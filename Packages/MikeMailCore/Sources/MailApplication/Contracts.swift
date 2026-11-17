import Foundation
import MailDomain

public enum MailFailure: Error, Equatable, Sendable {
    case offline, authenticationExpired, rateLimited(retryAfter: TimeInterval)
    case permissionDenied, notFound, invalidInput, unsupported, providerFailure
}

public struct AccessScope: Sendable {
    public let accountIDs: Set<AccountID>
    public let folderIDs: Set<FolderID>?
    /// nil folderIDs means all folders of the explicitly allowed accounts; [] means none.
    public init(accountIDs: Set<AccountID>, folderIDs: Set<FolderID>? = nil) {
        self.accountIDs = accountIDs; self.folderIDs = folderIDs
    }
    public func permits(_ message: MailMessage) -> Bool {
        accountIDs.contains(message.accountID) && (folderIDs.map { !$0.isDisjoint(with: message.folderIDs) } ?? true)
    }
}

public struct MessageFilter: Equatable, Sendable {
    public var text: String = ""
    public var accountID: AccountID?
    public var folderID: FolderID?
    public var role: FolderRole?
    public var unreadOnly = false
    public var flaggedOnly = false
    public var includeIndexedText = true
    public var receivedAfter: Date?
    public var timeZoneID: String = TimeZone.current.identifier
    public init() {}
    public func searchQuery() throws -> MailSearchQuery {
        guard let zone = TimeZone(identifier: timeZoneID) else { throw MailFailure.invalidInput }
        return try MailSearchParser.parse(text, timeZone: zone)
    }
}

public struct PageRequest: Sendable {
    public let limit: Int
    public let cursor: String?
    public init(limit: Int = 20, cursor: String? = nil) throws {
        guard (1...100).contains(limit), (cursor?.utf8.count ?? 0) <= 256 else { throw MailFailure.invalidInput }
        self.limit = limit; self.cursor = cursor
    }
}

public struct SearchCoverage: Sendable {
    public let isSynthetic: Bool
    public let metadataOnly: Bool
    public let messageCount: Int
    public let oldest: Date?
    public let newest: Date?
    public let indexedTextCount: Int
    public let eligibleMessageCount: Int
    public let truncatedTextCount: Int
    public let folders: [SearchFolderCoverage]
    public init(isSynthetic: Bool, metadataOnly: Bool, messageCount: Int, oldest: Date?, newest: Date?,
                indexedTextCount: Int = 0, eligibleMessageCount: Int? = nil, truncatedTextCount: Int = 0, folders: [SearchFolderCoverage] = []) {
        self.isSynthetic = isSynthetic; self.metadataOnly = metadataOnly; self.messageCount = messageCount
        self.oldest = oldest; self.newest = newest
        self.indexedTextCount = indexedTextCount; self.eligibleMessageCount = eligibleMessageCount ?? messageCount
        self.truncatedTextCount = truncatedTextCount; self.folders = folders
    }
}
public struct SearchFolderCoverage: Sendable {
    public let accountID: AccountID
    public let folderID: FolderID
    public let name: String
    public let indexedCount: Int
    public let serverCount: Int?
    public let lastSuccess: Date?
    public let isComplete: Bool
    public init(accountID: AccountID, folderID: FolderID, name: String, indexedCount: Int, serverCount: Int?, lastSuccess: Date?, isComplete: Bool = false) {
        self.accountID = accountID; self.folderID = folderID; self.name = name
        self.indexedCount = indexedCount; self.serverCount = serverCount; self.lastSuccess = lastSuccess; self.isComplete = isComplete
    }
}
public struct MessagePage: Sendable {
    public let items: [MailMessage]
    public let nextCursor: String?
    public let coverage: SearchCoverage
    public init(items: [MailMessage], nextCursor: String?, coverage: SearchCoverage) {
        self.items = items; self.nextCursor = nextCursor; self.coverage = coverage
    }
}

public protocol MailMetadataRepository: Sendable {
    func accounts(in scope: AccessScope) async throws -> [MailAccount]
    func folders(in scope: AccessScope) async throws -> [MailFolder]
    func messages(filter: MessageFilter, page: PageRequest, in scope: AccessScope) async throws -> MessagePage
    func message(id: MessageID, in scope: AccessScope) async throws -> MailMessage
    func thread(id: ThreadID, page: PageRequest, in scope: AccessScope) async throws -> MessagePage
}

public struct ProviderCapabilities: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let labels = Self(rawValue: 1 << 0)
    public static let onlineSearch = Self(rawValue: 1 << 1)
    public static let delta = Self(rawValue: 1 << 2)
    public static let idle = Self(rawValue: 1 << 3)
    public static let providerThreads = Self(rawValue: 1 << 4)
    public static let drafts = Self(rawValue: 1 << 5)
    public static let send = Self(rawValue: 1 << 6)
}

public struct ContentRequest: Sendable {
    public let accountID: AccountID
    public let locator: ProviderLocator
    public let maximumBytes: Int
    public init(accountID: AccountID, locator: ProviderLocator, maximumBytes: Int) throws {
        guard locator.isValid, maximumBytes > 0 && maximumBytes <= 10 * 1024 * 1024 else { throw MailFailure.invalidInput }
        self.accountID = accountID; self.locator = locator; self.maximumBytes = maximumBytes
    }
}

/// No mark-as-read argument: every implementation MUST use side-effect-free reads (IMAP PEEK).
/// Implementations are responsible for timeouts, cancellation, pagination and response limits.
public protocol MailReadProvider: Sendable {
    var accountID: AccountID { get }
    var capabilities: ProviderCapabilities { get }
    func testConnection() async throws
    func listFolders(page: PageRequest) async throws -> [MailFolder]
    func listMetadata(folder: FolderID, page: PageRequest) async throws -> MessagePage
    func fetchPlainText(_ request: ContentRequest) async throws -> String
}

/// A separate future write boundary. Phase 0 has no implementation and no access to it in the UI/bridge.
public protocol MailWriteProvider: Sendable {
    func setReadStatus(message: MessageID, account: AccountID, isRead: Bool) async throws
    func setFlagged(message: MessageID, account: AccountID, isFlagged: Bool) async throws
    func moveToTrash(message: MessageID, account: AccountID) async throws
}

public struct CredentialReference: Hashable, Sendable {
    public let accountID: AccountID
    public let purpose: Purpose
    public enum Purpose: String, Sendable { case incomingPassword, outgoingPassword, oauthRefreshToken }
    public init(accountID: AccountID, purpose: Purpose) { self.accountID = accountID; self.purpose = purpose }
}

/// Secret values must never be logged or Codable. Implemented by MailSecurity in phase 1.
public protocol CredentialStore: Sendable {
    func read(_ reference: CredentialReference) async throws -> Data?
    func save(_ secret: Data, for reference: CredentialReference) async throws
    func delete(_ reference: CredentialReference) async throws
}

public protocol ProviderAuthentication: Sendable {
    func authenticate(account: AccountID) async throws
    func revoke(account: AccountID) async throws
}

/// Future bounded HTTP adapter. No URLSession/transport is instantiated in phase 0.
public protocol ProviderTransport: Sendable {
    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse)
}
