import Foundation
import MailDomain

/// One explicitly requested page. Results remain in RAM and never advance the rolling sync checkpoint.
public struct OnlineSearchPage: Sendable {
    public let items: [MailMessage]
    public let nextCursor: String?
    public let indexedFlags: [IMAPFlags]?
    public let uidValidity: UInt32?
    public let checkedAt: Date
    public let totalMessagesInFolder: Int
    public init(items: [MailMessage], nextCursor: String?, totalMessagesInFolder: Int, checkedAt: Date = Date(), uidValidity: UInt32? = nil, indexedFlags: [IMAPFlags]? = nil) {
        self.indexedFlags = indexedFlags; self.uidValidity = uidValidity; self.items = items; self.nextCursor = nextCursor
        self.totalMessagesInFolder = totalMessagesInFolder; self.checkedAt = checkedAt
    }
}
public protocol IMAPSearchSession: IMAPReadSession {
    func search(folder: MailFolder, query: MailSearchQuery, page: PageRequest) async throws -> OnlineSearchPage
}

public protocol IMAPCatalogSession: IMAPSearchSession {
    func catalog(folder: MailFolder, checkpoint: IMAPCheckpoint?, page: PageRequest) async throws -> OnlineSearchPage
}
