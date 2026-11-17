import Foundation
import SwiftUI
import AppKit
import Testing
import MailDomain
import MailApplication
@testable import MailDemo
@testable import MikeMailHub

@Suite(.serialized) @MainActor
struct DashboardTests {
    private let now = Date(timeIntervalSince1970: 1794052800)
    private var zone: TimeZone { TimeZone(identifier: "Europe/Zurich")! }

    private func fixture(at now: Date) throws -> DemoDataset {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let today = calendar.startOfDay(for: now)
        let identities = [("KupferFunke", "kupferfunke.ch"), ("PadelVision", "padelvision.ch"), ("Sense of Time", "senseoftime.ch"), ("Privat", "gmail.com")]
        let accounts = try identities.enumerated().map { index, item in
            MailAccount(id: try AccountID(), name: item.0, address: try EmailAddress("demo@" + item.1), provider: index == 3 ? .gmail : .imap)
        }
        let folders = try accounts.flatMap { account in
            try [(.inbox, "Posteingang"), (.archive, "Archiv")].map { (role: FolderRole, name: String) in
                try MailFolder(id: FolderID(), accountID: account.id, providerID: role.rawValue, name: name, role: role)
            }
        }
        var messages: [MailMessage] = []
        let counts = [4, 2, 8, 5, 3, 7, 6]
        let subjects = ["Ein neuer Funke für unser Projekt", "Die nächste Runde ist geplant", "Zeit für die schönen Dinge", "Ein Gruss zum Wochenende"]
        func append(at date: Date, inbox: Bool) throws {
            let index = messages.count, account = accounts[messages.count % accounts.count]
            let folder = folders.first { $0.accountID == account.id && $0.role == (inbox ? .inbox : .archive) }!
            var ids: Set<FolderID> = [folder.id]
            if index == 0 { ids.insert(folders.first { $0.accountID == account.id && $0.role == .archive }!.id) }
            messages.append(try MailMessage(id: MessageID(), accountID: account.id,
                locator: account.provider == .gmail ? .gmail(id: "dashboard-\(index)") : .imap(mailbox: folder.providerID, uidValidity: 1, uid: UInt32(index + 1)),
                threadID: nil, folderIDs: ids, subject: subjects[index % subjects.count],
                sender: MailPerson(name: ["Lena Muster", "Jonas Beispiel", "Nora Beispiel", "Atelier Muster"][index % 4], address: EmailAddress("sender@example.com")),
                recipients: [MailPerson(name: account.name, address: account.address)], receivedAt: date,
                isUnread: !inbox || index.isMultiple(of: 2), isFlagged: index.isMultiple(of: 13), preview: nil))
        }
        for (index, count) in counts.enumerated() {
            let day = calendar.date(byAdding: .day, value: index - 6, to: today)!
            for hour in 0..<count { try append(at: day.addingTimeInterval(Double(hour + 1) * 3600), inbox: true) }
        }
        for index in 0..<100 { try append(at: today.addingTimeInterval(Double(index)), inbox: false) }
        return DemoDataset(snapshot: try MailSnapshot(accounts: accounts, folders: folders, threads: [], messages: messages), contents: [:])
    }

    @Test func fullCountsExcludeArchivedUnreadAndDeduplicateLabels() async throws {
        let data = try fixture(at: now)
        let dashboard = try await MailDashboard.load(service: InboxService(repository: data.repository()), scope: data.scope, now: now, timeZone: zone)
        #expect(dashboard.total == 135 && dashboard.inbox == 35 && dashboard.unread == 18)
        #expect(dashboard.days.map(\.count) == [4, 2, 8, 5, 3, 7, 6])
        #expect(dashboard.weekTotal == 35 && dashboard.recentUnread.count == 4)
        let inboxIDs = Set(data.snapshot.folders.filter { $0.role == .inbox }.map(\.id))
        #expect(dashboard.recentUnread.allSatisfy { $0.isUnread && !$0.folderIDs.isDisjoint(with: inboxIDs) })
        let account = data.snapshot.accounts[0]
        let limited = try await MailDashboard.load(service: InboxService(repository: data.repository()), scope: AccessScope(accountIDs: [account.id]), now: now, timeZone: zone)
        #expect(limited.accounts.map(\.id) == [account.id])
        #expect(limited.total == data.snapshot.messages.filter { $0.accountID == account.id }.count)
        #expect(limited.recentUnread.allSatisfy { $0.accountID == account.id })
        let empty = try await MailDashboard.load(service: InboxService(repository: data.repository()), scope: AccessScope(accountIDs: []), now: now, timeZone: zone)
        #expect(empty.total == 0 && empty.inbox == 0 && empty.unread == 0 && empty.weekTotal == 0 && empty.recentUnread.isEmpty)
    }

    @Test func dateBucketsRespectDSTAndDrilldownMatchesCounts() async throws {
        // Switzerland's autumn transition has a 25-hour calendar day.
        let autumn = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!
        let data = try fixture(at: autumn)
        let repository = InboxService(repository: data.repository())
        let dashboard = try await MailDashboard.load(service: repository, scope: data.scope, now: autumn, timeZone: zone)
        let day = try #require(dashboard.days.last)
        #expect(day.end.timeIntervalSince(day.date) == 25 * 3600)
        for day in dashboard.days {
            var query = MessageFilter(); query.role = .inbox; query.text = day.query; query.timeZoneID = zone.identifier
            let result = try await repository.search(query, page: PageRequest(limit: 100), scope: data.scope)
            #expect(result.items.count == day.count)
            #expect(result.items.allSatisfy { $0.receivedAt >= day.date && $0.receivedAt < day.end })
        }
    }

    @Test func navigationDoesNotOpenBodiesUntilMessageIsChosen() async throws {
        let model = InboxModel(dataset: try fixture(at: now), initialDestination: .dashboard)
        await model.start()
        try await ready { !model.isLoading }
        #expect(model.dashboard?.inbox == 35 && model.inboxCount == 35 && model.unreadCount == 18)
        #expect(model.selection.isEmpty && model.messages.isEmpty && model.content.isEmpty && model.safeHTML == nil)
        let message = try #require(model.dashboard?.recentUnread.first)
        model.openDashboardMessage(message)
        try await ready { !model.isLoading }
        #expect(model.destination == .unread && model.selection == [message.id])
        model.searchText = "no-such-subject"
        model.destination = .dashboard
        try await ready { !model.isLoading }
        #expect(model.dashboard?.inbox == 35 && model.selection.isEmpty)
        model.showDashboardDestination(.inbox)
        try await ready { !model.isLoading }
        #expect(model.searchText.isEmpty && model.coverage?.messageCount == 35 && model.messages.count == 20)
        model.destination = .dashboard
        model.showDashboardDestination(.flagged)
        try await ready { !model.isLoading }
        #expect(model.destination == .flagged && model.messages.allSatisfy(\.isFlagged))
    }

    @Test func dashboardReportsFailureAndRecovers() async throws {
        let model = InboxModel(dataset: try DemoDataset.empty(), initialDestination: .dashboard)
        model.scenario = .error
        await model.start(autoSelectDemo: false)
        try await ready { !model.isLoading }
        #expect(model.error != nil && model.dashboard == nil)
        model.scenario = .standard
        try await ready { !model.isLoading }
        #expect(model.error == nil && model.dashboard?.total == 0 && model.dashboard?.accounts.isEmpty == true)
    }

    @Test func renderDashboardForReview() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CUMAIL_DASHBOARD_RENDER_DIR"] else { return }
        _ = NSApplication.shared; AppResources.registerFonts()
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let model = InboxModel(dataset: try fixture(at: Date()), initialDestination: .dashboard)
        await model.start(autoSelectDemo: false)
        try await ready { !model.isLoading }
        for (name, size, scheme) in [("light", NSSize(width: 1000, height: 970), ColorScheme.light),
                                     ("dark", NSSize(width: 1000, height: 970), ColorScheme.dark),
                                     ("narrow", NSSize(width: 550, height: 1350), ColorScheme.light)] {
            let hosting = NSHostingView(rootView: DashboardView(model: model).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = hosting; hosting.frame = NSRect(origin: .zero, size: size)
            try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("dashboard-\(name).png"))
            window.contentView = nil
        }
    }

    private func ready(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}
