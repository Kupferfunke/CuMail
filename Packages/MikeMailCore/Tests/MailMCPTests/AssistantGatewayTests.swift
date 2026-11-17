import Foundation
import Testing
import MCP
import MailDomain
import MailApplication
import MailDemo
@testable import MailMCP

private actor PausedText {
    var started = false
    var continuation: CheckedContinuation<String, Never>?
    func read() async -> String {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: "private text"); continuation = nil }
}

struct AssistantGatewayTests {
    private func setup() throws -> (DemoDataset, AssistantGateway, AssistantGrant) {
        let data = try SyntheticFixtures.make(), repository = data.repository()
        let gateway = AssistantGateway(service: InboxService(repository: repository)) { id, scope in try await repository.text(for: id, scope: scope) }
        let first = data.snapshot.messages[0]
        var grant = AssistantGrant(); grant.enabled = true; grant.accountIDs = [first.accountID]; grant.folderIDs = first.folderIDs
        return (data, gateway, grant)
    }
    @Test func defaultDenyAndDirectIDsCannotEscapeAccountOrFolderScope() async throws {
        let (data, gateway, grant) = try setup()
        #expect(await gateway.call("mail_status", arguments: [:]).isError == true)
        await gateway.setGrant(grant)
        let status = await gateway.call("mail_status", arguments: [:])
        #expect(status.isError != true)
        let accountIDs = status.structuredContent?.objectValue?["accounts"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue }
        #expect(accountIDs == grant.accountIDs.map(\.description))
        let foreign = try #require(data.snapshot.messages.first { !grant.accountIDs.contains($0.accountID) })
        #expect(await gateway.call("get_email", arguments: ["email_id": .string(foreign.id.description)]).isError == true)
        #expect(await gateway.call("search_emails", arguments: ["account": .string(foreign.accountID.description)]).isError == true)
        var empty = grant; empty.folderIDs = []; await gateway.setGrant(empty)
        #expect(await gateway.call("get_email", arguments: ["email_id": .string(data.snapshot.messages[0].id.description)]).isError == true)
    }
    @Test func metadataProjectionOmitsProviderIDsHeadersBodiesAndUnsharedLabels() async throws {
        let (data, gateway, grant) = try setup(); await gateway.setGrant(grant)
        let result = await gateway.call("search_emails", arguments: ["limit": .int(1)])
        let record = try #require(result.structuredContent?.objectValue?["items"]?.arrayValue?.first?.objectValue)
        #expect(record["locator"] == nil && record["preview"] == nil && record["internetMessageID"] == nil && record["text"] == nil)
        #expect(record["deep_link"]?.stringValue?.hasPrefix("cumail://message/") == true)
        #expect(await gateway.call("get_email", arguments: ["email_id": .string(data.snapshot.messages[0].id.description), "include_text": .bool(true)]).isError == true)
        let page = try #require(result.structuredContent?.objectValue)
        #expect(page["coverage"]?.objectValue?["metadata_only"] == .bool(true))
    }
    @Test func textIsExplicitBoundedUntrustedAndLeavesReadStatusUntouched() async throws {
        let (data, gateway, initial) = try setup(); var grant = initial; grant.allowText = true
        await gateway.setGrant(grant)
        let message = data.snapshot.messages[0]
        let result = await gateway.call("get_email", arguments: ["email_id": .string(message.id.description), "include_text": .bool(true), "max_text_characters": .int(8)])
        let object = try #require(result.structuredContent?.objectValue)
        #expect(object["text"]?.stringValue?.count == 8)
        #expect(object["truncated"] == .bool(true))
        #expect(object["unread"] == .bool(message.isUnread))
        #expect(object["notice"]?.stringValue?.contains("untrusted") == true)
        #expect(AssistantGateway.clean("a\u{202E}b\u{0000}c", limit: 5) == "abc")
    }
    @Test func revokeWhileReadingDropsTheResultBeforeItCanBeReturned() async throws {
        let (data, _, initial) = try setup(); var grant = initial; grant.allowText = true
        let source = PausedText()
        let gateway = AssistantGateway(service: InboxService(repository: data.repository())) { _, _ in await source.read() }
        await gateway.setGrant(grant)
        let task = Task { await gateway.call("get_email", arguments: ["email_id": .string(data.snapshot.messages[0].id.description), "include_text": .bool(true)]) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await !source.started, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await source.started)
        await gateway.setGrant(AssistantGrant()); await source.finish()
        let result = await task.value
        #expect(result.isError == true && result.structuredContent == nil)
    }
    @Test func malformedArgumentsUnknownToolsAndRateLimitsAreEnforced() async throws {
        let (_, gateway, grant) = try setup(); await gateway.setGrant(grant)
        for args: [String: Value] in [["limit": .int(101)], ["limit": .bool(true)], ["query": .string(String(repeating: "x", count: 1025))], ["sql": .string("SELECT *")], ["account": .string("invalid")]] {
            #expect(await gateway.call("search_emails", arguments: args).isError == true)
        }
        #expect(await gateway.call("send_email", arguments: [:]).isError == true)
        for _ in 0..<30 { _ = await gateway.call("mail_status", arguments: [:]) }
        #expect(await gateway.call("mail_status", arguments: [:]).isError == true)
        #expect(await gateway.recentAudit().count <= 50)
    }
    @Test func sdkHandshakeLabelsWritesSeparatelyAndRevocationIsEffective() async throws {
        let (_, gateway, grant) = try setup(); await gateway.setGrant(grant)
        let transport = await InMemoryTransport.createConnectedPair()
        let server = await gateway.server(); try await server.start(transport: transport.server)
        let client = Client(name: "Synthetic phase 10", version: "1")
        let initialized = try await client.connect(transport: transport.client)
        #expect(initialized.capabilities.tools != nil && initialized.capabilities.resources == nil)
        let tools = try await client.listTools().tools
        #expect(tools.count == 16 && tools.filter { $0.annotations.readOnlyHint == true }.count == 9)
        #expect(tools.first { $0.name == "send_email_now" }?.annotations.destructiveHint == true)
        #expect(tools.first { $0.name == "prepare_email" }?.annotations.readOnlyHint == false)
        #expect(tools.first { $0.name == "request_email_send" }?.annotations.destructiveHint == true)
        #expect(tools.first { $0.name == "prepare_reply" }?.annotations.readOnlyHint == false)
        #expect(tools.first { $0.name == "request_reply_send" }?.annotations.destructiveHint == true)
        let result = try await client.callTool(name: "mail_status", arguments: [:])
        #expect(result.isError != true)
        await gateway.setGrant(AssistantGrant())
        let denied = try await client.callTool(name: "mail_status", arguments: [:])
        #expect(denied.isError == true)
        await client.disconnect(); await server.stop()
    }
    @Test func recentWindowAndAttachmentSearchStayBounded() async throws {
        let (data, gateway, grant) = try setup(); await gateway.setGrant(grant)
        let result = await gateway.call("recent_emails", arguments: ["hours": .int(1)])
        #expect(result.isError != true)
        #expect(result.structuredContent?.objectValue?["window_start"]?.stringValue != nil)
        let attachments = await gateway.call("search_attachments", arguments: [:])
        let values = try #require(attachments.structuredContent?.objectValue?["items"]?.arrayValue)
        #expect(values.allSatisfy { $0.objectValue?["has_attachments"] == .bool(true) })
        #expect(values.count <= data.snapshot.messages.count)
        #expect(await gateway.call("recent_emails", arguments: ["hours": .int(721)]).isError == true)
    }
}
