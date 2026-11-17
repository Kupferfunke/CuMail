import Foundation
import MailDomain

public enum GmailPermission: String, Codable, CaseIterable, Sendable {
    case readOnly, manageMail
    public var scope: String { "https://www.googleapis.com/auth/gmail." + (self == .readOnly ? "readonly" : "modify") }
}

/// Public registration only. OAuth state is held separately by CredentialStore.
public struct GmailConfiguration: Equatable, Sendable {
    public let accountID: AccountID
    public let clientID: String
    public let permission: GmailPermission
    public init(accountID: AccountID, clientID: String, permission: GmailPermission) throws {
        guard clientID.hasSuffix(".apps.googleusercontent.com"), (30...200).contains(clientID.utf8.count),
              clientID.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 })
        else { throw MailFailure.invalidInput }
        self.accountID = accountID; self.clientID = clientID; self.permission = permission
    }
}

public enum GmailFailure: Error, Equatable, Sendable {
    case accessDenied(operation: String, reason: String)
    case cancelled, busy, timeout, invalidResponse, tooLarge, historyExpired, historyLimit
    case missingClient, noBody, pendingAction, insufficientScope
    case clientSecretRequired, invalidClient, authenticationFailed
}

public enum GmailIdentity {
    public static let archive = "__ARCHIVE__"
    public static func folder(account: AccountID, label: String) throws -> FolderID {
        try IMAPIdentity.folder(account: account, mailbox: "gmail:" + label)
    }
    public static func message(account: AccountID, id: String) throws -> MessageID {
        try IMAPIdentity.message(account: account, mailbox: "gmail:" + id, validity: 1, uid: 1)
    }
    public static func thread(account: AccountID, id: String) throws -> ThreadID {
        try IMAPIdentity.thread(account: account, key: "gmail:" + id)
    }
    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 256 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

public struct GmailProfile: Sendable {
    public let email: String
    public let historyID: String
    public let messageCount: Int?
    public init(email: String, historyID: String, messageCount: Int? = nil) {
        self.email = email; self.historyID = historyID; self.messageCount = messageCount
    }
}
public struct GmailHistory: Sendable {
    public let changedIDs: Set<String>
    public let historyID: String
    public init(changedIDs: Set<String>, historyID: String) { self.changedIDs = changedIDs; self.historyID = historyID }
}
public struct GmailCheckpoint: Sendable {
    public let historyID: String?
    public let labels: Set<String>
    public let knownIDs: Set<String>
    public init(historyID: String?, labels: Set<String>, knownIDs: Set<String>) {
        self.historyID = historyID; self.labels = labels; self.knownIDs = knownIDs
    }
}
public struct GmailBatch: Sendable {
    public static let windowLimit = 200
    public static let labelLimit = 5
    public let folders: [MailFolder]
    public let messages: [MailMessage]
    public let providerThreads: [ThreadID: String]
    public let wantedIDs: Set<String>
    public let labels: Set<String>
    public let historyID: String
    public init(folders: [MailFolder], messages: [MailMessage], providerThreads: [ThreadID: String],
                wantedIDs: Set<String>, labels: Set<String>, historyID: String) throws {
        guard folders.count <= 500, labels.count <= Self.labelLimit, !labels.isEmpty,
              wantedIDs.count <= Self.windowLimit * Self.labelLimit, wantedIDs.allSatisfy(GmailIdentity.validID),
              !historyID.isEmpty, historyID.count <= 64, historyID.allSatisfy(\.isNumber),
              messages.count <= wantedIDs.count else { throw GmailFailure.invalidResponse }
        self.folders = folders; self.messages = messages; self.providerThreads = providerThreads
        self.wantedIDs = wantedIDs; self.labels = labels; self.historyID = historyID
    }
}
public protocol GmailReadAPI: Sendable {
    var accountID: AccountID { get }
    func profile() async throws -> GmailProfile
    func folders() async throws -> [MailFolder]
    func messageIDs(label: String, limit: Int, query: String?) async throws -> [String]
    func history(since: String) async throws -> GmailHistory
    func metadata(id: String, folders: [MailFolder]) async throws -> (MailMessage, String)
    func body(id: String, preferHTML: Bool, maximumBytes: Int) async throws -> MailBody
    func draftVersion(id: String) async throws -> GmailDraftReceipt
    func findDraft(internetMessageID: String) async throws -> GmailDraftReceipt?
}
public protocol GmailAPI: GmailReadAPI {
    func modify(id: String, adding: [String], removing: [String]) async throws
    func send(raw: Data, draftID: String?) async throws -> String
    func saveDraft(raw: Data, draftID: String?) async throws -> GmailDraftReceipt
}
/// Reports history discovery before metadata retrieval. Removed labels absent
/// from the authoritative catalog need no per-message metadata fetch.
public protocol GmailHistoryProgressAPI: GmailReadAPI {
    func history(since: String, existingLabelIDs: Set<String>?,
                 progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> GmailHistory
}
public protocol GmailSyncReportingAPI: GmailAPI {
    func reportingSyncProgress(_ progress: @escaping @Sendable (GmailSyncProgress) async -> Void) -> any GmailAPI
}
public protocol GmailIndex: Sendable {
    func gmailConfigurations() async throws -> [GmailConfiguration]
    func saveGmailAccount(_ account: MailAccount, configuration: GmailConfiguration, folders: [MailFolder]) async throws
    func gmailCheckpoint(account: AccountID) async throws -> GmailCheckpoint
    func applyGmailBatch(_ batch: GmailBatch, account: MailAccount) async throws
    func setGmailStatus(_ status: AccountStatus, account: AccountID) async throws
    func gmailPendingAction(account: AccountID) async throws -> Bool
    func setGmailPendingAction(_ pending: Bool, account: AccountID) async throws
    func resetGmailCoverage(account: AccountID) async throws
    /// Reconciles the catalog and memberships, never deletes messages or advances history.
    func reconcileGmailFolders(_ folders: [MailFolder], account: MailAccount) async throws
}
public typealias GmailFactory = @Sendable (GmailConfiguration) -> any GmailAPI

public struct GmailDraftReceipt: Sendable, Equatable {
    public let id: String
    public let messageID: String
    public init(id: String, messageID: String) { self.id = id; self.messageID = messageID }
}
public struct GmailDraftBinding: Sendable, Equatable {
    public let receipt: GmailDraftReceipt?
    public let revision: Int
    public let pending: Bool
    public init(receipt: GmailDraftReceipt?, revision: Int, pending: Bool) { self.receipt = receipt; self.revision = revision; self.pending = pending }
}
public protocol GmailDraftRepository: DraftRepository {
    func gmailDraftBinding(id: UUID, account: AccountID) async throws -> GmailDraftBinding?
    func setGmailDraftBinding(_ binding: GmailDraftBinding, id: UUID, account: AccountID) async throws
}
