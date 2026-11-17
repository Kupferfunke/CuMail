import Foundation
import MailDomain

public struct ContentIndexProgress: Sendable, Equatable {
    public let accountID: AccountID
    public let enabled: Bool
    public let total: Int
    public let indexed: Int
    public let truncated: Int
    public let skipped: Int
    public let retrying: Int
    public let bytes: Int
    public let budget: Int
    public var pending: Int { max(0, total - indexed - skipped) }
    public init(accountID: AccountID, enabled: Bool, total: Int, indexed: Int, truncated: Int,
                skipped: Int, retrying: Int, bytes: Int, budget: Int) {
        self.accountID = accountID; self.enabled = enabled; self.total = total; self.indexed = indexed
        self.truncated = truncated; self.skipped = skipped; self.retrying = retrying; self.bytes = bytes; self.budget = budget
    }
}
public enum ContentIndexIssue: String, Sendable { case unavailable, noText, tooLarge }
