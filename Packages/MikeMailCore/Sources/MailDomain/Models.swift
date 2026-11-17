import Foundation

public enum ProviderKind: String, CaseIterable, Sendable { case gmail, microsoft, imap }
public enum AccountStatus: String, Sendable { case demo, connected, offline, requiresAuthentication }

public struct MailAccount: Identifiable, Hashable, Sendable {
    public let id: AccountID
    public let name: String
    public let address: EmailAddress
    public let provider: ProviderKind
    public let status: AccountStatus
    public init(id: AccountID, name: String, address: EmailAddress, provider: ProviderKind, status: AccountStatus = .demo) {
        self.id = id; self.name = name; self.address = address; self.provider = provider; self.status = status
    }
}

public enum FolderRole: String, CaseIterable, Sendable { case inbox, sent, drafts, archive, trash, custom }
public struct MailFolder: Identifiable, Hashable, Sendable {
    public let id: FolderID
    public let accountID: AccountID
    public let providerID: String
    public let name: String
    public let role: FolderRole
    public init(id: FolderID, accountID: AccountID, providerID: String, name: String, role: FolderRole) throws {
        guard !providerID.isEmpty, providerID.utf8.count <= 2048 else { throw DomainError.invalidLocator }
        self.id = id; self.accountID = accountID; self.providerID = providerID; self.name = name; self.role = role
    }
}

public enum ProviderLocator: Hashable, Sendable {
    case gmail(id: String)
    case graph(immutableID: String)
    case imap(mailbox: String, uidValidity: UInt32, uid: UInt32)

    public var kind: ProviderKind {
        switch self { case .gmail: .gmail; case .graph: .microsoft; case .imap: .imap }
    }
    public var isValid: Bool {
        switch self {
        case .gmail(let id), .graph(let id): !id.isEmpty && id.utf8.count <= 2048
        case .imap(let mailbox, let validity, let uid): !mailbox.isEmpty && mailbox.utf8.count <= 2048 && validity > 0 && uid > 0
        }
    }
}

public struct MailPerson: Hashable, Codable, Sendable {
    public let name: String
    public let address: EmailAddress
    public init(name: String, address: EmailAddress) { self.name = name; self.address = address }
    public var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? address.value : name
    }
}

public struct MailThread: Identifiable, Hashable, Sendable {
    public let id: ThreadID
    public let accountID: AccountID
    public let subject: String
    public init(id: ThreadID, accountID: AccountID, subject: String) {
        self.id = id; self.accountID = accountID; self.subject = subject
    }
}

public struct AttachmentMetadata: Identifiable, Hashable, Sendable {
    public let id: AttachmentID
    public let messageID: MessageID
    public let accountID: AccountID
    public let filename: String
    public let mimeType: String
    public let byteCount: Int64
    public let isInline: Bool
    public let providerPartID: String?
    public let contentID: String?
    public init(id: AttachmentID, messageID: MessageID, accountID: AccountID, filename: String,
                mimeType: String, byteCount: Int64, isInline: Bool = false, providerPartID: String? = nil, contentID: String? = nil) throws {
        guard byteCount >= 0, (providerPartID?.utf8.count ?? 0) <= 512, (contentID?.utf8.count ?? 0) <= 2048 else { throw DomainError.invalidSize }
        self.id = id; self.messageID = messageID; self.accountID = accountID
        self.filename = filename; self.mimeType = mimeType; self.byteCount = byteCount; self.isInline = isInline
        self.providerPartID = providerPartID; self.contentID = contentID
    }
}

/// Metadata only. No original MIME, HTML or attachment bytes are representable here.
public struct MailMessage: Identifiable, Hashable, Sendable {
    public let id: MessageID
    public let accountID: AccountID
    public let locator: ProviderLocator
    public let threadID: ThreadID?
    public let folderIDs: Set<FolderID>
    public let internetMessageID: String?
    public let inReplyTo: String?
    public let references: [String]
    public let threadingHeadersLoaded: Bool
    public let subject: String
    public let sender: MailPerson
    public let recipients: [MailPerson]
    public let ccRecipients: [MailPerson]
    public let replyTo: [MailPerson]
    public let receivedAt: Date
    public let isUnread: Bool
    public let isFlagged: Bool
    public let preview: String?
    public let attachments: [AttachmentMetadata]

    public init(id: MessageID, accountID: AccountID, locator: ProviderLocator, threadID: ThreadID?,
                folderIDs: Set<FolderID>, internetMessageID: String? = nil, subject: String,
                sender: MailPerson, recipients: [MailPerson], receivedAt: Date,
                isUnread: Bool, isFlagged: Bool, preview: String?, attachments: [AttachmentMetadata] = [],
                inReplyTo: String? = nil, references: [String] = [], threadingHeadersLoaded: Bool = false,
                ccRecipients: [MailPerson] = [], replyTo: [MailPerson] = []) throws {
        guard references.count <= 100, references.allSatisfy({ $0.utf8.count <= 1024 }),
              (inReplyTo?.utf8.count ?? 0) <= 1024 else { throw DomainError.invalidLocator }
        guard locator.isValid else { throw DomainError.invalidLocator }
        guard attachments.allSatisfy({ $0.messageID == id && $0.accountID == accountID }) else { throw DomainError.crossAccountReference }
        guard Set(attachments.map(\.id)).count == attachments.count else { throw DomainError.duplicateID }
        self.id = id; self.accountID = accountID; self.locator = locator; self.threadID = threadID
        self.folderIDs = folderIDs; self.internetMessageID = internetMessageID; self.subject = subject
        self.inReplyTo = inReplyTo; self.references = references; self.threadingHeadersLoaded = threadingHeadersLoaded
        self.sender = sender; self.recipients = recipients; self.receivedAt = receivedAt
        self.ccRecipients = ccRecipients; self.replyTo = replyTo
        self.isUnread = isUnread; self.isFlagged = isFlagged; self.preview = preview; self.attachments = attachments
    }
}

/// Validate the entire graph at a repository boundary, including empty accounts/threads.
public struct MailSnapshot: Sendable {
    public let accounts: [MailAccount]
    public let folders: [MailFolder]
    public let threads: [MailThread]
    public let messages: [MailMessage]

    public init(accounts: [MailAccount], folders: [MailFolder], threads: [MailThread], messages: [MailMessage]) throws {
        guard Set(accounts.map(\.id)).count == accounts.count,
              Set(folders.map(\.id)).count == folders.count,
              Set(threads.map(\.id)).count == threads.count,
              Set(messages.map(\.id)).count == messages.count else { throw DomainError.duplicateID }
        let accountMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let folderMap = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let threadMap = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        guard folders.allSatisfy({ accountMap[$0.accountID] != nil }), threads.allSatisfy({ accountMap[$0.accountID] != nil })
        else { throw DomainError.unknownAccount }
        for message in messages {
            guard let account = accountMap[message.accountID] else { throw DomainError.unknownAccount }
            guard account.provider == message.locator.kind else { throw DomainError.inconsistentProvider }
            guard message.folderIDs.allSatisfy({ folderMap[$0]?.accountID == message.accountID }),
                  message.threadID.map({ threadMap[$0]?.accountID == message.accountID }) ?? true
            else { throw DomainError.crossAccountReference }
        }
        self.accounts = accounts; self.folders = folders; self.threads = threads; self.messages = messages
    }
}
