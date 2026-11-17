import Foundation
import Testing
import MailApplication
import MailDomain
import MailPersistence
import MailSecurity
@testable import MailDemo
@testable import MikeMailHub

private actor QueueTestSecrets: CredentialStore, DatabaseKeyStore {
    func read(_ reference: CredentialReference) -> Data? { nil }
    func save(_ secret: Data, for reference: CredentialReference) {}
    func delete(_ reference: CredentialReference) {}
    func databaseKey(createIfMissing: Bool) -> Data { Data(repeating: 39, count: 32) }
    func deleteDatabaseKey() {}
}

private actor QueueGmail: GmailAPI {
    nonisolated let accountID: AccountID
    let account: MailAccount
    let catalog: [MailFolder]
    let originals: [String: MailMessage]
    var trashed: Set<String>
    var writes: [String] = []
    init(account: MailAccount, folders: [MailFolder], messages: [MailMessage], oldMatches: Bool) {
        self.accountID = account.id; self.account = account; catalog = folders
        originals = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ("a\($0.offset)", $0.element) })
        trashed = oldMatches ? ["a0"] : []
    }
    func profile() -> GmailProfile { .init(email: account.address.value, historyID: "42") }
    func folders() -> [MailFolder] { catalog }
    func messageIDs(label: String, limit: Int, query: String?) -> [String] { Array(originals.keys).sorted() }
    func history(since: String) -> GmailHistory { .init(changedIDs: Set(originals.keys), historyID: "42") }
    func metadata(id: String, folders: [MailFolder]) throws -> (MailMessage, String) {
        let original = try #require(originals[id])
        let folder = try #require(catalog.first { $0.role == (trashed.contains(id) ? .trash : .inbox) })
        return (try MailMessage(id: original.id, accountID: accountID, locator: original.locator, threadID: GmailIdentity.thread(account: accountID, id: "b1"),
            folderIDs: [folder.id], subject: original.subject, sender: original.sender, recipients: original.recipients,
            receivedAt: original.receivedAt, isUnread: original.isUnread, isFlagged: false, preview: nil), "b1")
    }
    func modify(id: String, adding: [String], removing: [String]) { writes.append(id); if adding.contains("TRASH") { trashed.insert(id) } }
    func body(id: String, preferHTML: Bool, maximumBytes: Int) -> MailBody { .init(text: "Synthetic only", format: .plainText) }
    func draftVersion(id: String) throws -> GmailDraftReceipt { throw MailFailure.unsupported }
    func findDraft(internetMessageID: String) -> GmailDraftReceipt? { nil }
    func send(raw: Data, draftID: String?) throws -> String { throw MailFailure.unsupported }
    func saveDraft(raw: Data, draftID: String?) throws -> GmailDraftReceipt { throw MailFailure.unsupported }
}

@Suite(.serialized) @MainActor
struct NativeMailActionQueueTests {
    @Test(arguments: [false, true]) func oldGmailUncertaintyIsReadBackAndBothWaitingDeletesContinue(oldMatches: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CuMail-Gmail-queue-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = MailAccount(id: try AccountID(), name: "Gmail synthetic", address: try EmailAddress("synthetic@example.invalid"), provider: .gmail, status: .connected)
        let inbox = try MailFolder(id: GmailIdentity.folder(account: account.id, label: "INBOX"), accountID: account.id, providerID: "INBOX", name: "Inbox", role: .inbox)
        let trash = try MailFolder(id: GmailIdentity.folder(account: account.id, label: "TRASH"), accountID: account.id, providerID: "TRASH", name: "Trash", role: .trash)
        let messages = try (0..<3).map { i in
            try MailMessage(id: GmailIdentity.message(account: account.id, id: "a\(i)"), accountID: account.id, locator: .gmail(id: "a\(i)"),
                threadID: nil, folderIDs: [inbox.id], subject: "Synthetic \(i)", sender: MailPerson(name: "Sender", address: account.address),
                recipients: [MailPerson(name: "", address: account.address)], receivedAt: Date().addingTimeInterval(Double(-i)), isUnread: true, isFlagged: false, preview: nil)
        }
        let snapshot = try MailSnapshot(accounts: [account], folders: [inbox, trash], threads: [], messages: messages)
        let data = DemoDataset(snapshot: snapshot, contents: [:])
        let workspace = try await LocalMailWorkspace.open(paths: WorkspacePaths(root: root, cache: root.appendingPathComponent("Cache")), credentials: QueueTestSecrets(), syntheticSnapshot: snapshot)
        let config = try GmailConfiguration(accountID: account.id, clientID: "1234567890-synthetic.apps.googleusercontent.com", permission: .manageMail)
        try await workspace.repository.saveGmailAccount(account, configuration: config, folders: [inbox, trash])
        var settings = try await workspace.settings(for: account.id); settings.serverActionsEnabled = true
        try await workspace.saveSettings(settings)
        let actions = MailActions(service: InboxService(repository: workspace.repository), store: workspace.repository) { _, _, _, _ in Issue.record("Preparation must not write") }
        for (i, message) in messages.enumerated() {
            let request = try MailActionRequest(accountID: account.id, messageIDs: [message.id], kind: .move, targetFolderID: trash.id)
            var receipt = try await actions.prepare(request, scope: data.scope, nativeQueue: true, authorize: {})
            if i == 0 { receipt.items[0].state = .uncertain; receipt.finished = true; try await workspace.repository.saveMailAction(receipt) }
        }
        let api = QueueGmail(account: account, folders: [inbox, trash], messages: messages, oldMatches: oldMatches)
        let gmail = GmailService(index: workspace.repository) { _ in api }
        let model = InboxModel(dataset: data, workspace: workspace, gmail: gmail)
        await model.start(autoSelectDemo: false)
        try await ready { model.lastMailAction != nil && !model.hasQueuedMailActions && !model.mailActionProcessing && model.checkingMailActionID == nil && !model.isLoading }
        #expect(await api.writes == ["a1", "a2"])
        for message in messages.dropFirst() { #expect(try await workspace.repository.message(id: message.id, in: data.scope).folderIDs == [trash.id]) }
        #expect(model.queuedMailActions.allSatisfy { !$0.blocksQueue })
        #expect(model.queuedMailActions.count == (oldMatches ? 0 : 1))
        #expect(model.inboxCount == (oldMatches ? 0 : 1))
        #expect(model.mailActionQueueError == nil)
        #expect(await model.prepareToQuit()); try await workspace.close()
    }
    @Test func queuedIntentResumesAfterApplicationRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CuMail-native-action-restart-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try SyntheticFixtures.make(), keys = QueueTestSecrets()
        let paths = WorkspacePaths(root: root, cache: root.appendingPathComponent("Cache"))
        let workspace = try await LocalMailWorkspace.open(paths: paths, credentials: keys, syntheticSnapshot: data.snapshot)
        let first = InboxModel(dataset: data, workspace: workspace)
        await first.start(autoSelectDemo: false); try await ready { !first.isLoading }
        let message = try #require(first.displayedMessages.first)
        first.networkBusy = true; first.synchronizationActive = true; first.selection = [message.id]
        first.mutate(.read(true), expectedMessage: message.id)
        try await ready { first.queuedMailActions.count == 1 }
        let requestID = try #require(first.queuedMailActions.first?.id)
        #expect(await first.prepareToQuit())
        try await workspace.close()
        let reopened = try await LocalMailWorkspace.open(paths: paths, credentials: keys, syntheticSnapshot: data.snapshot)
        let second = InboxModel(dataset: data, workspace: reopened)
        await second.start(autoSelectDemo: false)
        try await ready { second.lastMailAction?.id == requestID && !second.mailActionProcessing && !second.hasQueuedMailActions }
        #expect(second.lastMailAction?.confirmedCount == 1 && !second.hasQueuedMailActions)
        #expect(try await !reopened.repository.message(id: message.id, in: data.scope).isUnread)
        #expect(await second.prepareToQuit()); try await reopened.close()
    }
    @Test func actionsStayAvailableDuringSyncAreDurableAndMoveOpensNextMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CuMail-native-action-queue-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try SyntheticFixtures.make()
        let workspace = try await LocalMailWorkspace.open(paths: WorkspacePaths(root: root, cache: root.appendingPathComponent("Cache")), credentials: QueueTestSecrets(), syntheticSnapshot: data.snapshot)
        let model = InboxModel(dataset: data, workspace: workspace)
        await model.start(autoSelectDemo: false); try await ready { !model.isLoading }
        let first = try #require(model.displayedMessages.first)
        let following = try #require(model.displayedMessages.dropFirst().first)
        model.selection = [first.id]; try await ready { !model.contentLoading }
        model.networkBusy = true; model.synchronizationActive = true
        #expect(model.canMutate)
        let archive = try #require(model.targetFolder(.archive))
        model.mutate(.move(archive), expectedMessage: first.id)
        try await ready { model.queuedMailActions.count == 1 }
        #expect(!model.canMutate && model.pendingActionMessageIDs.contains(first.id))
        #expect(try await workspace.repository.message(id: first.id, in: data.scope).folderIDs == first.folderIDs)
        #expect(try await workspace.repository.queuedMailActions(accounts: data.scope.accountIDs).count == 1)
        // No write overlaps the sync, even when several UI ticks pass.
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.queuedMailActions.first?.confirmedCount == 0)
        model.networkBusy = false; model.synchronizationActive = false
        try await ready { !model.hasQueuedMailActions && !model.mailActionProcessing && !model.isLoading && !model.contentLoading }
        #expect(try await workspace.repository.message(id: first.id, in: data.scope).folderIDs == [archive.id])
        #expect(model.selectedMessage?.id == following.id)
        #expect(model.lastMailAction?.confirmedCount == 1)
        #expect(await model.prepareToQuit())
        try await workspace.close()
    }

    @Test func multipleQueuedActionsAndUserNavigationRemainIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CuMail-native-action-navigation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try SyntheticFixtures.make()
        let workspace = try await LocalMailWorkspace.open(paths: WorkspacePaths(root: root, cache: root.appendingPathComponent("Cache")), credentials: QueueTestSecrets(), syntheticSnapshot: data.snapshot)
        let model = InboxModel(dataset: data, workspace: workspace)
        await model.start(autoSelectDemo: false); try await ready { !model.isLoading }
        let rows = Array(model.displayedMessages.prefix(3)); #expect(rows.count == 3)
        model.networkBusy = true; model.synchronizationActive = true
        for row in rows.prefix(2) {
            model.selection = [row.id]
            #expect(model.canMutate)
            model.mutate(.read(true), expectedMessage: row.id)
        }
        try await ready { model.queuedMailActions.count == 2 }
        model.selection = [rows[2].id]
        #expect(model.canMutate)
        model.networkBusy = false; model.synchronizationActive = false
        try await ready { !model.hasQueuedMailActions && !model.mailActionProcessing && !model.isLoading }
        for row in rows.prefix(2) { #expect(try await !workspace.repository.message(id: row.id, in: data.scope).isUnread) }
        #expect(model.selectedMessage?.id == rows[2].id)
        #expect(await model.prepareToQuit())
        try await workspace.close()
    }
    private func ready(_ condition: () -> Bool) async throws {
        for _ in 0..<600 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
