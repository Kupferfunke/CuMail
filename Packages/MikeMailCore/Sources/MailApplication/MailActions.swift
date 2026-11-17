import Foundation
import MailDomain

public enum MailActionKind: String, Codable, Sendable { case read, unread, flag, unflag, move }
/// An accepted assistant job keeps its original scope and a revocable account grant.
/// This contains no login credentials or live MCP session tokens.
public struct AssistantActionAuthorization: Codable, Equatable, Sendable {
    public let generation: UUID
    public let folderIDs: Set<FolderID>
    public init(generation: UUID = UUID(), folderIDs: Set<FolderID>) {
        self.generation = generation; self.folderIDs = folderIDs
    }
    public func scope(account: AccountID) -> AccessScope { AccessScope(accountIDs: [account], folderIDs: folderIDs) }
}
public struct MailActionRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let accountID: AccountID
    public let messageIDs: [MessageID]
    public let kind: MailActionKind
    public let targetFolderID: FolderID?
    public init(id: UUID = UUID(), accountID: AccountID, messageIDs: [MessageID], kind: MailActionKind, targetFolderID: FolderID? = nil) throws {
        guard !messageIDs.isEmpty, messageIDs.count <= 100, Set(messageIDs).count == messageIDs.count,
              (kind == .move) == (targetFolderID != nil) else { throw MailFailure.invalidInput }
        self.id = id; self.accountID = accountID; self.messageIDs = messageIDs.sorted { $0.description < $1.description }
        self.kind = kind; self.targetFolderID = targetFolderID
    }
}
public struct MailActionReceipt: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case waiting, inFlight, confirmed, uncertain, notAttempted, undone }
    public struct Item: Codable, Equatable, Sendable {
        public let messageID: MessageID
        public let originalFolders: Set<FolderID>
        public let wasUnread: Bool
        public let wasFlagged: Bool
        public var state: State
        /// Fresh provider read-back resolved the ambiguity without replaying a write.
        public var checkedAt: Date?
    }
    public let request: MailActionRequest
    public let createdAt: Date
    public var items: [Item]
    public var finished: Bool
    public var undoRequestID: UUID?
    /// Legacy receipts without either queue marker never gain resume permission.
    public var nativeQueue: Bool?
    public var assistantAuthorization: AssistantActionAuthorization?
    public var queueDismissed: Bool?
    public var isQueued: Bool { nativeQueue == true || assistantAuthorization != nil }
    public var id: UUID { request.id }
    public var confirmedCount: Int { items.filter { $0.state == .confirmed }.count }
    public var uncertainCount: Int { items.filter { $0.state == .uncertain || $0.state == .inFlight }.count }
    public var blocksQueue: Bool { items.contains { ($0.state == .uncertain || $0.state == .inFlight) && $0.checkedAt == nil } }
    public var needsAttention: Bool { finished && items.contains { $0.state == .uncertain || $0.state == .inFlight || $0.state == .notAttempted } }
    public var canUndo: Bool { finished && request.kind != .move && confirmedCount > 0 && uncertainCount == 0 && undoRequestID == nil && Date().timeIntervalSince(createdAt) < 86400 }
    public func permitted(in scope: AccessScope) -> Bool {
        scope.accountIDs.contains(request.accountID) &&
        items.allSatisfy { item in scope.folderIDs.map { !$0.isDisjoint(with: item.originalFolders) } ?? true } &&
        (request.targetFolderID.map { scope.folderIDs?.contains($0) ?? true } ?? true)
    }
}
public protocol MailActionStore: Sendable {
    func mailAction(id: UUID, account: AccountID) async throws -> MailActionReceipt?
    func saveMailAction(_ receipt: MailActionReceipt) async throws
    func queuedMailActions(accounts: Set<AccountID>) async throws -> [MailActionReceipt]
}

/// Durable write receipts never replay an operation whose server outcome is uncertain.
public actor MailActions {
    public typealias Authorize = @Sendable () async throws -> Void
    public typealias Writer = @Sendable (MailMutation, MailMessage, MailAccount, AccessScope) async throws -> Void
    public typealias Verifier = @Sendable (MailMutation, MailMessage, MailAccount, AccessScope) async throws -> Bool
    private let service: InboxService
    private let store: any MailActionStore
    private let writer: Writer
    private var running = false
    private var preparations: [UUID: Task<MailActionReceipt, Error>] = [:]
    public init(service: InboxService, store: any MailActionStore, writer: @escaping Writer) {
        self.service = service; self.store = store; self.writer = writer
    }
    public func get(id: UUID, account: AccountID, scope: AccessScope) async throws -> MailActionReceipt {
        guard let receipt = try await store.mailAction(id: id, account: account), receipt.permitted(in: scope) else { throw MailFailure.notFound }
        if !running, receipt.items.contains(where: { $0.state == .inFlight }) || (!receipt.finished && receipt.undoRequestID != nil) {
            // Interrupted undo is never a resumable forward action. Finalize its
            // known outcomes too, including a partially restored batch.
            var recovered = receipt
            for i in recovered.items.indices {
                if recovered.items[i].state == .inFlight { recovered.items[i].state = .uncertain }
                else if recovered.items[i].state == .waiting { recovered.items[i].state = .notAttempted }
            }
            recovered.finished = true; try await store.saveMailAction(recovered); return recovered
        }
        return receipt
    }
    public func prepare(_ request: MailActionRequest, scope: AccessScope, nativeQueue: Bool = false,
                        assistantAuthorization: AssistantActionAuthorization? = nil, authorize: @escaping Authorize) async throws -> MailActionReceipt {
        try await authorize()
        // Two deliveries of one MCP request may overlap. Never let a second
        // preparation overwrite a receipt that the worker has already advanced.
        if let pending = preparations[request.id] {
            _ = try await pending.value
            try await authorize()
            let existing = try await get(id: request.id, account: request.accountID, scope: scope)
            guard existing.request == request else { throw MailFailure.invalidInput }
            return existing
        }
        let pending = Task {
            try await self.prepareNew(request, scope: scope, nativeQueue: nativeQueue,
                                      assistantAuthorization: assistantAuthorization, authorize: authorize)
        }
        preparations[request.id] = pending
        defer { preparations.removeValue(forKey: request.id) }
        return try await pending.value
    }
    private func prepareNew(_ request: MailActionRequest, scope: AccessScope, nativeQueue: Bool,
                            assistantAuthorization: AssistantActionAuthorization?, authorize: Authorize) async throws -> MailActionReceipt {
        let createdAt = Date()
        try await authorize()
        if let existing = try await store.mailAction(id: request.id, account: request.accountID) {
            guard existing.request == request, existing.permitted(in: scope) else { throw MailFailure.invalidInput }
            return existing
        }
        if let target = request.targetFolderID {
            guard try await service.folders(scope: scope).contains(where: { $0.id == target && $0.accountID == request.accountID }) else { throw MailFailure.permissionDenied }
        }
        var items: [MailActionReceipt.Item] = []
        for id in request.messageIDs {
            let message = try await service.getEmail(id, scope: scope)
            guard message.accountID == request.accountID, scope.permits(message) else { throw MailFailure.permissionDenied }
            items.append(.init(messageID: id, originalFolders: message.folderIDs, wasUnread: message.isUnread, wasFlagged: message.isFlagged, state: .waiting))
        }
        try await authorize()
        var receipt = MailActionReceipt(request: request, createdAt: createdAt, items: items, finished: false)
        guard !nativeQueue || assistantAuthorization == nil else { throw MailFailure.invalidInput }
        if nativeQueue { receipt.nativeQueue = true }
        if let assistantAuthorization {
            guard receipt.permitted(in: assistantAuthorization.scope(account: request.accountID)) else { throw MailFailure.permissionDenied }
            receipt.assistantAuthorization = assistantAuthorization
        }
        try await store.saveMailAction(receipt)
        return receipt
    }
    public func queue(scope: AccessScope) async throws -> [MailActionReceipt] {
        var result: [MailActionReceipt] = []
        for stored in try await store.queuedMailActions(accounts: scope.accountIDs) where stored.permitted(in: scope) {
            result.append(try await get(id: stored.id, account: stored.request.accountID, scope: scope))
        }
        return result.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }
    public func dismissQueueResult(id: UUID, account: AccountID, scope: AccessScope) async throws {
        var receipt = try await get(id: id, account: account, scope: scope)
        guard receipt.finished, receipt.isQueued else { throw MailFailure.invalidInput }
        receipt.queueDismissed = true; try await store.saveMailAction(receipt)
    }
    /// Verifies only the current provider state. It never calls the writer or
    /// turns an uncertain attempt back into a waiting/retryable action.
    public func reconcile(id: UUID, account: AccountID, scope: AccessScope, authorize: Authorize, verify: Verifier) async throws -> MailActionReceipt {
        guard !running else { throw MailFailure.rateLimited(retryAfter: 1) }
        running = true; defer { running = false }
        var receipt = try await get(id: id, account: account, scope: scope)
        guard receipt.finished, receipt.uncertainCount > 0, receipt.undoRequestID == nil else { return receipt }
        try await authorize()
        guard let owner = try await service.accounts(scope: scope).first(where: { $0.id == account }) else { throw MailFailure.notFound }
        let target = try await service.folders(scope: scope).first { $0.id == receipt.request.targetFolderID && $0.accountID == account }
        for i in receipt.items.indices where receipt.items[i].state == .uncertain {
            try Task.checkCancellation(); try await authorize()
            let message = try await service.getEmail(receipt.items[i].messageID, scope: scope)
            guard message.accountID == account, scope.permits(message) else { throw MailFailure.permissionDenied }
            let mutation: MailMutation
            switch receipt.request.kind {
            case .read: mutation = .read(true)
            case .unread: mutation = .read(false)
            case .flag: mutation = .flagged(true)
            case .unflag: mutation = .flagged(false)
            case .move: guard let target else { throw MailFailure.notFound }; mutation = .move(target)
            }
            let matched = try await verify(mutation, message, owner, scope)
            try await authorize()
            if matched { receipt.items[i].state = .confirmed }
            receipt.items[i].checkedAt = Date()
            try await store.saveMailAction(receipt)
        }
        return receipt
    }
    public func execute(id: UUID, account: AccountID, scope: AccessScope, authorize: Authorize) async throws -> MailActionReceipt {
        guard !running else { throw MailFailure.rateLimited(retryAfter: 1) }
        running = true; defer { running = false }
        var receipt = try await get(id: id, account: account, scope: scope)
        // Any previous start is evidence of uncertainty; never infer that it failed.
        guard !receipt.finished, receipt.items.allSatisfy({ $0.state == .waiting || (receipt.isQueued && $0.state == .confirmed) }) else { return receipt }
        guard let owner = try await service.accounts(scope: scope).first(where: { $0.id == account }) else { throw MailFailure.notFound }
        let target = try await service.folders(scope: scope).first { $0.id == receipt.request.targetFolderID && $0.accountID == account }
        for i in receipt.items.indices where receipt.items[i].state == .waiting {
            var writeStarted = false
            do {
                try Task.checkCancellation(); try await authorize()
                let message = try await service.getEmail(receipt.items[i].messageID, scope: scope)
                guard message.accountID == account, scope.permits(message), message.folderIDs == receipt.items[i].originalFolders else { throw MailFailure.permissionDenied }
                let mutation: MailMutation
                switch receipt.request.kind {
                case .read: mutation = .read(true)
                case .unread: mutation = .read(false)
                case .flag: mutation = .flagged(true)
                case .unflag: mutation = .flagged(false)
                case .move: guard let target else { throw MailFailure.notFound }; mutation = .move(target)
                }
                receipt.items[i].state = .inFlight; try await store.saveMailAction(receipt)
                try await authorize()
                try Task.checkCancellation()
                writeStarted = true
                try await writer(mutation, message, owner, scope)
                receipt.items[i].state = .confirmed; try await store.saveMailAction(receipt)
            } catch {
                if error is CancellationError, receipt.isQueued, !writeStarted {
                    // Nothing was sent for this item. Retain the durable queue
                    // position so a normal quit/restart can continue safely.
                    receipt.items[i].state = .waiting
                    try await store.saveMailAction(receipt)
                    return receipt
                }
                receipt.items[i].state = writeStarted ? .uncertain : .notAttempted
                break
            }
        }
        for i in receipt.items.indices where receipt.items[i].state == .waiting { receipt.items[i].state = .notAttempted }
        receipt.finished = true; try await store.saveMailAction(receipt)
        return receipt
    }
    /// Read/flag undo uses the recorded previous values and refuses to overwrite a later change.
    public func undo(id: UUID, account: AccountID, undoID: UUID, scope: AccessScope, authorize: Authorize) async throws -> MailActionReceipt {
        guard !running else { throw MailFailure.rateLimited(retryAfter: 1) }
        running = true; defer { running = false }
        var receipt = try await get(id: id, account: account, scope: scope)
        if receipt.undoRequestID == undoID { return receipt }
        guard receipt.canUndo, Date().timeIntervalSince(receipt.createdAt) < 86400 else { throw MailFailure.invalidInput }
        try await authorize()
        guard let owner = try await service.accounts(scope: scope).first(where: { $0.id == account }) else { throw MailFailure.notFound }
        receipt.undoRequestID = undoID; receipt.finished = false; try await store.saveMailAction(receipt)
        for i in receipt.items.indices where receipt.items[i].state == .confirmed {
            do {
                try Task.checkCancellation(); try await authorize()
                let item = receipt.items[i], message = try await service.getEmail(item.messageID, scope: scope)
                let mutation: MailMutation
                switch receipt.request.kind {
                case .read, .unread:
                    guard message.isUnread == (receipt.request.kind == .unread) else { continue }
                    mutation = .read(!item.wasUnread)
                case .flag, .unflag:
                    guard message.isFlagged == (receipt.request.kind == .flag) else { continue }
                    mutation = .flagged(item.wasFlagged)
                case .move: throw MailFailure.unsupported
                }
                receipt.items[i].state = .inFlight; try await store.saveMailAction(receipt)
                try await authorize(); try await writer(mutation, message, owner, scope)
                receipt.items[i].state = .undone; try await store.saveMailAction(receipt)
            } catch {
                if receipt.items[i].state == .inFlight { receipt.items[i].state = .uncertain }
                break
            }
        }
        receipt.finished = true; try await store.saveMailAction(receipt)
        return receipt
    }
}
