import Foundation
import MailDomain
import MailApplication

public actor InMemoryMailRepository: MailMetadataRepository, PlainTextContentSource {
    private let snapshot: MailSnapshot
    private let contents: [MessageID: String]

    public init(snapshot: MailSnapshot, contents: [MessageID: String] = [:]) {
        self.snapshot = snapshot; self.contents = contents
    }

    public func accounts(in scope: AccessScope) -> [MailAccount] { snapshot.accounts.filter { scope.accountIDs.contains($0.id) } }
    public func folders(in scope: AccessScope) -> [MailFolder] {
        snapshot.folders.filter { scope.accountIDs.contains($0.accountID) && (scope.folderIDs?.contains($0.id) ?? true) }
    }
    public func messages(filter: MessageFilter, page: PageRequest, in scope: AccessScope) throws -> MessagePage {
        try Task.checkCancellation()
        let query = try filter.searchQuery()
        let accountIDs = Set(snapshot.accounts.filter(query.matchesAccount).map(\.id))
        let folderIDs = Set(snapshot.folders.filter(query.matchesFolder).map(\.id))
        let matches = snapshot.messages.filter { message in
            scope.permits(message)
            && accountIDs.contains(message.accountID)
            && (query.folder == nil || !message.folderIDs.isDisjoint(with: folderIDs))
            && (filter.accountID.map { message.accountID == $0 } ?? true)
            && (filter.folderID.map { message.folderIDs.contains($0) } ?? true)
            && (filter.role.map { role in snapshot.folders.contains { $0.role == role && message.folderIDs.contains($0.id) } } ?? true)
            && (!filter.unreadOnly || message.isUnread) && (!filter.flaggedOnly || message.isFlagged)
            && (filter.receivedAfter.map { message.receivedAt >= $0 } ?? true)
            && query.matchesMetadata(message)
        }
        return try paginate(matches, page: page)
    }
    public func message(id: MessageID, in scope: AccessScope) throws -> MailMessage {
        guard let message = snapshot.messages.first(where: { $0.id == id }), scope.permits(message) else { throw MailFailure.notFound }
        return message
    }
    public func thread(id: ThreadID, page: PageRequest, in scope: AccessScope) throws -> MessagePage {
        guard snapshot.threads.contains(where: { $0.id == id && scope.accountIDs.contains($0.accountID) }) else { throw MailFailure.notFound }
        return try paginate(snapshot.messages.filter { $0.threadID == id && scope.permits($0) }, page: page)
    }
    public func text(for id: MessageID, scope: AccessScope) throws -> String {
        _ = try message(id: id, in: scope)
        guard let content = contents[id] else { throw MailFailure.notFound }
        return content
    }
    private func paginate(_ values: [MailMessage], page: PageRequest) throws -> MessagePage {
        let offset: Int
        if let cursor = page.cursor {
            guard !cursor.isEmpty, cursor.allSatisfy(\.isNumber), let parsed = Int(cursor), parsed >= 0, parsed <= values.count else { throw MailFailure.invalidInput }
            offset = parsed
        } else { offset = 0 }
        let ordered = values.sorted { $0.receivedAt == $1.receivedAt ? $0.id.description < $1.id.description : $0.receivedAt > $1.receivedAt }
        let end = offset + min(page.limit, ordered.count - offset)
        return MessagePage(items: Array(ordered[offset..<end]), nextCursor: end < ordered.count ? String(end) : nil,
                           coverage: SearchCoverage(isSynthetic: true, metadataOnly: true, messageCount: ordered.count,
                                                    oldest: ordered.last?.receivedAt, newest: ordered.first?.receivedAt))
    }
    private static func searchableMetadata(_ message: MailMessage) -> String {
        ([message.subject, message.sender.name, message.sender.address.value]
         + message.recipients.map { $0.address.value } + message.attachments.map(\.filename)).joined(separator: " ")
    }
}

/// Tests only. Never touches Security.framework or a real Keychain entry.
public actor InMemoryCredentialStore: CredentialStore {
    private var values: [CredentialReference: Data] = [:]
    public init() {}
    public func read(_ reference: CredentialReference) -> Data? { values[reference] }
    public func save(_ secret: Data, for reference: CredentialReference) { values[reference] = secret }
    public func delete(_ reference: CredentialReference) { values[reference] = nil }
}
