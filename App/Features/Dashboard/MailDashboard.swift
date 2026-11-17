import Foundation
import MailDomain
import MailApplication

/// Metadata-only overview. Totals always come from search coverage, never a loaded page.
struct MailDashboard: Sendable {
    struct Account: Identifiable, Sendable {
        let account: MailAccount
        let inbox: Int
        let unread: Int
        let total: Int
        let lastSync: Date?
        let complete: Bool
        var id: AccountID { account.id }
    }
    struct Day: Identifiable, Sendable {
        let date: Date
        let end: Date
        let count: Int
        let query: String
        var id: Date { date }
    }
    let accounts: [Account]
    let days: [Day]
    let recentUnread: [MailMessage]
    let flagged: Int
    let refreshedAt: Date
    var inbox: Int { accounts.reduce(0) { $0 + $1.inbox } }
    var unread: Int { accounts.reduce(0) { $0 + $1.unread } }
    var total: Int { accounts.reduce(0) { $0 + $1.total } }
    var weekTotal: Int { days.reduce(0) { $0 + $1.count } }

    static func load(service: InboxService, scope: AccessScope, now: Date = Date(),
                     timeZone: TimeZone = .current) async throws -> MailDashboard {
        let page = try PageRequest(limit: 1)
        let allowed = try await service.accounts(scope: scope)
        var accounts: [Account] = []
        for account in allowed {
            try Task.checkCancellation()
            var query = MessageFilter(); query.accountID = account.id
            let all = try await service.search(query, page: page, scope: scope).coverage
            query.role = .inbox
            let inbox = try await service.search(query, page: page, scope: scope).coverage.messageCount
            query.unreadOnly = true
            let unread = try await service.search(query, page: page, scope: scope).coverage.messageCount
            accounts.append(Account(account: account, inbox: inbox, unread: unread, total: all.messageCount,
                lastSync: all.folders.compactMap(\.lastSuccess).max(),
                complete: !all.folders.isEmpty && all.folders.allSatisfy(\.isComplete)))
        }
        var unread = MessageFilter(); unread.role = .inbox; unread.unreadOnly = true
        let recent = try await service.search(unread, page: PageRequest(limit: 4), scope: scope).items
        var flagged = MessageFilter(); flagged.flaggedOnly = true
        let favorites = try await service.search(flagged, page: page, scope: scope).coverage.messageCount
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        let formatter = DateFormatter(); formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        var days: [Day] = []
        for offset in -6...0 {
            try Task.checkCancellation()
            guard let date = calendar.date(byAdding: .day, value: offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: date) else { throw MailFailure.invalidInput }
            // Calendar boundaries respect DST. These exact filters also power chart navigation.
            let text = "after:\(formatter.string(from: date)) before:\(formatter.string(from: end))"
            var query = MessageFilter(); query.role = .inbox; query.text = text; query.timeZoneID = timeZone.identifier
            let count = try await service.search(query, page: page, scope: scope).coverage.messageCount
            days.append(Day(date: date, end: end, count: count, query: text))
        }
        try Task.checkCancellation()
        return MailDashboard(accounts: accounts, days: days, recentUnread: recent, flagged: favorites, refreshedAt: now)
    }
}
