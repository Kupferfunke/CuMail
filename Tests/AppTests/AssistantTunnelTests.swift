import Foundation
import Testing
import MailApplication
import MailDemo
@testable import MikeMailHub

private actor TunnelSecrets: CredentialStore {
    var stored: Data?
    var reads = 0
    func read(_ reference: CredentialReference) throws -> Data? { reads += 1; return stored }
    func save(_ secret: Data, for reference: CredentialReference) throws { stored = secret }
    func delete(_ reference: CredentialReference) throws { stored = nil }
}

@MainActor @Suite(.serialized) struct AssistantTunnelTests {
    @Test func newMessagePermissionPersistsSeparatelyAndClearsWithAccountAccess() async throws {
        let suite = "CuMail.compose.grant.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let data = try SyntheticFixtures.make()
        let account = try #require(data.snapshot.accounts.first { $0.provider != .microsoft })
        let controller = AssistantController(defaults: defaults)
        await controller.configure(service: InboxService(repository: data.repository()), accounts: data.snapshot.accounts, folders: data.snapshot.folders) { _, _ in "synthetic" }
        await controller.setCompose(account.id, allowed: true)
        #expect(controller.grant.composeAccountIDs.isEmpty)
        await controller.setAccountFolders(account.id, allowed: true)
        await controller.setCompose(account.id, allowed: true)
        #expect(controller.grant.composeAccountIDs == [account.id] && controller.grant.replyAccountIDs.isEmpty)
        #expect(controller.grant.directSendAccountIDs.isEmpty)
        await controller.setDirectSend(account.id, allowed: true)
        let restored = AssistantController(defaults: defaults)
        #expect(restored.grant.composeAccountIDs == [account.id])
        #expect(restored.grant.directSendAccountIDs == [account.id])
        await restored.configure(service: InboxService(repository: data.repository()), accounts: data.snapshot.accounts, folders: data.snapshot.folders) { _, _ in "synthetic" }
        await restored.setAccountFolders(account.id, allowed: false)
        #expect(restored.grant.composeAccountIDs.isEmpty)
        #expect(restored.grant.directSendAccountIDs.isEmpty)
        #expect(AssistantController(defaults: defaults).grant.composeAccountIDs.isEmpty)
    }
    @Test func directSendPermissionNeedsPreparationPermissionAndDisablesWithItsLastGrant() async throws {
        let data = try SyntheticFixtures.make(), controller = AssistantController(defaults: nil)
        let account = try #require(data.snapshot.accounts.first { $0.provider != .microsoft })
        await controller.configure(service: InboxService(repository: data.repository()), accounts: data.snapshot.accounts, folders: data.snapshot.folders) { _, _ in "synthetic" }
        await controller.setAccountFolders(account.id, allowed: true)
        await controller.setDirectSend(account.id, allowed: true)
        #expect(controller.grant.directSendAccountIDs.isEmpty)
        await controller.setReplies(account.id, allowed: true)
        await controller.setCompose(account.id, allowed: true)
        await controller.setDirectSend(account.id, allowed: true)
        await controller.setReplies(account.id, allowed: false)
        #expect(controller.grant.directSendAccountIDs == [account.id])
        await controller.setCompose(account.id, allowed: false)
        #expect(controller.grant.directSendAccountIDs.isEmpty)
    }
    @Test func launchesAndStopsARealChildWithoutMutatingFrozenProcessSettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mmh-child-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        // This isolated executable never connects to a network or reads a real
        // credential. A real Process catches Objective-C launch-setting errors
        // that a mocked credential store and configuration-only tests miss.
        for name in ["tunnel-client", "MikeMailBridgeSandboxed"] {
            let executable = directory.appendingPathComponent(name)
            try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let controller = AssistantTunnelController(defaults: nil, directory: directory, helpersDirectory: directory)
        controller.configure(credentials: TunnelSecrets())
        #expect(await controller.saveConfiguration(tunnelID: "tunnel_0123456789abcdef0123456789abcdef", key: "sk-synthetic-only-for-child-test"))
        await controller.setEnabled(true, localReady: true)
        #expect(!controller.busy)
        #expect(controller.status == "Verbindung zu OpenAI wird geprüft …")
        await controller.revoke()
        #expect(!controller.settings.enabled && !controller.ready && !controller.busy)
        #expect(controller.status == "ChatGPT-Verbindung ist aus.")
    }
    @Test func setupStoresOnlyIDInPreferencesAndWaitsForExplicitConnectionAndLocalGrant() async throws {
        let suite = "MikeMailHub.tunnel.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AssistantTunnelController(defaults: defaults, directory: URL(fileURLWithPath: "/tmp/unused-assistant-test"))
        let secret = TunnelSecrets(); controller.configure(credentials: secret)
        #expect(!controller.settings.enabled && !controller.ready)
        let id = "tunnel_0123456789abcdef0123456789abcdef", key = "sk-synthetic-secret-only-for-unit-test"
        #expect(await controller.saveConfiguration(tunnelID: id, key: key))
        #expect(await secret.stored == Data(key.utf8))
        let preference = try #require(defaults.data(forKey: "assistantTunnel.v1"))
        #expect(!String(decoding: preference, as: UTF8.self).contains(key))
        await controller.reconcile(localReady: true)
        #expect(await secret.reads == 0)
        await controller.setEnabled(true, localReady: false)
        #expect(await secret.reads == 0 && !controller.ready)
        await controller.revoke(); #expect(!controller.settings.enabled)
        await controller.forget(); #expect(await secret.stored == nil && controller.settings.tunnelID.isEmpty)
    }
    @Test func rejectsMalformedTunnelAndKeyWithoutSavingAnything() async throws {
        let controller = AssistantTunnelController(defaults: nil, directory: URL(fileURLWithPath: "/tmp/unused-assistant-test"))
        let secret = TunnelSecrets(); controller.configure(credentials: secret)
        #expect(AssistantTunnelController.validID("tunnel_ab12_0123456789abcdef0123456789abcdef"))
        for id in ["", "tunnel_a", "https://example.invalid", "tunnel_0123456789abcdef0123456789abcdef;exit", "tunnel_0123456789abcdef0123456789abcdef\n"] {
            #expect(!AssistantTunnelController.validID(id))
            #expect(await controller.saveConfiguration(tunnelID: id, key: "sk-synthetic-secret-only-for-unit-test") == false)
        }
        #expect(await controller.saveConfiguration(tunnelID: "tunnel_0123456789abcdef0123456789abcdef", key: "sk-secret\nOTHER=1") == false)
        #expect(await secret.stored == nil)
        #expect(await secret.reads == 0)
    }
}
