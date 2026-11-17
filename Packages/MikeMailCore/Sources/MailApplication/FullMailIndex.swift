import Foundation
import MailDomain

/// Durable pagination state. A partial scan adds metadata but never prunes old mail.
public struct FullMailScan: Sendable, Equatable {
    public let accountID: AccountID
    public let scope: String
    public let generation: String
    public let cursor: String?
    public let anchor: String?
    public let indexedCount: Int
    public init(accountID: AccountID, scope: String, generation: String, cursor: String?, anchor: String?, indexedCount: Int = 0) {
        self.accountID = accountID; self.scope = scope; self.generation = generation
        self.cursor = cursor; self.anchor = anchor
        self.indexedCount = indexedCount
    }
}

public protocol FullMailIndex: Sendable {
    func fullMailScan(account: AccountID, scope: String, anchor: String?) async throws -> FullMailScan
    func resetFullMailScan(account: AccountID, scope: String) async throws
    /// The cursor and page are committed together. nil nextCursor completes the scan.
    func applyFullMailPage(_ scan: FullMailScan, account: MailAccount, folders: [MailFolder],
                          messages: [MailMessage], providerThreads: [ThreadID: String],
                          nextCursor: String?, uidValidity: UInt32?, serverCount: Int?, flags: [IMAPFlags]?) async throws -> Int
    func fullGmailHistory(account: AccountID) async throws -> String?
    func applyGmailChanges(account: MailAccount, folders: [MailFolder], messages: [MailMessage],
                           providerThreads: [ThreadID: String], removedIDs: Set<String>, historyID: String?) async throws
}

public struct GmailMessagePage: Sendable {
    public let ids: [String]
    public let nextCursor: String?
    public init(ids: [String], nextCursor: String?) { self.ids = ids; self.nextCursor = nextCursor }
}
public protocol GmailPagedReadAPI: GmailReadAPI {
    /// All messages, including Spam and Trash; no label or date restriction.
    func allMessageIDs(cursor: String?) async throws -> GmailMessagePage
}
