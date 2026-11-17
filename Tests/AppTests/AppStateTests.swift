import Foundation
import SwiftUI
import AppKit
import Testing
@testable import MailDemo
import MailDomain
import MailApplication
@testable import MikeMailHub

@Suite(.serialized)
@MainActor
struct AppStateTests {
    @Test func synchronizationProgressDistinguishesDiscoveryCountsWaitingAndFailure() throws {
        let account = try SyntheticFixtures.make().snapshot.accounts[0]
        let start = Date(timeIntervalSince1970: 1000)
        var progress = MailSynchronizationProgress(account: account, now: start)
        progress.receive(.discovering(pages: 12, messages: 6000), now: start)
        #expect(progress.fraction == nil && progress.detail.contains("12"))
        progress.receive(.updating(completed: 1500, total: 6000), now: start.addingTimeInterval(10))
        #expect(progress.fraction == 0.25 && !progress.estimatedTotal)
        progress.receive(.waiting(30), now: start.addingTimeInterval(20))
        #expect(progress.fraction == 0.25)
        #expect(progress.timing(at: start.addingTimeInterval(25)).contains("25 Sek."))
        progress.receive(.updating(completed: 1600, total: 6000), now: start.addingTimeInterval(51))
        #expect(progress.waitingUntil == nil)
        #expect(progress.timing(at: start.addingTimeInterval(71)).contains("letzte Rückmeldung vor 20 Sek."))
        progress.finish(error: "Offline", now: start.addingTimeInterval(75))
        #expect(!progress.isRunning && progress.state == .failed && progress.detail == "Offline")
        progress = MailSynchronizationProgress(account: account, now: start)
        progress.receive(.scanning(completed: 100, total: nil), now: start)
        #expect(progress.fraction == nil && progress.detail.contains("unbekannt"))
        progress.finish(cancelled: true, now: start.addingTimeInterval(30))
        #expect(progress.state == .paused)
    }
    @Test func localDraftNavigationSeparatesWorkFromReceiptsAndDoesNotOpenMail() async throws {
        let dataset = try SyntheticFixtures.make()
        let model = InboxModel(dataset: dataset)
        await model.start(autoSelectDemo: false)
        try await ready { !model.isLoading }
        model.destination = .localDrafts
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.messages.isEmpty && model.selection.isEmpty && model.content.isEmpty)
        let account = dataset.snapshot.accounts[0]
        func draft(_ status: DraftStatus) -> LocalDraft {
            var value = LocalDraft(accountID: account.id, sender: account.address.value)
            value.subject = "Draft to finish"; value.to = "recipient@example.invalid"; value.status = status
            return value
        }
        let working = draft(.editing), failed = draft(.failed), sent = draft(.sent), uncertain = draft(.uncertain)
        model.savedDrafts = [working, failed, sent, uncertain]
        #expect(Set(model.visibleDrafts.map(\.id)) == [working.id, failed.id])
        model.selectedDraftID = working.id
        #expect(model.selectedDraft?.id == working.id)
        model.showingSubmissionHistory = true
        #expect(model.selectedDraft == nil)
        #expect(Set(model.visibleDrafts.map(\.id)) == [sent.id, uncertain.id])
        model.draftSearchText = "missing"
        #expect(model.visibleDrafts.isEmpty)
        model.draftSearchText = "RECIPIENT@EXAMPLE.INVALID"
        #expect(model.visibleDrafts.count == 2)
        model.destination = .unread
        try await ready { !model.isLoading }
        #expect(model.messages.count == model.unreadCount)
    }
    @Test func sidebarCountsMatchDestinationsAcrossFoldersAndPages() async throws {
        let data = try SyntheticFixtures.make()
        let account = try #require(data.snapshot.accounts.first { $0.provider == .gmail })
        let inbox = try #require(data.snapshot.folders.first { $0.accountID == account.id && $0.role == .inbox })
        let archive = try #require(data.snapshot.folders.first { $0.accountID == account.id && $0.role == .archive })
        let sample = try #require(data.snapshot.messages.first { $0.accountID == account.id })
        // Unread archive-only mail must not enter the inbox-only view/count.
        // One Gmail message has both labels and must still be counted once.
        let extra = try (0..<50).map { index in
            try MailMessage(id: MessageID(), accountID: account.id, locator: .gmail(id: "counter-test-\(index)"),
                threadID: nil, folderIDs: index == 0 ? [inbox.id, archive.id] : index < 25 ? [inbox.id] : [archive.id],
                subject: "Counter fixture \(index)", sender: sample.sender, recipients: sample.recipients,
                receivedAt: sample.receivedAt.addingTimeInterval(Double(index)), isUnread: true, isFlagged: false, preview: nil)
        }
        let dataset = DemoDataset(snapshot: try MailSnapshot(accounts: data.snapshot.accounts, folders: data.snapshot.folders,
            threads: data.snapshot.threads, messages: data.snapshot.messages + extra), contents: [:])
        let model = InboxModel(dataset: dataset)
        await model.start(autoSelectDemo: false)
        try await ready { !model.isLoading }
        #expect(model.inboxCount == 33)
        #expect(model.inboxCount == model.coverage?.messageCount)
        #expect(model.unreadCount == 29)
        #expect(model.accountUnread[account.id] == 26)

        model.destination = .unread
        try await ready { !model.isLoading }
        #expect(model.messages.count == 20)
        #expect(model.nextCursor != nil)
        #expect(model.coverage?.messageCount == model.unreadCount)
        await model.loadMore()
        #expect(model.messages.count == 29)
        #expect(Set(model.messages.map(\.id)).count == 29)

        model.searchText = "subject:missing-counter-text"
        try await ready { !model.isLoading }
        #expect(model.messages.isEmpty)
        #expect(model.inboxCount == 33 && model.unreadCount == 29)
    }

    @Test func customFolderOrderStaysInsideItsAccountAndAppendsNewFolders() async throws {
        let data = try SyntheticFixtures.make()
        let model = InboxModel(dataset: data)
        await model.start(autoSelectDemo: false)
        let first = data.snapshot.accounts[0].id, other = data.snapshot.accounts[1].id
        let original = model.orderedFolders(for: first), otherOriginal = model.orderedFolders(for: other)
        let order = Array(original.suffix(2).reversed()).map(\.id)
        model.folderOrders[first] = order
        #expect(model.orderedFolders(for: first).map(\.id) == order + original.dropLast(2).map(\.id))
        #expect(model.orderedFolders(for: other).map(\.id) == otherOriginal.map(\.id))
        await model.start(autoSelectDemo: false)
        #expect(model.orderedFolders(for: first).prefix(2).map(\.id) == order)
    }

    @Test func assistantCanReadDuringMetadataImportButNotDuringServerMutation() async throws {
        let data = try SyntheticFixtures.make()
        let model = InboxModel(dataset: data)
        await model.start(autoSelectDemo: false)
        try await ready { !model.isLoading && !model.contentLoading }
        let imap = try #require(data.snapshot.accounts.first { $0.provider == .imap })
        let gmail = try #require(data.snapshot.accounts.first { $0.provider == .gmail })
        let imapMail = try #require(data.snapshot.messages.first { $0.accountID == imap.id })
        let gmailMail = try #require(data.snapshot.messages.first { $0.accountID == gmail.id })
        model.networkBusy = true; model.syncingAccountID = gmail.id
        #expect(try await model.assistantText(imapMail.id, scope: data.scope) == data.contents[imapMail.id])
        #expect(try await model.assistantText(gmailMail.id, scope: data.scope) == data.contents[gmailMail.id])
        model.syncingAccountID = imap.id
        await #expect(throws: MailFailure.offline) { try await model.assistantText(imapMail.id, scope: data.scope) }
        #expect(try await model.assistantText(gmailMail.id, scope: data.scope) == data.contents[gmailMail.id])
        model.syncingAccountID = nil
        await #expect(throws: MailFailure.offline) { try await model.assistantText(gmailMail.id, scope: data.scope) }
    }
    /// Exercise a real native split view and unified toolbar, including the
    /// large-to-small transition that previously retained a 1547-point minimum.
    @Test func columnViewportShrinksAfterLargeWindowWithConnectedAccount() async throws {
        _ = NSApplication.shared
        AppResources.registerFonts()
        let model = InboxModel(dataset: try SyntheticFixtures.make())
        await model.start(autoSelectDemo: false)
        try await ready { !model.isLoading }
        let hosting = NSHostingView(rootView: InboxView(model: model).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        window.contentView = hosting
        defer { window.contentView = nil }
        // Let InboxView's startup task finish before applying synthetic UI state.
        try await Task.sleep(for: .milliseconds(300))
        let account = try #require(model.accounts.first { $0.provider == .imap })
        model.imapAccountIDs = [account.id]
        model.accounts = model.accounts.map {
            MailAccount(id: $0.id, name: $0.name, address: $0.address, provider: $0.provider,
                        status: $0.id == account.id ? .connected : $0.status)
        }
        #expect(model.canSearchOnline)
        let message = try #require(model.messages.first)
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        for selected in [false, true] {
            if selected {
                var progress = MailSynchronizationProgress(account: model.accounts[0])
                progress.receive(.updating(completed: 1500, total: 6000))
                progress.receive(.waiting(30))
                model.synchronizationProgress = progress
            } else { model.synchronizationProgress = nil }
            model.selection = selected ? [message.id] : []
            try await ready { !model.contentLoading }
            for (width, height) in [(3360.0, 1744.0), (1512.0, 833.0), (1000.0, 652.0), (1280.0, 820.0)] {
                window.setContentSize(NSSize(width: width, height: height))
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
                hosting.layoutSubtreeIfNeeded()
                let split = try #require(descendants(hosting).compactMap { $0 as? NSSplitView }.first)
                let viewport = hosting.bounds.insetBy(dx: -0.5, dy: -0.5)
                #expect(viewport.contains(split.convert(split.bounds, to: hosting)))
                let scrolls = descendants(split).compactMap { $0 as? NSScrollView }
                    .filter { $0.frame.width > 200 && $0.frame.height > 100 }
                #expect(scrolls.count >= 2)
                for scroll in scrolls {
                    #expect(viewport.contains(scroll.convert(scroll.bounds, to: hosting)))
                }
                print("Scroll layout: selected=\(selected), window=\(hosting.bounds.size), split=\(split.bounds.size)")
                if let directory = ProcessInfo.processInfo.environment["MIKE_MAIL_LAYOUT_RENDER_DIR"] {
                    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("layout-\(Int(width))-\(Int(height))-selected-\(selected).png"))
                }
            }
        }
    }
    @Test func invalidSearchClearsOldContentAndValidFieldFiltersRecover() async throws {
        let model = InboxModel(dataset: try SyntheticFixtures.make())
        await model.start(); try await ready { !model.isLoading && !model.contentLoading }
        model.searchText = "after:2026-02-30"
        try await ready { !model.isLoading }
        #expect(model.searchInvalid && model.messages.isEmpty && model.content.isEmpty && model.coverage == nil)
        #expect(model.error?.contains("gültiges Datum") == true)
        model.searchText = "from:Lena has:attachment"
        try await ready { !model.isLoading && !model.contentLoading }
        #expect(!model.searchInvalid && model.error == nil && !model.messages.isEmpty)
        #expect(model.messages.allSatisfy { $0.sender.name.contains("Lena") && !$0.attachments.isEmpty })
        model.searchText = "from:Mara"
        model.destination = .flagged
        try await ready { !model.isLoading && !model.contentLoading }
        #expect(model.messages.allSatisfy { $0.isFlagged && $0.sender.name.contains("Mara") })
    }
    @Test func onlineSearchRequiresOneRealFolderAndSupportedFilters() async throws {
        let model = InboxModel(dataset: try SyntheticFixtures.make())
        await model.start(); try await ready { !model.isLoading }
        #expect(!model.canSearchOnline)
        let account = try #require(model.accounts.first { $0.provider == .imap })
        model.accounts = model.accounts.map {
            MailAccount(id: $0.id, name: $0.name, address: $0.address, provider: $0.provider, status: $0.id == account.id ? .connected : $0.status)
        }
        model.imapAccountIDs = [account.id]
        model.destination = .account(account.id)
        try await ready { !model.isLoading }
        #expect(model.onlineSearchFolder == nil)
        model.destination = .folder(try #require(model.folders.first { $0.accountID == account.id && $0.role == .inbox }).id)
        try await ready { !model.isLoading }
        #expect(model.onlineSearchFolder?.accountID == account.id)
        model.searchText = "filename:pdf"; try await ready { !model.isLoading }
        #expect(!model.canSearchOnline && model.onlineSearchExplanation.contains("nur lokal"))
        model.searchText = ""; model.destination = .unread
        try await ready { !model.isLoading }
        // The inbox-only unread filter now resolves the single eligible IMAP inbox.
        #expect(model.onlineSearchFolder?.accountID == account.id)
        #expect(model.onlineSearchFolder?.role == .inbox && model.filter.unreadOnly)
    }
    @Test func accountViewIncludesSentAndArchivedMail() async throws {
        let data = try SyntheticFixtures.make()
        let model = InboxModel(dataset: data)
        await model.start(autoSelectDemo: false)
        try await ready { !model.isLoading }
        for account in data.snapshot.accounts where account.provider != .microsoft {
            model.destination = .account(account.id)
            try await ready { !model.isLoading }
            let expected = data.snapshot.messages.filter { $0.accountID == account.id }
            #expect(Set(model.messages.map(\.id)) == Set(expected.map(\.id)))
            let outsideInbox = try #require(expected.first { message in
                data.snapshot.folders.contains { $0.accountID == account.id && $0.role != .inbox && message.folderIDs.contains($0.id) }
            })
            model.searchText = "subject:\"\(outsideInbox.subject)\""
            try await ready { !model.isLoading }
            #expect(model.messages.map(\.id) == [outsideInbox.id])
            model.searchText = ""
            try await ready { !model.isLoading }
        }
    }
    @Test func nonDemoAccountsRequireExplicitMessageSelection() async throws {
        let model = InboxModel(dataset: try SyntheticFixtures.make())
        await model.start()
        try await ready { !model.isLoading && !model.contentLoading }
        model.accounts = model.accounts.map {
            MailAccount(id: $0.id, name: $0.name, address: $0.address, provider: $0.provider, status: .connected)
        }
        model.selection = []
        model.reload()
        try await ready { !model.isLoading }
        #expect(!model.messages.isEmpty)
        #expect(model.selection.isEmpty && model.content.isEmpty && !model.contentLoading)
        model.destination = .unread
        try await ready { !model.isLoading }
        #expect(model.selection.isEmpty && model.content.isEmpty)
    }
    private func ready(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("State did not settle within one second")
    }

    @Test func navigationSelectionAndContent() async throws {
        let model = InboxModel(dataset: try SyntheticFixtures.make())
        await model.start()
        try await ready { !model.isLoading && !model.content.isEmpty }
        #expect(model.messages.count == 8)
        #expect(model.selectedMessage?.subject == "Die nächste Version nimmt Form an")
        model.destination = .unread
        try await ready { !model.isLoading }
        #expect(model.messages.count == 4)
        let last = try #require(model.messages.last)
        model.selection = [last.id]
        try await ready { !model.contentLoading }
        #expect(model.content.contains("Freitag"))
        model.selection = Set(model.messages.prefix(2).map(\.id))
        #expect(model.selectedMessage == nil)
        #expect(model.content.isEmpty)
    }

    @Test func latestSearchWinsAndDoesNotLeakOldBody() async throws {
        let model = InboxModel(dataset: try SyntheticFixtures.make())
        await model.start()
        model.searchText = "Lena"
        model.searchText = "Mara"
        try await ready { !model.isLoading && !model.contentLoading }
        #expect(model.messages.count == 1)
        #expect(model.selectedMessage?.sender.name == "Mara Muster")
        #expect(!model.content.contains("Donnerstag"))
        model.searchText = "kein-treffer-123"
        try await ready { !model.isLoading }
        #expect(model.messages.isEmpty)
        #expect(model.selection.isEmpty)
        #expect(model.content.isEmpty)
    }

    @Test func demoStatesAreExplicitAndRecoverable() async throws {
        let model = InboxModel(dataset: try SyntheticFixtures.make())
        await model.start()
        model.scenario = .offline
        try await ready { !model.isLoading }
        #expect(model.messages.count == 8)
        #expect(model.content.isEmpty)
        #expect(model.contentError?.contains("offline") == true)
        model.scenario = .expired
        try await ready { !model.isLoading }
        #expect(model.contentError?.contains("Anmeldung") == true)
        model.scenario = .error
        try await ready { !model.isLoading }
        #expect(model.error != nil)
        model.scenario = .noAccounts
        try await ready { !model.isLoading }
        #expect(model.messages.isEmpty)
        model.scenario = .standard
        try await ready { !model.isLoading && !model.content.isEmpty }
        #expect(model.error == nil)
        #expect(model.messages.count == 8)
    }

    @Test func fontsAndOriginalBrandAssetsLoad() throws {
        AppResources.registerFonts()
        #expect(NSFont(name: "JosefinSans-Thin", size: 20) != nil)
        #expect(NSFont(name: "Barlow-Bold", size: 20) != nil)
        #expect(NSFont(name: "IBMPlexMono-Regular", size: 12) != nil)
        for name in ["LockupLight","LockupDark"] {
            let url = try #require(AppResources.url(name, extension: "pdf", folder: "Brand"))
            #expect(NSImage(contentsOf: url) != nil)
        }
    }

    /// Renders only our own off-screen view. No screen capture, accessibility API or input automation.
    /// Set MIKE_MAIL_RENDER_DIR to opt into review artifacts; these are not desktop screenshots.
    @Test func renderNativeViewsForReview() async throws {
        guard let directory = ProcessInfo.processInfo.environment["MIKE_MAIL_RENDER_DIR"] else { return }
        _ = NSApplication.shared
        AppResources.registerFonts()
        let model = InboxModel(dataset: try SyntheticFixtures.make())
        await model.start()
        try await ready { !model.isLoading && !model.content.isEmpty }
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let view = InboxView(model: model).environment(\.colorScheme, scheme).frame(width: 1280, height: 800)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("demo-\(name)-render.png"))
            #expect(png.count > 20_000)
            window.contentView = nil
        }
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            var progress = MailSynchronizationProgress(account: model.accounts[0])
            progress.receive(.updating(completed: 1500, total: 6000))
            progress.receive(.waiting(30))
            let view = SynchronizationStatusView(progress: progress, pause: {}, dismiss: {})
                .environment(\.colorScheme, scheme).frame(width: 300)
            let hosting = NSHostingView(rootView: view)
            let size = hosting.fittingSize
            #expect(size.height > 80 && size.height < 230, "Progress stays compact in the narrowest message column")
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = hosting; hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("sync-\(name)-render.png"))
            window.contentView = nil
        }
        let form = IMAPAccountEditor(model: model).environment(\.colorScheme, .light)
            .frame(width: 570, height: 590).background(Brand.surface(.light))
        let hosting = NSHostingView(rootView: form)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 590), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 570, height: 590)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("phase-2-imap-form-render.png"))
        window.contentView = nil
    }
}

extension AppStateTests {
    @Test func conversationSelectionRemainsBoundToAccountAndMessage() async throws {
        let model = InboxModel(dataset: try SyntheticFixtures.make())
        await model.start()
        try await ready { !model.isLoading && !model.conversationLoading }
        #expect(model.conversation.count == 2)
        let reply = try #require(model.conversation.first { !model.selection.contains($0.id) })
        model.openConversationMessage(reply.id)
        let listSelection = model.selection
        model.selection = listSelection // Native List focus updates must not reset the conversation member.
        try await ready { !model.contentLoading }
        #expect(model.selectedMessage?.id == reply.id)
        #expect(model.selectedMessage?.accountID == reply.accountID)
        #expect(model.content.contains("Danke für die Muster"))
        model.destination = .account(try #require(model.accounts.first { $0.id != reply.accountID }).id)
        try await ready { !model.isLoading && !model.contentLoading && !model.conversationLoading }
        #expect(model.selectedMessage?.accountID != reply.accountID)
        #expect(!model.content.contains("Danke für die Muster"))
    }
    @Test func HTMLContentDoesNotLeakAcrossSelections() async throws {
        let model = InboxModel(dataset: try SyntheticFixtures.make())
        await model.start()
        try await ready { !model.isLoading && !model.contentLoading }
        #expect(model.showHTML && model.htmlAvailable == true)
        model.showHTML = false
        try await ready { !model.contentLoading }
        #expect(!model.showHTML && !model.content.isEmpty)
        model.showHTML = true
        try await ready { !model.contentLoading }
        #expect(model.safeHTML != nil)
        #expect(model.safeHTML?.remoteImageCount == 1)
        #expect(model.safeHTML?.bodyMarkup.contains("<script") == false)
        let next = try #require(model.messages.last)
        model.selection = [next.id]
        #expect(model.safeHTML == nil && model.content.isEmpty)
        try await ready { !model.contentLoading }
        #expect(model.content.contains("Freitag"))
        #expect(model.showHTML && model.htmlAvailable == true)
        model.showHTML = false
        try await ready { !model.contentLoading }
        model.selection = [try #require(model.messages.first).id]
        try await ready { !model.contentLoading }
        #expect(model.showHTML && model.safeHTML != nil)
    }
}
