import Foundation
import Testing
import MCP
import MailApplication
import MailDomain
import MailPersistence
import MailSecurity
import MailDemo
import MailMCP
@testable import MikeMailHub

private actor AssistantQueueSecrets: CredentialStore, DatabaseKeyStore {
    func read(_ reference: CredentialReference) -> Data? { nil }
    func save(_ secret: Data, for reference: CredentialReference) {}
    func delete(_ reference: CredentialReference) {}
    func databaseKey(createIfMissing: Bool) -> Data { Data(repeating: 71, count: 32) }
    func deleteDatabaseKey() {}
}

@MainActor
private final class AssistantQueueFixture {
    let suite = "CuMail.assistant.queue.\(UUID())"
    let root = URL(fileURLWithPath: "/tmp/cumail-queue-\(UUID())")
    let data: DemoDataset
    let secrets = AssistantQueueSecrets()
    let defaults: UserDefaults
    var workspace: LocalMailWorkspace!
    var model: InboxModel!
    var paths: WorkspacePaths { WorkspacePaths(root: root, cache: root.appendingPathComponent("Cache")) }
    var gateway: AssistantGateway { get throws { try #require(model.assistant.gateway) } }
    init() async throws {
        data = try SyntheticFixtures.make()
        defaults = try #require(UserDefaults(suiteName: suite))
        try await open()
        for account in data.snapshot.accounts {
            await model.assistant.setAccountFolders(account.id, allowed: true)
            await model.assistant.setActions(account.id, allowed: true)
        }
        await model.assistant.setEnabled(true)
    }
    func open(holdChannel: Bool = false) async throws {
        workspace = try await LocalMailWorkspace.open(paths: paths, credentials: secrets, syntheticSnapshot: data.snapshot)
        let controller = AssistantController(defaults: defaults, directory: root.appendingPathComponent("mcp"))
        model = InboxModel(dataset: data, workspace: workspace, assistant: controller)
        model.networkBusy = holdChannel; model.synchronizationActive = holdChannel
        await model.start(autoSelectDemo: false)
        try await settled { !self.model.isLoading }
    }
    func restartHoldingChannel() async throws {
        #expect(await model.prepareToQuit()); try await workspace.close()
        try await open(holdChannel: true)
    }
    func close() async {
        _ = await model?.prepareToQuit(); try? await workspace?.close()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    func request(_ message: MailMessage, kind: String = "read", target: FolderID? = nil, id: UUID = UUID()) -> [String: Value] {
        var result: [String: Value] = ["account": .string(message.accountID.description), "email_ids": .array([.string(message.id.description)]), "action": .string(kind), "request_id": .string(id.uuidString)]
        if let target { result["target_folder"] = .string(target.description) }
        return result
    }
    func status(_ request: [String: Value]) async throws -> CallTool.Result {
        await (try gateway).call("get_mail_action", arguments: ["account": request["account"]!, "action_id": request["request_id"]!])
    }
    func release() { model.networkBusy = false; model.synchronizationActive = false }
    func settled(_ condition: () -> Bool) async throws {
        for _ in 0..<800 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}

@Suite(.serialized) @MainActor
struct AssistantMailActionQueueTests {
    private func withFixture(_ body: (AssistantQueueFixture) async throws -> Void) async throws {
        let fixture = try await AssistantQueueFixture()
        do { try await body(fixture); await fixture.close() }
        catch { await fixture.close(); throw error }
    }

    @Test func mcpReadArchiveAndTrashAreSavedDuringSyncAndReportConfirmedOnlyAfterExecution() async throws {
        try await withFixture { f in
            #expect(await (try f.gateway).call("mail_status", arguments: [:]).structuredContent?.objectValue?["mail_action_queue_enabled"] == .bool(true))
            let source = try #require(f.data.snapshot.messages.first)
            let rows = Array(f.data.snapshot.messages.filter { $0.accountID == source.accountID }.prefix(3))
            try #require(rows.count == 3)
            let archive = try #require(f.data.snapshot.folders.first { $0.accountID == source.accountID && $0.role == .archive })
            let trash = try #require(f.data.snapshot.folders.first { $0.accountID == source.accountID && $0.role == .trash })
            f.model.networkBusy = true; f.model.synchronizationActive = true
            let requests = [f.request(rows[0]), f.request(rows[1], kind: "move", target: archive.id), f.request(rows[2], kind: "move", target: trash.id)]
            for request in requests {
                let response = await (try f.gateway).call("request_mail_action", arguments: request)
                #expect(response.isError != true)
                #expect(response.structuredContent?.objectValue?["durably_queued"] == .bool(true))
                #expect(response.structuredContent?.objectValue?["queue_status"] == .string("waiting"))
                #expect(response.structuredContent?.objectValue?["confirmed"] == .int(0))
            }
            #expect(f.model.queuedMailActions.count == 3)
            #expect(f.model.queuedMailActions.allSatisfy { $0.assistantAuthorization != nil && $0.nativeQueue != true })
            #expect(try await f.workspace.repository.queuedMailActions(accounts: f.data.scope.accountIDs).count == 3)
            try await Task.sleep(for: .milliseconds(150))
            for row in rows { #expect(try await f.workspace.repository.message(id: row.id, in: f.data.scope).folderIDs == row.folderIDs) }
            #expect(try await f.status(requests[0]).structuredContent?.objectValue?["queue_status"] == .string("waiting"))
            f.release()
            try await f.settled { !f.model.hasQueuedMailActions && !f.model.mailActionProcessing && !f.model.isLoading }
            #expect(try await !f.workspace.repository.message(id: rows[0].id, in: f.data.scope).isUnread)
            #expect(try await f.workspace.repository.message(id: rows[1].id, in: f.data.scope).folderIDs == [archive.id])
            #expect(try await f.workspace.repository.message(id: rows[2].id, in: f.data.scope).folderIDs == [trash.id])
            for request in requests {
                let status = try await f.status(request)
                #expect(status.structuredContent?.objectValue?["confirmed"] == .int(1))
                #expect(status.structuredContent?.objectValue?["queue_status"] == .string("completed"))
            }
        }
    }

    @Test func mcpJobSurvivesRestartAndRepeatedRequestKeepsItsReceipt() async throws {
        try await withFixture { f in
            let source = try #require(f.data.snapshot.messages.first)
            f.model.networkBusy = true; f.model.synchronizationActive = true
            let request = f.request(source)
            #expect(await (try f.gateway).call("request_mail_action", arguments: request).isError != true)
            let saved = try #require(f.model.queuedMailActions.first)
            try await f.restartHoldingChannel()
            #expect(try await f.status(request).structuredContent?.objectValue?["queue_status"] == .string("waiting"))
            #expect(await (try f.gateway).call("request_mail_action", arguments: request).isError != true)
            #expect(f.model.queuedMailActions.count == 1 && f.model.queuedMailActions.first?.id == saved.id)
            #expect(f.model.queuedMailActions.first?.assistantAuthorization == saved.assistantAuthorization)
            f.release()
            try await f.settled { !f.model.hasQueuedMailActions && !f.model.mailActionProcessing && !f.model.isLoading }
            #expect(try await f.status(request).structuredContent?.objectValue?["confirmed"] == .int(1))
            #expect(await (try f.gateway).call("request_mail_action", arguments: request).structuredContent?.objectValue?["queue_status"] == .string("completed"))
            #expect(try await f.workspace.repository.mailAction(id: saved.id, account: source.accountID)?.createdAt == saved.createdAt)
        }
    }

    @Test func revokedAndRegrantedAccessDoesNotReviveAnEarlierJob() async throws {
        try await withFixture { f in
            let source = try #require(f.data.snapshot.messages.first)
            f.model.networkBusy = true; f.model.synchronizationActive = true
            let request = f.request(source, kind: source.isUnread ? "read" : "unread")
            #expect(await (try f.gateway).call("request_mail_action", arguments: request).isError != true)
            await f.model.assistant.setActions(source.accountID, allowed: false)
            await f.model.assistant.setActions(source.accountID, allowed: true)
            f.release()
            try await f.settled { !f.model.hasQueuedMailActions && !f.model.mailActionProcessing && !f.model.isLoading }
            #expect(try await f.workspace.repository.message(id: source.id, in: f.data.scope).isUnread == source.isUnread)
            let result = try #require(f.model.queuedMailActions.first)
            #expect(result.needsAttention && result.items[0].state == .notAttempted && result.uncertainCount == 0)
            #expect(try await f.status(request).structuredContent?.objectValue?["queue_status"] == .string("needs_attention"))
        }
    }
}
