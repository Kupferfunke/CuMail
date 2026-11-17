import Foundation
import Testing
import MCP
import MailDomain
import MailApplication
import MailDemo
import MailPersistence
@testable import MailMCP

private actor ActionCounter {
    var writes = 0
    func wrote() { writes += 1 }
}
struct AssistantMailActionTests {
    @Test func actionsNeedSeparateGrantAndRetriesAndUndoAreIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CuMail-actions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try SyntheticFixtures.make(), first = data.snapshot.messages[0]
        let repo = try EncryptedMailRepository(paths: WorkspacePaths(root: root, cache: root.appendingPathComponent("Cache")), key: Data(repeating: 42, count: 32))
        try await repo.seedIfNeeded(data.snapshot)
        let service = InboxService(repository: repo), counter = ActionCounter()
        let actions = MailActions(service: service, store: repo) { mutation, message, _, scope in
            await counter.wrote(); try await repo.performDemoMutation(mutation, message: message.id, scope: scope)
        }
        let handlers = AssistantMailActions(submit: { request, scope, authorize in
            _ = try await actions.prepare(request, scope: scope, authorize: authorize)
            return try await actions.execute(id: request.id, account: request.accountID, scope: scope, authorize: authorize)
        }, read: { id, account, scope in try await actions.get(id: id, account: account, scope: scope) },
        undo: { id, account, request, scope, authorize in try await actions.undo(id: id, account: account, undoID: request, scope: scope, authorize: authorize) })
        let gateway = AssistantGateway(service: service, actions: handlers) { _, _ in "" }
        var grant = AssistantGrant(); grant.enabled = true; grant.accountIDs = [first.accountID]; grant.folderIDs = first.folderIDs
        await gateway.setGrant(grant)
        let id = UUID(), undoID = UUID()
        let request: [String: Value] = ["account": .string(first.accountID.description), "email_ids": .array([.string(first.id.description)]), "action": .string("read"), "request_id": .string(id.uuidString)]
        #expect(await gateway.call("request_mail_action", arguments: request).isError == true)
        #expect(await counter.writes == 0)
        grant.actionAccountIDs = [first.accountID]; await gateway.setGrant(grant)
        let result = await gateway.call("request_mail_action", arguments: request)
        #expect(result.isError != true && result.structuredContent?.objectValue?["confirmed"] == .int(1))
        #expect(await gateway.call("request_mail_action", arguments: request).isError != true)
        #expect(await counter.writes == 1)
        let undo: [String: Value] = ["account": .string(first.accountID.description), "action_id": .string(id.uuidString), "request_id": .string(undoID.uuidString)]
        #expect(await gateway.call("undo_mail_action", arguments: undo).isError != true)
        #expect(await gateway.call("undo_mail_action", arguments: undo).isError != true)
        #expect(await counter.writes == 2)
        #expect(try await repo.message(id: first.id, in: data.scope).isUnread == first.isUnread)
        grant.folderIDs = []; await gateway.setGrant(grant)
        #expect(await gateway.call("get_mail_action", arguments: ["account": .string(first.accountID.description), "action_id": .string(id.uuidString)]).isError == true)
        try await repo.close()
    }
    @Test func oldGrantsNeverAcquireActionRightsAndToolsAdvertiseWrites() throws {
        let old = Data(#"{"enabled":true,"accountIDs":[],"folderIDs":[],"allowText":true,"replyAccountIDs":[]}"#.utf8)
        #expect(try JSONDecoder().decode(AssistantGrant.self, from: old).actionAccountIDs.isEmpty)
        #expect(AssistantGateway.tools.first { $0.name == "request_mail_action" }?.annotations.readOnlyHint == false)
        #expect(AssistantGateway.tools.first { $0.name == "undo_mail_action" }?.annotations.destructiveHint == true)
        #expect(AssistantGateway.tools.first { $0.name == "get_mail_action" }?.annotations.readOnlyHint == true)
    }
}
