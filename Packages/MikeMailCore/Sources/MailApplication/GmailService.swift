import Foundation
import MailDomain

public enum GmailSyncProgress: Sendable, Equatable {
    case checking, folders(Int), discovering(pages: Int, messages: Int)
    case updating(completed: Int, total: Int), scanning(completed: Int, total: Int?)
    case fullScanRequired, finishing, waiting(Int)
}

public actor GmailService {
    private let index: any GmailIndex
    private let factory: GmailFactory
    private var busy: Set<AccountID> = []
    public init(index: any GmailIndex, factory: @escaping GmailFactory) { self.index = index; self.factory = factory }
    private func api(account: AccountID) async throws -> any GmailReadAPI {
        guard let config = try await index.gmailConfigurations().first(where: { $0.accountID == account }) else { throw MailFailure.notFound }
        return factory(config)
    }
    public func synchronize(account: MailAccount, label: String? = nil, progress: @escaping @Sendable (GmailSyncProgress) async -> Void = { _ in }) async throws {
        guard busy.insert(account.id).inserted else { throw GmailFailure.busy }
        defer { busy.remove(account.id) }
        do {
            await progress(.checking)
            let base = try await api(account: account.id)
            let api = (base as? any GmailSyncReportingAPI)?.reportingSyncProgress(progress) ?? base
            if let full = index as? any FullMailIndex, let paged = api as? any GmailPagedReadAPI {
                try await synchronizeAll(account: account, api: paged, index: full, progress: progress)
                return
            }
            let previous = try await index.gmailCheckpoint(account: account.id)
            let profile = try await api.profile()
            guard profile.email.caseInsensitiveCompare(account.address.value) == .orderedSame else { throw MailFailure.permissionDenied }
            let folders = try await api.folders()
            try await index.reconcileGmailFolders(folders, account: account)
            await progress(.folders(folders.count))
            let available = Set(folders.map(\.providerID))
            var labels = previous.labels.intersection(available)
            labels.insert("INBOX")
            if let label {
                guard available.contains(label) else { throw MailFailure.notFound }
                labels.insert(label)
            }
            // Oldest coverage is not silently evicted when another label is selected.
            guard labels.count <= GmailBatch.labelLimit else { throw GmailFailure.tooLarge }
            var cursor = profile.historyID
            var changed = previous.knownIDs
            if let old = previous.historyID {
                do { let history = try await api.history(since: old); cursor = history.historyID; changed = history.changedIDs }
                catch GmailFailure.historyExpired { changed = previous.knownIDs }
                catch GmailFailure.historyLimit { changed = previous.knownIDs }
            }
            var wanted: Set<String> = []
            for label in labels.sorted() {
                try Task.checkCancellation()
                wanted.formUnion(try await api.messageIDs(label: label, limit: GmailBatch.windowLimit, query: nil))
            }
            let fetch = wanted.subtracting(previous.knownIDs).union(wanted.intersection(changed))
            var messages: [MailMessage] = [], threads: [ThreadID: String] = [:]
            for id in fetch.sorted() {
                try Task.checkCancellation()
                let (message, thread) = try await api.metadata(id: id, folders: folders)
                messages.append(message)
                if let local = message.threadID { threads[local] = thread }
                await progress(.updating(completed: messages.count, total: fetch.count))
            }
            try Task.checkCancellation()
            try await index.applyGmailBatch(GmailBatch(folders: folders, messages: messages, providerThreads: threads,
                wantedIDs: wanted, labels: labels, historyID: cursor), account: account)
            // Full current label metadata has been read back before clearing an uncertain mutation.
            try await index.setGmailPendingAction(false, account: account.id)
        } catch {
            if !Task.isCancelled {
                try? await index.setGmailStatus((error as? MailFailure) == .authenticationExpired ? .requiresAuthentication : .offline, account: account.id)
            }
            throw error
        }
    }
    private func synchronizeAll(account: MailAccount, api: any GmailPagedReadAPI, index full: any FullMailIndex,
                                progress: @escaping @Sendable (GmailSyncProgress) async -> Void) async throws {
        let profile = try await api.profile()
        guard profile.email.caseInsensitiveCompare(account.address.value) == .orderedSame else { throw MailFailure.permissionDenied }
        let folders = try await api.folders()
        try await index.reconcileGmailFolders(folders, account: account)
        await progress(.folders(folders.count))
        if let historyID = try await full.fullGmailHistory(account: account.id) {
            do {
                try await applyHistory(since: historyID, account: account, api: api, folders: folders, index: full, progress: progress)
                // A previously complete index can finish through history even if an
                // older build started an unnecessary full scan for a large update.
                try await full.resetFullMailScan(account: account.id, scope: "gmail")
                return
            } catch GmailFailure.historyExpired { await progress(.fullScanRequired) }
              catch GmailFailure.historyLimit { await progress(.fullScanRequired) }
        }
        var restarted = false
        while true {
            try Task.checkCancellation()
            let scan = try await full.fullMailScan(account: account.id, scope: "gmail", anchor: profile.historyID)
            await progress(.scanning(completed: scan.indexedCount, total: profile.messageCount))
            let page: GmailMessagePage
            do { page = try await Self.readWithRetry(progress: progress) { try await api.allMessageIDs(cursor: scan.cursor) } }
            catch SearchFailure.invalidCursor {
                try await full.resetFullMailScan(account: account.id, scope: "gmail")
                guard !restarted else { throw SearchFailure.invalidCursor }
                restarted = true; continue
            }
            let fetched: (messages: [MailMessage], threads: [ThreadID: String], removed: Set<String>)
            fetched = try await Self.metadata(page.ids, api: api, folders: folders, progress: progress) { count in
                await progress(.scanning(completed: scan.indexedCount + count, total: profile.messageCount))
            }
            try Task.checkCancellation()
            let count = try await full.applyFullMailPage(scan, account: account, folders: folders, messages: fetched.messages,
                providerThreads: fetched.threads, nextCursor: page.nextCursor, uidValidity: nil, serverCount: nil, flags: nil)
            await progress(.scanning(completed: count, total: profile.messageCount))
            if page.nextCursor == nil {
                // Changes during the full scan are replayed from its original history anchor.
                if let anchor = scan.anchor {
                    try await applyHistory(since: anchor, account: account, api: api, folders: folders, index: full, progress: progress)
                }
                return
            }
        }
    }
    private func applyHistory(since historyID: String, account: MailAccount, api: any GmailReadAPI, folders: [MailFolder],
                              index: any FullMailIndex, progress: @escaping @Sendable (GmailSyncProgress) async -> Void) async throws {
        await progress(.discovering(pages: 0, messages: 0))
        let history = try await Self.readWithRetry(progress: progress) {
            if let reporting = api as? any GmailHistoryProgressAPI {
                return try await reporting.history(since: historyID, existingLabelIDs: Set(folders.map(\.providerID))) { pages, count in
                    await progress(.discovering(pages: pages, messages: count))
                }
            }
            return try await api.history(since: historyID)
        }
        // Labels created while history was being read must be mapped before its
        // cursor is committed. Later server changes remain for the next history pass.
        let currentFolders = try await Self.readWithRetry(progress: progress) { try await api.folders() }
        try await self.index.reconcileGmailFolders(currentFolders, account: account)
        await progress(.folders(currentFolders.count))
        let ids = history.changedIDs.sorted()
        await progress(.updating(completed: 0, total: ids.count))
        for offset in stride(from: 0, to: ids.count, by: 100) {
            try Task.checkCancellation()
            let batch = Array(ids[offset..<min(offset + 100, ids.count)])
            let fetched = try await Self.metadata(batch, api: api, folders: currentFolders, progress: progress) { count in
                await progress(.updating(completed: offset + count, total: ids.count))
            }
            try await index.applyGmailChanges(account: account, folders: currentFolders, messages: fetched.messages,
                providerThreads: fetched.threads, removedIDs: fetched.removed, historyID: nil)
            await progress(.updating(completed: offset + batch.count, total: ids.count))
        }
        try Task.checkCancellation()
        // Advancing only after every changed message makes an interrupted update replayable.
        await progress(.finishing)
        try await index.applyGmailChanges(account: account, folders: currentFolders, messages: [], providerThreads: [:], removedIDs: [], historyID: history.historyID)
    }
    private static func readWithRetry<Value: Sendable>(progress: @escaping @Sendable (GmailSyncProgress) async -> Void,
                                                      operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do { return try await operation() }
            catch MailFailure.rateLimited(let seconds) where attempt < 2 {
                let delay = min(120, max(1, seconds))
                await progress(.waiting(Int(delay.rounded(.up))))
                try await Task.sleep(for: .seconds(delay))
            }
        }
        throw MailFailure.offline
    }
    private static func metadata(_ ids: [String], api: any GmailReadAPI, folders: [MailFolder],
                                 progress: @escaping @Sendable (GmailSyncProgress) async -> Void = { _ in },
                                 completed: @escaping @Sendable (Int) async -> Void = { _ in }) async throws
        -> (messages: [MailMessage], threads: [ThreadID: String], removed: Set<String>) {
        var messages: [MailMessage] = [], threads: [ThreadID: String] = [:], removed: Set<String> = []
        // Four concurrent requests keep memory and provider load bounded for large mailboxes.
        for offset in stride(from: 0, to: ids.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(ids[offset..<min(offset + 4, ids.count)])
            try await withThrowingTaskGroup(of: (String, MailMessage?, String?).self) { group in
                for id in batch {
                    group.addTask {
                        do {
                            let (message, thread) = try await readWithRetry(progress: progress) { try await api.metadata(id: id, folders: folders) }
                            return (id, message, thread)
                        }
                        catch MailFailure.notFound { return (id, nil, nil) }
                    }
                }
                for try await (id, message, thread) in group {
                    if let message, let thread { messages.append(message); if let local = message.threadID { threads[local] = thread } }
                    else { removed.insert(id) }
                }
            }
            await completed(offset + batch.count)
        }
        return (messages, threads, removed)
    }

    public func body(for message: MailMessage, scope: AccessScope, preferHTML: Bool) async throws -> MailBody {
        guard scope.permits(message), case .gmail(let id) = message.locator else { throw MailFailure.permissionDenied }
        return try await api(account: message.accountID).body(id: id, preferHTML: preferHTML, maximumBytes: 2 * 1024 * 1024)
    }
    public func download(_ request: AttachmentRequest, sink: @escaping AttachmentSink,
                         progress: @escaping AttachmentProgress) async throws {
        guard case .gmail = request.locator else { throw MailFailure.permissionDenied }
        guard busy.insert(request.accountID).inserted else { throw GmailFailure.busy }
        defer { busy.remove(request.accountID) }
        guard let source = try await api(account: request.accountID) as? any AttachmentSource else { throw MailFailure.unsupported }
        try await source.download(request, sink: sink, progress: progress)
    }
    public func perform(_ mutation: MailMutation, message: MailMessage, account: MailAccount, scope: AccessScope) async throws {
        guard scope.permits(message), message.accountID == account.id, case .gmail(let id) = message.locator
        else { throw GmailFailure.insufficientScope }
        guard busy.insert(account.id).inserted else { throw GmailFailure.busy }
        do {
            guard let config = try await index.gmailConfigurations().first(where: { $0.accountID == account.id }), config.permission == .manageMail
            else { throw GmailFailure.insufficientScope }
            guard try await !index.gmailPendingAction(account: account.id) else { throw GmailFailure.pendingAction }
            var add: [String] = [], remove: [String] = []
            switch mutation {
            case .read(let read): if read { remove = ["UNREAD"] } else { add = ["UNREAD"] }
            case .flagged(let flagged): if flagged { add = ["STARRED"] } else { remove = ["STARRED"] }
            case .move(let folder):
                guard folder.accountID == account.id else { throw MailFailure.permissionDenied }
                switch folder.providerID {
                case GmailIdentity.archive: remove = ["INBOX"]
                case "TRASH": add = ["TRASH"]; remove = ["INBOX"]
                case "INBOX": add = ["INBOX"]; remove = ["TRASH", "SPAM"]
                default:
                    guard folder.providerID.hasPrefix("Label_") else { throw MailFailure.unsupported }
                    add = [folder.providerID]; remove = ["INBOX"]
                }
            }
            let api = factory(config)
            if case .move = mutation { /* Move is checked by its scoped target and read-back. */ }
            else {
                let labels = try await api.folders()
                let (current, _) = try await api.metadata(id: id, folders: labels)
                switch mutation {
                case .read: guard current.isUnread == message.isUnread else { throw MailFailure.providerFailure }
                case .flagged: guard current.isFlagged == message.isFlagged else { throw MailFailure.providerFailure }
                case .move: break
                }
            }
            try await index.setGmailPendingAction(true, account: account.id)
            try await api.modify(id: id, adding: add, removing: remove)
            let labels = try await api.folders()
            let (confirmed, thread) = try await api.metadata(id: id, folders: labels)
            guard Self.matches(mutation, message: confirmed, folders: labels) else { throw GmailFailure.pendingAction }
            if let full = index as? any FullMailIndex {
                // Keep the existing history cursor: the next normal sync still
                // discovers unrelated changes. No full-account scan per click.
                try await full.applyGmailChanges(account: account, folders: labels, messages: [confirmed],
                    providerThreads: confirmed.threadID.map { [$0: thread] } ?? [:], removedIDs: [], historyID: nil)
                try await index.setGmailPendingAction(false, account: account.id)
                busy.remove(account.id)
                return
            }
        } catch { busy.remove(account.id); throw error }
        busy.remove(account.id)
        try await synchronize(account: account)
    }
    /// Fresh read-only verification for a previously uncertain write. A false
    /// result means the requested state is not present now; it never retries it.
    public func verify(_ mutation: MailMutation, message: MailMessage, account: MailAccount, scope: AccessScope) async throws -> Bool {
        guard scope.permits(message), message.accountID == account.id, case .gmail(let id) = message.locator else { throw MailFailure.permissionDenied }
        if case .move(let target) = mutation { guard target.accountID == account.id, scope.folderIDs?.contains(target.id) ?? true else { throw MailFailure.permissionDenied } }
        // A surviving provider journal must be reconciled before other writes.
        if try await index.gmailPendingAction(account: account.id) { try await synchronize(account: account) }
        guard busy.insert(account.id).inserted else { throw GmailFailure.busy }
        defer { busy.remove(account.id) }
        let api = try await api(account: account.id)
        let profile = try await api.profile()
        guard profile.email.caseInsensitiveCompare(account.address.value) == .orderedSame else { throw MailFailure.permissionDenied }
        let folders = try await api.folders()
        let (current, thread) = try await api.metadata(id: id, folders: folders)
        if let full = index as? any FullMailIndex {
            try await full.applyGmailChanges(account: account, folders: folders, messages: [current],
                providerThreads: current.threadID.map { [$0: thread] } ?? [:], removedIDs: [], historyID: nil)
        }
        return Self.matches(mutation, message: current, folders: folders)
    }
    private static func matches(_ mutation: MailMutation, message: MailMessage, folders: [MailFolder]) -> Bool {
        let labels = Set(folders.filter { message.folderIDs.contains($0.id) }.map(\.providerID))
        switch mutation {
        case .read(let read): return message.isUnread == !read
        case .flagged(let flagged): return message.isFlagged == flagged
        case .move(let target):
            if target.providerID == GmailIdentity.archive { return labels.isDisjoint(with: ["INBOX", "TRASH", "SPAM"]) }
            return labels.contains(target.providerID) && (target.providerID == "INBOX" || !labels.contains("INBOX"))
        }
    }
}
