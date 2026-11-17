import Foundation
import MailDomain

/// The UI uses this application service. Credentials and library types never enter the index.
public actor IMAPService {
    private let index: any IMAPIndex
    private let credentials: any CredentialStore
    private let factory: IMAPSessionFactory
    private var busy = false
    public init(index: any IMAPIndex, credentials: any CredentialStore, factory: @escaping IMAPSessionFactory) {
        self.index = index; self.credentials = credentials; self.factory = factory
    }

    public func connectAccount(_ account: MailAccount, configuration: IMAPConfiguration, password: String) async throws {
        guard account.id == configuration.accountID, account.provider == .imap, account.status != .demo,
              !password.isEmpty, password.utf8.count <= 4096,
              !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw MailFailure.invalidInput }
        guard !busy else { throw IMAPFailure.busy }
        busy = true; defer { busy = false }
        guard !(try await index.imapConfigurations()).contains(where: { $0.accountID == account.id }) else {
            throw MailFailure.invalidInput
        }
        let session = factory(configuration, password)
        let folders = try await Self.run(session) { session in
            try await session.connect()
            return try await session.folders()
        }
        try Task.checkCancellation()
        let reference = CredentialReference(accountID: account.id, purpose: .incomingPassword)
        try await credentials.save(Data(password.utf8), for: reference)
        do {
            try Task.checkCancellation()
            try await index.addIMAPAccount(account, configuration: configuration, folders: folders)
        } catch {
            try? await credentials.delete(reference)
            throw error
        }
    }

    public func sync(account: MailAccount, folder: MailFolder, progress: @escaping @Sendable (Int) async -> Void = { _ in }) async throws -> IMAPSyncSummary {
        guard folder.accountID == account.id, account.provider == .imap, account.status != .demo else { throw MailFailure.permissionDenied }
        guard !busy else { throw IMAPFailure.busy }
        busy = true; defer { busy = false }
        do {
            if let full = index as? any FullMailIndex {
                return try await synchronizeAll(account: account, folder: folder, index: full, progress: progress)
            }
            let session = try await makeSession(account: account.id)
            let checkpoint = try await index.imapCheckpoint(account: account.id, folder: folder.id)
            let batch = try await Self.run(session) { session in
                try await session.connect()
                return try await session.readFolder(folder, checkpoint: checkpoint)
            }
            try Task.checkCancellation()
            try await index.applyIMAPBatch(batch, account: account, folder: folder)
            return IMAPSyncSummary(folderID: folder.id, indexedCount: batch.flags.count,
                                   totalOnServer: batch.totalOnServer, lastSuccess: Date())
        } catch {
            if !Task.isCancelled {
                let needsLogin = (error as? IMAPFailure) == .authentication || (error as? IMAPFailure) == .missingCredential
                try? await index.setConnectionStatus(needsLogin ? .requiresAuthentication : .offline, account: account.id)
            }
            throw error
        }
    }

    private func synchronizeAll(account: MailAccount, folder: MailFolder, index: any FullMailIndex,
                                progress: @escaping @Sendable (Int) async -> Void = { _ in }) async throws -> IMAPSyncSummary {
        let checkpoint = try await self.index.imapCheckpoint(account: account.id, folder: folder.id)
        var restarted = false
        while true {
            try Task.checkCancellation()
            let scan = try await index.fullMailScan(account: account.id, scope: folder.id.description, anchor: nil)
            let session = try await makeSession(account: account.id)
            guard let searcher = session as? any IMAPSearchSession else { throw MailFailure.unsupported }
            let page: OnlineSearchPage
            do {
                page = try await Self.run(session) { reader in
                    try await reader.connect()
                    if let catalog = searcher as? any IMAPCatalogSession {
                        return try await catalog.catalog(folder: folder, checkpoint: checkpoint, page: PageRequest(limit: 100, cursor: scan.cursor))
                    }
                    return try await searcher.search(folder: folder, query: MailSearchQuery(), page: PageRequest(limit: 100, cursor: scan.cursor))
                }
            } catch SearchFailure.invalidCursor {
                try await index.resetFullMailScan(account: account.id, scope: folder.id.description)
                guard !restarted else { throw IMAPFailure.mailboxChanged }
                restarted = true; continue
            } catch IMAPFailure.mailboxChanged {
                try await index.resetFullMailScan(account: account.id, scope: folder.id.description)
                throw IMAPFailure.mailboxChanged
            }
            try Task.checkCancellation()
            let count = try await index.applyFullMailPage(scan, account: account, folders: [folder], messages: page.items,
                providerThreads: [:], nextCursor: page.nextCursor, uidValidity: page.uidValidity, serverCount: page.totalMessagesInFolder, flags: page.indexedFlags)
            await progress(count)
            if page.nextCursor == nil {
                return IMAPSyncSummary(folderID: folder.id, indexedCount: count, totalOnServer: page.totalMessagesInFolder, lastSuccess: Date())
            }
        }
    }

    public func refreshFolders(account: AccountID) async throws {
        guard !busy else { throw IMAPFailure.busy }
        busy = true; defer { busy = false }
        let session = try await makeSession(account: account)
        let folders = try await Self.run(session) { session in
            try await session.connect()
            return try await session.folders()
        }
        try Task.checkCancellation()
        try await index.updateIMAPFolders(account: account, folders: folders)
    }

    public func search(account: MailAccount, folder: MailFolder, filter: MessageFilter, page: PageRequest, scope: AccessScope) async throws -> OnlineSearchPage {
        var query = try filter.searchQuery()
        guard account.provider == .imap, account.status != .demo, folder.accountID == account.id,
              scope.accountIDs.contains(account.id), scope.folderIDs?.contains(folder.id) ?? true,
              folder.id == (try IMAPIdentity.folder(account: account.id, mailbox: folder.providerID)),
              filter.accountID.map({ $0 == account.id }) ?? true,
              filter.folderID.map({ $0 == folder.id }) ?? true,
              filter.role.map({ $0 == folder.role }) ?? true,
              query.matchesAccount(account), query.matchesFolder(folder) else { throw MailFailure.permissionDenied }
        guard query.supportsOnline else { throw SearchFailure.onlineFilterUnsupported }
        if (filter.unreadOnly && query.unread == false) || (filter.flaggedOnly && query.flagged == false) {
            return OnlineSearchPage(items: [], nextCursor: nil, totalMessagesInFolder: 0)
        }
        if filter.unreadOnly { query.unread = true }
        if filter.flaggedOnly { query.flagged = true }
        guard !busy else { throw IMAPFailure.busy }
        busy = true; defer { busy = false }
        let session = try await makeSession(account: account.id)
        guard let searcher = session as? any IMAPSearchSession else { throw MailFailure.unsupported }
        let requestQuery = query
        let result = try await Self.run(session) { reader in
            try await reader.connect()
            return try await searcher.search(folder: folder, query: requestQuery, page: page)
        }
        guard result.items.count <= page.limit, result.items.allSatisfy({
            $0.accountID == account.id && $0.folderIDs == [folder.id] && scope.permits($0)
        }) else { throw IMAPFailure.invalidResponse }
        return result
    }

    public func plainText(for message: MailMessage, scope: AccessScope) async throws -> String {
        guard scope.permits(message), case .imap = message.locator else { throw MailFailure.permissionDenied }
        guard !busy else { throw IMAPFailure.busy }
        busy = true; defer { busy = false }
        let session = try await makeSession(account: message.accountID)
        let request = try ContentRequest(accountID: message.accountID, locator: message.locator, maximumBytes: 256 * 1024)
        return try await Self.run(session) { session in
            try await session.connect()
            return try await session.plainText(request)
        }
    }

    public func download(_ request: AttachmentRequest, sink: @escaping AttachmentSink,
                         progress: @escaping AttachmentProgress) async throws {
        guard case .imap = request.locator else { throw MailFailure.permissionDenied }
        guard !busy else { throw IMAPFailure.busy }
        busy = true; defer { busy = false }
        let session = try await makeSession(account: request.accountID)
        guard let source = session as? any AttachmentSource else { throw MailFailure.unsupported }
        try await Self.run(session) {
            try await $0.connect()
            try await source.download(request, sink: sink, progress: progress)
        }
    }

    public func updatePassword(account: AccountID, password: String) async throws {
        guard !password.isEmpty, password.utf8.count <= 4096,
              !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw MailFailure.invalidInput }
        guard !busy else { throw IMAPFailure.busy }
        busy = true; defer { busy = false }
        guard let config = try await index.imapConfigurations().first(where: { $0.accountID == account }) else { throw MailFailure.notFound }
        let session = factory(config, password)
        try await Self.run(session) { try await $0.connect() }
        try Task.checkCancellation()
        try await credentials.save(Data(password.utf8), for: CredentialReference(accountID: account, purpose: .incomingPassword))
        try await index.setConnectionStatus(.connected, account: account)
    }

    public func body(for message: MailMessage, scope: AccessScope, preferHTML: Bool) async throws -> MailBody {
        guard scope.permits(message), case .imap = message.locator else { throw MailFailure.permissionDenied }
        guard !busy else { throw IMAPFailure.busy }
        busy = true; defer { busy = false }
        let session = try await makeSession(account: message.accountID)
        let request = try ContentRequest(accountID: message.accountID, locator: message.locator, maximumBytes: preferHTML ? 2 * 1024 * 1024 : 256 * 1024)
        return try await Self.run(session) {
            try await $0.connect()
            return try await $0.body(request, preferHTML: preferHTML)
        }
    }

    public func perform(_ mutation: MailMutation, message: MailMessage, account: MailAccount, scope: AccessScope) async throws {
        guard scope.permits(message), account.id == message.accountID, account.provider == .imap, account.status != .demo,
              case .imap(let mailbox, _, _) = message.locator else { throw MailFailure.permissionDenied }
        let source = try IMAPIdentity.folder(account: account.id, mailbox: mailbox)
        guard message.folderIDs.contains(source) else { throw MailFailure.permissionDenied }
        var target: FolderID?
        if case .move(let folder) = mutation {
            guard folder.accountID == account.id, folder.id != source,
                  scope.folderIDs?.contains(folder.id) ?? true else { throw MailFailure.permissionDenied }
            target = folder.id
        }
        guard !busy else { throw IMAPFailure.busy }
        busy = true; defer { busy = false }
        let pending = PendingMailAction(accountID: account.id, sourceFolder: source, targetFolder: target)
        try await index.beginMailAction(pending, message: message)
        // Durable uncertainty marker is written before any network mutation; it is never replayed.
        let session = try await makeSession(account: account.id)
        guard let writer = session as? any IMAPWriteSession else { throw IMAPFailure.unsupportedAction }
        if let full = index as? any FullMailIndex {
            try await Self.run(session) { reader in
                try await reader.connect()
                try await writer.perform(mutation, on: message)
            }
            try await reconcileFull([pending], account: account, index: full)
        } else {
            try await Self.run(session) { [index] reader in
                try await reader.connect()
                try await writer.perform(mutation, on: message)
                try await Self.reconcile([pending], account: account, session: reader, index: index)
            }
        }
    }

    /// Explicit Sync resolves uncertain operations by reading both folders, never repeating a write.
    public func reconcilePending(account: MailAccount) async throws {
        guard !busy else { throw IMAPFailure.busy }
        busy = true; defer { busy = false }
        let actions = try await index.pendingMailActions(account: account.id)
        guard !actions.isEmpty else { return }
        if let full = index as? any FullMailIndex {
            try await reconcileFull(actions, account: account, index: full)
            return
        }
        let session = try await makeSession(account: account.id)
        try await Self.run(session) { [index] reader in
            try await reader.connect()
            try await Self.reconcile(actions, account: account, session: reader, index: index)
        }
    }
    private func reconcileFull(_ actions: [PendingMailAction], account: MailAccount, index full: any FullMailIndex) async throws {
        let session = try await makeSession(account: account.id)
        let folders = try await Self.run(session) { try await $0.connect(); return try await $0.folders() }
        let ids = Set(actions.flatMap { [$0.sourceFolder] + [$0.targetFolder].compactMap { $0 } })
        guard ids.allSatisfy({ id in folders.contains { $0.id == id } }) else { throw IMAPFailure.mailboxChanged }
        for folder in folders where ids.contains(folder.id) {
            try await full.resetFullMailScan(account: account.id, scope: folder.id.description)
            _ = try await synchronizeAll(account: account, folder: folder, index: full)
        }
        for action in actions { try await index.finishMailAction(action.id, account: account.id) }
    }

    private static func reconcile(_ actions: [PendingMailAction], account: MailAccount, session: any IMAPReadSession, index: any IMAPIndex) async throws {
        let folders = try await session.folders()
        let ids = Set(actions.flatMap { [$0.sourceFolder] + [$0.targetFolder].compactMap { $0 } })
        guard ids.allSatisfy({ id in folders.contains { $0.id == id && $0.accountID == account.id } }) else { throw IMAPFailure.mailboxChanged }
        for folder in folders where ids.contains(folder.id) {
            let checkpoint = try await index.imapCheckpoint(account: account.id, folder: folder.id)
            let batch = try await session.readFolder(folder, checkpoint: checkpoint)
            try Task.checkCancellation()
            try await index.applyIMAPBatch(batch, account: account, folder: folder)
        }
        try Task.checkCancellation()
        for action in actions { try await index.finishMailAction(action.id, account: account.id) }
    }

    private func makeSession(account: AccountID) async throws -> any IMAPReadSession {
        guard let config = try await index.imapConfigurations().first(where: { $0.accountID == account }) else { throw MailFailure.notFound }
        guard let data = try await credentials.read(CredentialReference(accountID: account, purpose: .incomingPassword)),
              let password = String(data: data, encoding: .utf8), !password.isEmpty else { throw IMAPFailure.missingCredential }
        try Task.checkCancellation()
        return factory(config, password)
    }

    private static func run<T: Sendable>(_ session: any IMAPReadSession,
                                         operation: @escaping @Sendable (any IMAPReadSession) async throws -> T) async throws -> T {
        do {
            let value = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: T.self) { group in
                    group.addTask { try Task.checkCancellation(); return try await operation(session) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(45))
                        await session.disconnect()
                        throw IMAPFailure.timeout
                    }
                    defer { group.cancelAll() }
                    guard let value = try await group.next() else { throw CancellationError() }
                    return value
                }
            } onCancel: {
                Task { await session.disconnect() }
            }
            await session.disconnect()
            try Task.checkCancellation()
            return value
        } catch {
            await session.disconnect()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}
