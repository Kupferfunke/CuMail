import Foundation
import Testing
import MailDomain
import MailApplication
@testable import MailDemo
@testable import MikeMailHub

@Suite(.serialized) @MainActor
struct MailMoveSelectionTests {
    @Test func sendingResponseOpensNextPageAndRespectsLaterNavigation() async throws {
        let data = try fixture(count: 26, moving: [])
        let inbox = InboxModel(dataset: data.after)
        await inbox.start(autoSelectDemo: false); try await ready { !inbox.isLoading }
        let source = try #require(inbox.displayedMessages.last)
        #expect(inbox.nextCursor != nil)
        inbox.selection = [source.id]
        let completion = try #require(inbox.sendContinuation(source: source.id))
        completion()
        try await ready { inbox.selectedMessage?.id == data.before[20].id && !inbox.contentLoading }
        #expect(inbox.messages.count == 26)
        let stale = try #require(inbox.sendContinuation(source: data.before[20].id))
        inbox.selection = [data.before[0].id]
        stale()
        try await Task.sleep(for: .milliseconds(40))
        #expect(inbox.selectedMessage?.id == data.before[0].id)
        // The final row has no next mail and must not jump to an unrelated one.
        inbox.selection = [data.before[25].id]
        let lastCompletion = try #require(inbox.sendContinuation(source: data.before[25].id))
        lastCompletion()
        try await Task.sleep(for: .milliseconds(40))
        #expect(inbox.selectedMessage?.id == data.before[25].id)
    }
    private func fixture(count: Int, moving: Set<Int>) throws -> (before: [MailMessage], after: DemoDataset) {
        let seed = try SyntheticFixtures.make(), account = seed.snapshot.accounts[0]
        let inbox = try #require(seed.snapshot.folders.first { $0.accountID == account.id && $0.role == .inbox })
        let archive = try #require(seed.snapshot.folders.first { $0.accountID == account.id && $0.role == .archive })
        var before: [MailMessage] = [], after: [MailMessage] = [], contents: [MessageID: String] = [:]
        for index in 0..<count {
            let id = try MessageID()
            func message(folder: FolderID) throws -> MailMessage {
                try MailMessage(id: id, accountID: account.id, locator: .imap(mailbox: inbox.providerID, uidValidity: 1, uid: UInt32(index + 1)),
                    threadID: nil, folderIDs: [folder], subject: "Message \(index)", sender: MailPerson(name: "Synthetic", address: account.address),
                    recipients: [], receivedAt: Date(timeIntervalSince1970: 1794010000 - Double(index) * 60),
                    isUnread: false, isFlagged: false, preview: nil)
            }
            before.append(try message(folder: inbox.id))
            after.append(try message(folder: moving.contains(index) ? archive.id : inbox.id))
            contents[id] = "Body \(index)"
        }
        return (before, DemoDataset(snapshot: try MailSnapshot(accounts: [account], folders: seed.snapshot.folders.filter { $0.accountID == account.id }, threads: [], messages: after), contents: contents))
    }

    @Test(arguments: [0, 10, 39, 65]) func selectsNextMailIncludingPageBoundaryAndPreviousAtEnd(index: Int) async throws {
        let data = try fixture(count: 66, moving: [index])
        let model = InboxModel(dataset: data.after)
        await model.start(autoSelectDemo: false); try await ready { !model.isLoading }
        let loaded = index < 20 ? 20 : index < 40 ? 40 : 66
        model.messages = Array(data.before.prefix(loaded)); model.selection = [data.before[index].id]
        let next = try #require(MailMoveContinuation(rows: model.displayedMessages, selection: model.selection, loadedCount: loaded))
        model.reload(autoSelectDemo: false, preserveDisplayedContent: true, afterMove: next)
        let expected = index == 65 ? 64 : index + 1
        try await ready { !model.isLoading && !model.contentLoading }
        #expect(model.selectedMessage?.id == data.before[expected].id)
        #expect(model.content == "Body \(expected)")
        #expect(model.messages.count == min(loaded, 65))
        #expect(model.coverage?.messageCount == 65)
    }

    @Test func emptyInboxClearsSelectionAndBody() async throws {
        let data = try fixture(count: 1, moving: [0]), model = InboxModel(dataset: data.after)
        await model.start(autoSelectDemo: false); try await ready { !model.isLoading }
        model.messages = data.before; model.selection = [data.before[0].id]
        let next = try #require(MailMoveContinuation(rows: model.displayedMessages, selection: model.selection, loadedCount: 1))
        model.reload(autoSelectDemo: false, preserveDisplayedContent: true, afterMove: next)
        try await ready { !model.isLoading && !model.contentLoading }
        #expect(model.messages.isEmpty && model.selection.isEmpty && model.content.isEmpty && model.safeHTML == nil)
    }

    @Test func partialMoveKeepsUnmovedSelectionAndAccountViewKeepsMovedMail() async throws {
        let data = try fixture(count: 6, moving: [1]), model = InboxModel(dataset: data.after)
        await model.start(autoSelectDemo: false); try await ready { !model.isLoading }
        model.messages = data.before; model.selection = [data.before[1].id, data.before[2].id]
        let next = try #require(MailMoveContinuation(rows: model.displayedMessages, selection: model.selection, loadedCount: 6))
        model.reload(autoSelectDemo: false, afterMove: next)
        try await ready { !model.isLoading && !model.contentLoading }
        #expect(model.selection == [data.before[2].id])
        model.destination = .account(data.before[1].accountID)
        try await ready { !model.isLoading }
        model.selection = [data.before[1].id]
        model.reload(autoSelectDemo: false, afterMove: next)
        try await ready { !model.isLoading && !model.contentLoading }
        #expect(model.selection == [data.before[1].id] && model.content == "Body 1")
    }

    @Test func laterNavigationWinsOverMoveContinuation() async throws {
        let data = try fixture(count: 6, moving: [1]), model = InboxModel(dataset: data.after)
        await model.start(autoSelectDemo: false); try await ready { !model.isLoading }
        model.messages = data.before; model.selection = [data.before[1].id]
        let next = try #require(MailMoveContinuation(rows: model.displayedMessages, selection: model.selection, loadedCount: 6))
        model.reload(autoSelectDemo: false, afterMove: next)
        model.destination = .flagged
        try await ready { !model.isLoading }
        #expect(model.destination == .flagged && model.messages.isEmpty && model.selection.isEmpty)
    }

    @Test func groupedRowContinuationPrefersNextVisibleConversation() throws {
        let data = try fixture(count: 5, moving: [0])
        let rows = [data.before[0], data.before[2], data.before[4]]
        let next = try #require(MailMoveContinuation(rows: rows, selection: [rows[0].id], loadedCount: 5))
        #expect(next.next(in: [data.before[1], data.before[2], data.before[4]]) == data.before[2].id)
        #expect(next.next(in: []) == nil)
    }

    private func ready(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
