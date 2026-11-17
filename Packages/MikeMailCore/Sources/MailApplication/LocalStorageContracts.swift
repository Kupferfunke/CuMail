import Foundation
import MailDomain

public enum LocalStoreFailure: Error, Equatable, Sendable {
    case unavailable, wrongKeyOrCorrupt, missingKey, incompatibleSchema
    case invalidInput, textIndexDisabled, budgetExceeded, cleanupPending
    case conflictingDataLocations, invalidBackup
}
public enum TextExtractionSource: String, Sendable { case plainText, sanitizedHTML, legacyUnknown }
public struct StoredTextExtract: Sendable {
    public let text: String
    public let source: TextExtractionSource
    public let version: Int
    public let indexedAt: Date
    public let byteCount: Int
    public let originalByteCount: Int
    public let truncated: Bool
    public init(text: String, source: TextExtractionSource, version: Int, indexedAt: Date, byteCount: Int, originalByteCount: Int, truncated: Bool) {
        self.text = text; self.source = source; self.version = version; self.indexedAt = indexedAt
        self.byteCount = byteCount; self.originalByteCount = originalByteCount; self.truncated = truncated
    }
}

public struct AccountSettings: Equatable, Sendable {
    public let accountID: AccountID
    public var displayName: String
    public var textIndexEnabled: Bool
    public var serverActionsEnabled: Bool
    public var fullTextIndexEnabled: Bool
    public var markReadAfterSeconds: Int
    public var messageTextLimit: Int
    public var accountTextBudget: Int

    public init(accountID: AccountID, displayName: String, textIndexEnabled: Bool = false,
                messageTextLimit: Int = 256 * 1024, accountTextBudget: Int = 250 * 1024 * 1024, serverActionsEnabled: Bool = false,
                fullTextIndexEnabled: Bool = false, markReadAfterSeconds: Int = 0) throws {
        self.accountID = accountID; self.displayName = displayName
        self.textIndexEnabled = textIndexEnabled; self.messageTextLimit = messageTextLimit
        self.accountTextBudget = accountTextBudget; self.serverActionsEnabled = serverActionsEnabled
        self.fullTextIndexEnabled = fullTextIndexEnabled; self.markReadAfterSeconds = markReadAfterSeconds
        try validate()
    }

    public func validate() throws {
        guard [0, 2, 5].contains(markReadAfterSeconds), !fullTextIndexEnabled || textIndexEnabled,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              displayName.count <= 80, displayName.utf8.count <= 512,
              !displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (1...256 * 1024).contains(messageTextLimit),
              (messageTextLimit...250 * 1024 * 1024).contains(accountTextBudget)
        else { throw LocalStoreFailure.invalidInput }
    }
}

public struct LocalIndexSummary: Sendable {
    public let accountCount: Int
    public let messageCount: Int
    public let indexedTextCount: Int
    public let extractBytes: Int
    public let databaseBytes: Int64
    public let temporaryBytes: Int64
    public let schemaVersion: Int
    public let cipherVersion: String
    public init(accountCount: Int, messageCount: Int, indexedTextCount: Int, extractBytes: Int,
                databaseBytes: Int64, temporaryBytes: Int64, schemaVersion: Int, cipherVersion: String) {
        self.accountCount = accountCount; self.messageCount = messageCount
        self.indexedTextCount = indexedTextCount; self.extractBytes = extractBytes
        self.databaseBytes = databaseBytes; self.temporaryBytes = temporaryBytes
        self.schemaVersion = schemaVersion; self.cipherVersion = cipherVersion
    }
}

/// The key has its own namespace and is never a field in the mail database.
public protocol DatabaseKeyStore: Sendable {
    func databaseKey(createIfMissing: Bool) async throws -> Data
    func deleteDatabaseKey() async throws
}

/// Local maintenance is separate from provider mutations and from ReadOnlyMailService.
public protocol LocalMailMaintenance: Sendable {
    func settings(for account: AccountID) async throws -> AccountSettings
    func saveSettings(_ settings: AccountSettings) async throws
    func storeExtract(_ text: String, for message: MessageID, account: AccountID) async throws
    func removeAccount(_ account: AccountID) async throws
    func clearLocalData() async throws
    func rebuildIndex() async throws
    func restoreSyntheticData() async throws
    func summary() async throws -> LocalIndexSummary
}
