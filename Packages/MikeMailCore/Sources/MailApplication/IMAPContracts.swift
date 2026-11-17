import Foundation
import CryptoKit
import MailDomain
import MailRendering

public enum IMAPSecurity: String, CaseIterable, Sendable { case implicitTLS, startTLS }

/// Non-secret connection settings. No URL, command, credential or plaintext transport is accepted.
public struct IMAPConfiguration: Hashable, Sendable {
    public let accountID: AccountID
    public let host: String
    public let port: Int
    public let security: IMAPSecurity
    public let username: String
    public init(accountID: AccountID, host: String, port: Int, security: IMAPSecurity, username: String) throws {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !host.isEmpty, host.utf8.count <= 253, labels.allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" &&
            $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }), (1...65535).contains(port), !username.isEmpty, username.utf8.count <= 254,
        !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MailFailure.invalidInput
        }
        self.accountID = accountID; self.host = host.lowercased(); self.port = port
        self.security = security; self.username = username
    }
}

public enum IMAPFailure: Error, Equatable, Sendable {
    case busy, cancelled, timeout, connection, authentication, invalidResponse, mailboxChanged
    case noPlainText, contentTooLarge, missingCredential, unsupportedAction, unconfirmedAction, reconciliationRequired
}

public struct IMAPFlags: Sendable, Equatable {
    public let uid: UInt32
    public let unread: Bool
    public let flagged: Bool
    public init(uid: UInt32, unread: Bool, flagged: Bool) {
        self.uid = uid; self.unread = unread; self.flagged = flagged
    }
}

public struct IMAPCheckpoint: Sendable {
    public let uidValidity: UInt32
    public let knownUIDs: Set<UInt32>
    public init(uidValidity: UInt32, knownUIDs: Set<UInt32>) {
        self.uidValidity = uidValidity; self.knownUIDs = knownUIDs
    }
}

/// Complete rolling window, plus metadata for only the UIDs absent from the checkpoint.
public struct IMAPFolderBatch: Sendable {
    public static let windowLimit = 200
    public let uidValidity: UInt32
    public let totalOnServer: Int
    public let flags: [IMAPFlags]
    public let newMessages: [MailMessage]
    public init(uidValidity: UInt32, totalOnServer: Int, flags: [IMAPFlags], newMessages: [MailMessage]) throws {
        guard uidValidity > 0, totalOnServer >= flags.count, flags.count <= Self.windowLimit,
              flags.allSatisfy({ $0.uid > 0 }), Set(flags.map(\.uid)).count == flags.count,
              newMessages.count <= flags.count else { throw IMAPFailure.invalidResponse }
        self.uidValidity = uidValidity; self.totalOnServer = totalOnServer
        self.flags = flags; self.newMessages = newMessages
    }
}

public struct IMAPSyncSummary: Sendable {
    public let folderID: FolderID
    public let indexedCount: Int
    public let totalOnServer: Int
    public let lastSuccess: Date
    public init(folderID: FolderID, indexedCount: Int, totalOnServer: Int, lastSuccess: Date) {
        self.folderID = folderID; self.indexedCount = indexedCount
        self.totalOnServer = totalOnServer; self.lastSuccess = lastSuccess
    }
}

/// No provider mutation, raw-message or attachment-download capability.
public protocol IMAPReadSession: Sendable {
    func connect() async throws
    func folders() async throws -> [MailFolder]
    func readFolder(_ folder: MailFolder, checkpoint: IMAPCheckpoint?) async throws -> IMAPFolderBatch
    func plainText(_ request: ContentRequest) async throws -> String
    func body(_ request: ContentRequest, preferHTML: Bool) async throws -> MailBody
    func disconnect() async
}
public struct MailBody: Sendable {
    public enum Format: Sendable { case plainText, html }
    public let text: String
    public let format: Format
    public let inlineImages: [String: InlineMailImage]
    public init(text: String, format: Format, inlineImages: [String: InlineMailImage] = [:]) {
        self.text = text; self.format = format; self.inlineImages = inlineImages
    }
}
public extension IMAPReadSession {
    func body(_ request: ContentRequest, preferHTML: Bool) async throws -> MailBody {
        MailBody(text: try await plainText(request), format: .plainText)
    }
}

/// Deliberate UI actions only. No delete/expunge or sending capability is exposed.
public enum MailMutation: Sendable, Equatable {
    case read(Bool), flagged(Bool), move(MailFolder)
}
public protocol IMAPWriteSession: IMAPReadSession {
    func perform(_ mutation: MailMutation, on message: MailMessage) async throws
}
public struct PendingMailAction: Sendable, Equatable {
    public let id: UUID
    public let accountID: AccountID
    public let sourceFolder: FolderID
    public let targetFolder: FolderID?
    public init(id: UUID = UUID(), accountID: AccountID, sourceFolder: FolderID, targetFolder: FolderID?) {
        self.id = id; self.accountID = accountID; self.sourceFolder = sourceFolder; self.targetFolder = targetFolder
    }
}
public typealias IMAPSessionFactory = @Sendable (IMAPConfiguration, String) -> any IMAPReadSession

public protocol IMAPIndex: Sendable {
    func imapConfigurations() async throws -> [IMAPConfiguration]
    func addIMAPAccount(_ account: MailAccount, configuration: IMAPConfiguration, folders: [MailFolder]) async throws
    func updateIMAPFolders(account: AccountID, folders: [MailFolder]) async throws
    func imapCheckpoint(account: AccountID, folder: FolderID) async throws -> IMAPCheckpoint?
    func applyIMAPBatch(_ batch: IMAPFolderBatch, account: MailAccount, folder: MailFolder) async throws
    func setConnectionStatus(_ status: AccountStatus, account: AccountID) async throws
    func imapSummaries() async throws -> [IMAPSyncSummary]
    func pendingMailActions(account: AccountID) async throws -> [PendingMailAction]
    func beginMailAction(_ action: PendingMailAction, message: MailMessage) async throws
    func finishMailAction(_ id: UUID, account: AccountID) async throws
}


/// Opaque local IDs derived using the system hash, namespaced by account and provider identity.
/// Sequence numbers and Internet Message-ID are deliberately excluded.
public enum IMAPIdentity {
    public static func folder(account: AccountID, mailbox: String) throws -> FolderID {
        try EntityID(uuid(["folder", account.description, mailbox]))
    }
    public static func message(account: AccountID, mailbox: String, validity: UInt32, uid: UInt32) throws -> MessageID {
        try EntityID(uuid(["message", account.description, mailbox, String(validity), String(uid)]))
    }
    public static func attachment(message: MessageID, section: String) throws -> AttachmentID {
        try EntityID(uuid(["attachment", message.description, section]))
    }
    public static func thread(account: AccountID, key: String) throws -> ThreadID {
        try EntityID(uuid(["thread", account.description, key]))
    }
    private static func uuid(_ parts: [String]) throws -> UUID {
        let input = try JSONEncoder().encode(parts)
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}
