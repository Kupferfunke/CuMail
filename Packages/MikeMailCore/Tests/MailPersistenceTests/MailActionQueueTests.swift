import Foundation
import Testing
import MailApplication
import MailDomain
import MailDemo
@testable import MailPersistence

private actor QueueWrites {
    var count = 0
    func record() { count += 1 }
}
private actor QueueAuthorizationChecks {
    var count = 0
    func failSecond(cancel: Bool) throws {
        count += 1
        if count == 2 { if cancel { throw CancellationError() }; throw MailFailure.permissionDenied }
    }
}

struct MailActionQueueTests {
    @Test(arguments: [false, true]) func uncertainResultCanBeCheckedWithoutRepeatingItsWrite(matches: Bool) async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), source = data.snapshot.messages[0]
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(data.snapshot)
        let writes = QueueWrites()
        let actions = MailActions(service: InboxService(repository: repo), store: repo) { _, _, _, _ in await writes.record() }
        let request = try MailActionRequest(accountID: source.accountID, messageIDs: [source.id], kind: .read)
        var stored = try await actions.prepare(request, scope: data.scope, nativeQueue: true, authorize: {})
        stored.items[0].state = .uncertain; stored.finished = true
        try await repo.saveMailAction(stored)
        await #expect(throws: MailFailure.authenticationExpired) {
            try await actions.reconcile(id: request.id, account: source.accountID, scope: data.scope, authorize: {}, verify: { _, _, _, _ in throw MailFailure.authenticationExpired })
        }
        #expect(try await actions.get(id: request.id, account: source.accountID, scope: data.scope).blocksQueue)
        let checked = try await actions.reconcile(id: request.id, account: source.accountID, scope: data.scope, authorize: {}, verify: { _, _, _, _ in matches })
        #expect(!checked.blocksQueue && checked.items[0].checkedAt != nil)
        #expect(checked.items[0].state == (matches ? .confirmed : .uncertain))
        #expect(checked.finished && checked.uncertainCount == (matches ? 0 : 1))
        _ = try await actions.execute(id: request.id, account: source.accountID, scope: data.scope, authorize: {})
        #expect(await writes.count == 0)
        if !matches {
            let nowConfirmed = try await actions.reconcile(id: request.id, account: source.accountID, scope: data.scope, authorize: {}, verify: { _, _, _, _ in true })
            #expect(nowConfirmed.confirmedCount == 1 && !nowConfirmed.blocksQueue)
            #expect(await writes.count == 0)
            // Restore the earlier checked snapshot to exercise restart persistence.
            try await repo.saveMailAction(checked)
        }
        try await repo.close()
        let reopened = try EncryptedMailRepository(paths: test.paths, key: test.key)
        #expect(try await reopened.mailAction(id: request.id, account: source.accountID) == checked)
        try await reopened.close()
    }
    @Test func waitingActionsSurviveRestartAndExecuteOnceInOrder() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), source = data.snapshot.messages[0]
        let repository = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repository.seedIfNeeded(data.snapshot)
        let initial = MailActions(service: InboxService(repository: repository), store: repository) { _, _, _, _ in Issue.record("Preparing must not write to the provider") }
        let first = try MailActionRequest(accountID: source.accountID, messageIDs: [source.id], kind: .read)
        let second = try MailActionRequest(accountID: source.accountID, messageIDs: [source.id], kind: .flag)
        _ = try await initial.prepare(first, scope: data.scope, nativeQueue: true, authorize: {})
        let authorization = AssistantActionAuthorization(folderIDs: source.folderIDs)
        _ = try await initial.prepare(second, scope: data.scope, assistantAuthorization: authorization, authorize: {})
        let assistant = try MailActionRequest(accountID: source.accountID, messageIDs: [source.id], kind: .unread)
        _ = try await initial.prepare(assistant, scope: data.scope, authorize: {})
        try await repository.close()
        let reopened = try EncryptedMailRepository(paths: test.paths, key: test.key), writes = QueueWrites()
        let actions = MailActions(service: InboxService(repository: reopened), store: reopened) { mutation, message, _, scope in
            await writes.record(); try await reopened.performDemoMutation(mutation, message: message.id, scope: scope)
        }
        #expect(try await actions.queue(scope: data.scope).map(\.id) == [first.id, second.id])
        for request in [first, first, second, second] {
            #expect(try await actions.execute(id: request.id, account: request.accountID, scope: data.scope, authorize: {}).confirmedCount == 1)
        }
        #expect(await writes.count == 2)
        #expect(try await actions.queue(scope: data.scope).isEmpty)
        let result = try await reopened.message(id: source.id, in: data.scope)
        #expect(!result.isUnread && result.isFlagged)
        try await reopened.close()
    }

    @Test(arguments: [false, true]) func crashedInFlightActionsStayVisibleAndNeverReplay(assistant: Bool) async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), source = data.snapshot.messages[0]
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(data.snapshot)
        let writes = QueueWrites()
        let actions = MailActions(service: InboxService(repository: repo), store: repo) { _, _, _, _ in await writes.record() }
        let request = try MailActionRequest(accountID: source.accountID, messageIDs: [source.id], kind: .read)
        var receipt = try await actions.prepare(request, scope: data.scope, nativeQueue: !assistant,
            assistantAuthorization: assistant ? AssistantActionAuthorization(folderIDs: source.folderIDs) : nil, authorize: {})
        receipt.items[0].state = .inFlight; try await repo.saveMailAction(receipt)
        let recovered = try #require(try await actions.queue(scope: data.scope).first)
        #expect(recovered.needsAttention && recovered.uncertainCount == 1)
        _ = try await actions.execute(id: receipt.id, account: request.accountID, scope: data.scope, authorize: {})
        #expect(await writes.count == 0)
        #expect(try await actions.queue(scope: data.scope).count == 1)
        try await actions.dismissQueueResult(id: receipt.id, account: request.accountID, scope: data.scope)
        #expect(try await actions.queue(scope: data.scope).isEmpty)
        #expect(try await repo.mailAction(id: receipt.id, account: request.accountID)?.uncertainCount == 1)
        try await repo.close()
    }

    @Test(arguments: [false, true]) func partiallyConfirmedBatchResumesOnlyUnattemptedItems(assistant: Bool) async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), account = data.snapshot.accounts[0]
        let sources = Array(data.snapshot.messages.filter { $0.accountID == account.id }.prefix(2))
        #expect(sources.count == 2)
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(data.snapshot)
        let writes = QueueWrites()
        let actions = MailActions(service: InboxService(repository: repo), store: repo) { mutation, message, _, scope in
            await writes.record(); try await repo.performDemoMutation(mutation, message: message.id, scope: scope)
        }
        let request = try MailActionRequest(accountID: account.id, messageIDs: sources.map(\.id), kind: .read)
        var receipt = try await actions.prepare(request, scope: data.scope, nativeQueue: !assistant,
            assistantAuthorization: assistant ? AssistantActionAuthorization(folderIDs: Set(sources.flatMap(\.folderIDs))) : nil, authorize: {})
        receipt.items[0].state = .confirmed
        try await repo.performDemoMutation(.read(true), message: receipt.items[0].messageID, scope: data.scope)
        try await repo.saveMailAction(receipt)
        let result = try await actions.execute(id: receipt.id, account: account.id, scope: data.scope, authorize: {})
        #expect(result.confirmedCount == 2 && result.finished && !result.needsAttention)
        #expect(await writes.count == 1)
        try await repo.close()
    }

    @Test func cancellationBeforeWritePreservesQueueAndChangedFolderIsReported() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), source = data.snapshot.messages[0]
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(data.snapshot)
        let writes = QueueWrites()
        let actions = MailActions(service: InboxService(repository: repo), store: repo) { _, _, _, _ in await writes.record() }
        let request = try MailActionRequest(accountID: source.accountID, messageIDs: [source.id], kind: .read)
        _ = try await actions.prepare(request, scope: data.scope, nativeQueue: true, authorize: {})
        let cancelled = try await actions.execute(id: request.id, account: request.accountID, scope: data.scope, authorize: { throw CancellationError() })
        #expect(!cancelled.finished && cancelled.items[0].state == .waiting)
        let target = try #require(data.snapshot.folders.first { $0.accountID == source.accountID && !source.folderIDs.contains($0.id) })
        try await repo.performDemoMutation(.move(target), message: source.id, scope: data.scope)
        let result = try await actions.execute(id: request.id, account: request.accountID, scope: data.scope, authorize: {})
        #expect(result.needsAttention && result.items[0].state == .notAttempted)
        #expect(try await actions.queue(scope: data.scope).count == 1)
        #expect(await writes.count == 0)
        try await repo.close()
    }

    @Test func concurrentAssistantAdmissionsNeverOverwriteAnExistingReceipt() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), source = data.snapshot.messages[0]
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(data.snapshot)
        let writes = QueueWrites()
        let actions = MailActions(service: InboxService(repository: repo), store: repo) { _, _, _, _ in await writes.record() }
        let request = try MailActionRequest(accountID: source.accountID, messageIDs: [source.id], kind: .read)
        let authorization = AssistantActionAuthorization(folderIDs: source.folderIDs)
        try await withThrowingTaskGroup(of: MailActionReceipt.self) { group in
            for _ in 0..<20 {
                group.addTask { try await actions.prepare(request, scope: data.scope, assistantAuthorization: authorization, authorize: {}) }
            }
            for try await receipt in group { #expect(receipt.id == request.id) }
        }
        #expect(try await actions.queue(scope: data.scope).count == 1)
        let finished = try await actions.execute(id: request.id, account: source.accountID, scope: data.scope, authorize: {})
        let repeated = try await actions.prepare(request, scope: data.scope, assistantAuthorization: authorization, authorize: {})
        #expect(repeated == finished && repeated.finished && repeated.confirmedCount == 1)
        let conflict = try MailActionRequest(id: request.id, accountID: source.accountID, messageIDs: [source.id], kind: .unread)
        await #expect(throws: MailFailure.invalidInput) {
            try await actions.prepare(conflict, scope: data.scope, assistantAuthorization: authorization, authorize: {})
        }
        _ = try await actions.execute(id: request.id, account: source.accountID, scope: data.scope, authorize: {})
        #expect(await writes.count == 1)
        try await repo.close()
    }

    @Test(arguments: [false, true]) func cancellationOrRevocationBeforeProviderCallIsNeverReportedAsAnUncertainWrite(cancel: Bool) async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), source = data.snapshot.messages[0]
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(data.snapshot)
        let writes = QueueWrites(), checks = QueueAuthorizationChecks()
        let actions = MailActions(service: InboxService(repository: repo), store: repo) { _, _, _, _ in await writes.record() }
        let request = try MailActionRequest(accountID: source.accountID, messageIDs: [source.id], kind: .read)
        _ = try await actions.prepare(request, scope: data.scope, assistantAuthorization: AssistantActionAuthorization(folderIDs: source.folderIDs), authorize: {})
        let result = try await actions.execute(id: request.id, account: source.accountID, scope: data.scope, authorize: { try await checks.failSecond(cancel: cancel) })
        #expect(await writes.count == 0)
        #expect(result.uncertainCount == 0)
        #expect(result.items[0].state == (cancel ? .waiting : .notAttempted))
        #expect(result.finished == !cancel)
        try await repo.close()
    }

    @Test func interruptedUndoCannotBecomeARepeatedForwardAction() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), account = data.snapshot.accounts[0]
        let rows = Array(data.snapshot.messages.filter { $0.accountID == account.id }.prefix(2))
        try #require(rows.count == 2)
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(data.snapshot)
        let writes = QueueWrites()
        let actions = MailActions(service: InboxService(repository: repo), store: repo) { _, _, _, _ in await writes.record() }
        let request = try MailActionRequest(accountID: account.id, messageIDs: rows.map(\.id), kind: .read)
        var receipt = try await actions.prepare(request, scope: data.scope,
            assistantAuthorization: AssistantActionAuthorization(folderIDs: Set(rows.flatMap(\.folderIDs))), authorize: {})
        receipt.undoRequestID = UUID(); receipt.items[0].state = .undone; receipt.items[1].state = .confirmed
        try await repo.saveMailAction(receipt)
        let recovered = try await actions.get(id: request.id, account: account.id, scope: data.scope)
        #expect(recovered.finished && recovered.items[0].state == .undone && recovered.items[1].state == .confirmed)
        #expect(try await actions.queue(scope: data.scope).isEmpty)
        _ = try await actions.execute(id: request.id, account: account.id, scope: data.scope, authorize: {})
        #expect(await writes.count == 0)
        try await repo.close()
    }
}
