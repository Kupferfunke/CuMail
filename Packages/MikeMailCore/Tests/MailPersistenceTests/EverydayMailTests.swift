import Foundation
import Testing
import MailDomain
import MailApplication
import MailDemo
@testable import MailPersistence

private actor WriteProbe {
    var calls = 0
    var revoked = false
    func write() -> Int { calls += 1; return calls }
    func revoke() { revoked = true }
    func authorize() throws { if revoked { throw MailFailure.permissionDenied } }
}

struct EverydayMailTests {
    @Test func textScanResumesSkipsFailuresAndSearchHonorsTextPermission() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make()
        var repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(data.snapshot)
        let account = data.snapshot.accounts[0].id
        #expect(try await repo.nextContentIndexMessage(account: account) == nil)
        var settings = try await repo.settings(for: account)
        settings.textIndexEnabled = true; settings.fullTextIndexEnabled = true
        try await repo.saveSettings(settings)
        let first = try #require(try await repo.nextContentIndexMessage(account: account))
        try await repo.storeExtract("uniquecumailbodyword", for: first.id, account: account)
        let second = try #require(try await repo.nextContentIndexMessage(account: account))
        #expect(first.id != second.id)
        try await repo.recordContentIndexIssue(.unavailable, message: second.id, account: account, now: Date())
        let progress = try await repo.contentIndexProgress(account: account)
        #expect(progress.indexed == 1 && progress.retrying == 1 && progress.skipped == 0)
        #expect(try await repo.message(id: first.id, in: data.scope).isUnread == first.isUnread)
        try await repo.close()
        repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        #expect(try await repo.settings(for: account).fullTextIndexEnabled)
        #expect(try await repo.nextContentIndexMessage(account: account)?.id != first.id)
        #expect(try await repo.nextContentIndexMessage(account: account)?.id != second.id)
        var query = MessageFilter(); query.text = "uniquecumailbodyword"
        let service = InboxService(repository: repo)
        #expect(try await service.search(query, page: PageRequest(), scope: data.scope).items.map(\.id) == [first.id])
        query.includeIndexedText = false
        #expect(try await service.search(query, page: PageRequest(), scope: data.scope).items.isEmpty)
        try await repo.recordContentIndexIssue(.noText, message: second.id, account: account)
        #expect(try await repo.contentIndexProgress(account: account).skipped == 1)
        try await repo.clearExtracts(account: account)
        #expect(try await repo.contentIndexProgress(account: account).indexed == 0)
        #expect(try await !repo.settings(for: account).fullTextIndexEnabled)
        try await repo.close()
    }

    @Test func bulkActionIsIdempotentUndoRestoresMixedFlagsAndNeverEscapesScope() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(data.snapshot)
        let account = data.snapshot.accounts[0].id
        let messages = Array(data.snapshot.messages.filter { $0.accountID == account }.prefix(3))
        let probe = WriteProbe()
        let actions = MailActions(service: InboxService(repository: repo), store: repo) { mutation, message, _, scope in
            _ = await probe.write()
            try await repo.performDemoMutation(mutation, message: message.id, scope: scope)
        }
        let request = try MailActionRequest(accountID: account, messageIDs: messages.map(\.id), kind: .read)
        _ = try await actions.prepare(request, scope: data.scope, authorize: {})
        let result = try await actions.execute(id: request.id, account: account, scope: data.scope, authorize: {})
        #expect(result.confirmedCount == messages.count && result.canUndo)
        _ = try await actions.prepare(request, scope: data.scope, authorize: {})
        _ = try await actions.execute(id: request.id, account: account, scope: data.scope, authorize: {})
        #expect(await probe.calls == messages.count)
        let undoID = UUID()
        let undone = try await actions.undo(id: request.id, account: account, undoID: undoID, scope: data.scope, authorize: {})
        #expect(undone.items.allSatisfy { $0.state == .undone })
        for message in messages { #expect(try await repo.message(id: message.id, in: data.scope).isUnread == message.isUnread) }
        _ = try await actions.undo(id: request.id, account: account, undoID: undoID, scope: data.scope, authorize: {})
        #expect(await probe.calls == messages.count * 2)
        let foreign = try #require(data.snapshot.messages.first { $0.accountID != account })
        await #expect(throws: MailFailure.permissionDenied) {
            try await actions.prepare(MailActionRequest(accountID: account, messageIDs: [foreign.id], kind: .read), scope: data.scope, authorize: {})
        }
        await #expect(throws: MailFailure.notFound) {
            try await actions.get(id: request.id, account: account, scope: AccessScope(accountIDs: [account], folderIDs: []))
        }
        let changed = try MailActionRequest(id: request.id, accountID: account, messageIDs: messages.map(\.id), kind: .unread)
        await #expect(throws: MailFailure.invalidInput) { try await actions.prepare(changed, scope: data.scope, authorize: {}) }
        try await repo.close()
    }

    @Test func interruptedBulkStopsAndRestartCannotReplayUncertainWrite() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make()
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(data.snapshot)
        let account = data.snapshot.accounts[0].id, probe = WriteProbe()
        let messages = Array(data.snapshot.messages.filter { $0.accountID == account }.prefix(3))
        let actions = MailActions(service: InboxService(repository: repo), store: repo) { mutation, message, _, scope in
            let n = await probe.write()
            try await repo.performDemoMutation(mutation, message: message.id, scope: scope)
            if n == 2 { throw MailFailure.offline } // Server may have accepted; response was lost.
        }
        let request = try MailActionRequest(accountID: account, messageIDs: messages.map(\.id), kind: .flag)
        _ = try await actions.prepare(request, scope: data.scope, authorize: {})
        let result = try await actions.execute(id: request.id, account: account, scope: data.scope, authorize: {})
        #expect(result.confirmedCount == 1 && result.uncertainCount == 1 && result.items.last?.state == .notAttempted)
        try await repo.close()
        let reopened = try EncryptedMailRepository(paths: test.paths, key: test.key)
        let afterRestart = MailActions(service: InboxService(repository: reopened), store: reopened) { _, _, _, _ in _ = await probe.write() }
        _ = try await afterRestart.prepare(request, scope: data.scope, authorize: {})
        _ = try await afterRestart.execute(id: request.id, account: account, scope: data.scope, authorize: {})
        #expect(await probe.calls == 2)
        try await reopened.close()
    }

    @Test func revocationBetweenItemsStopsBeforeAnotherNetworkWrite() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(data.snapshot)
        let account = data.snapshot.accounts[0].id, probe = WriteProbe()
        let messages = Array(data.snapshot.messages.filter { $0.accountID == account }.prefix(3))
        let actions = MailActions(service: InboxService(repository: repo), store: repo) { mutation, message, _, scope in
            _ = await probe.write(); try await repo.performDemoMutation(mutation, message: message.id, scope: scope); await probe.revoke()
        }
        let request = try MailActionRequest(accountID: account, messageIDs: messages.map(\.id), kind: .flag)
        _ = try await actions.prepare(request, scope: data.scope, authorize: { try await probe.authorize() })
        let result = try await actions.execute(id: request.id, account: account, scope: data.scope, authorize: { try await probe.authorize() })
        #expect(result.confirmedCount == 1 && result.uncertainCount == 0)
        #expect(await probe.calls == 1)
        try await repo.close()
    }
    @Test func crashDuringWriteBecomesUncertainWithoutAutomaticReplay() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(data.snapshot)
        let message = data.snapshot.messages[0], probe = WriteProbe()
        let actions = MailActions(service: InboxService(repository: repo), store: repo) { _, _, _, _ in _ = await probe.write() }
        let request = try MailActionRequest(accountID: message.accountID, messageIDs: [message.id], kind: .flag)
        var receipt = try await actions.prepare(request, scope: data.scope, authorize: {})
        receipt.items[0].state = .inFlight; try await repo.saveMailAction(receipt)
        let recovered = try await actions.get(id: request.id, account: message.accountID, scope: data.scope)
        #expect(recovered.finished && recovered.uncertainCount == 1 && !recovered.canUndo)
        _ = try await actions.execute(id: request.id, account: message.accountID, scope: data.scope, authorize: {})
        #expect(await probe.calls == 0)
        try await repo.close()
    }
}
