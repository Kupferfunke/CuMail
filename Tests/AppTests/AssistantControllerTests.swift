import Foundation
import Testing
import MailApplication
import MailDemo
import MailDomain
import MailMCP
@testable import MikeMailHub

@MainActor @Suite(.serialized) struct AssistantControllerTests {
    @Test func actionGrantsPersistAcrossRestartAndOnlyRestrictionsInvalidateTheirAccount() throws {
        let data = try SyntheticFixtures.make()
        let first = data.snapshot.accounts[0].id, second = data.snapshot.accounts[1].id
        let firstFolders = data.snapshot.folders.filter { $0.accountID == first }
        var grant = AssistantGrant(); grant.enabled = true
        grant.accountIDs = [first, second]; grant.actionAccountIDs = [first, second]
        grant.folderIDs = Set(data.snapshot.folders.filter { $0.accountID == first || $0.accountID == second }.map(\.id))
        grant.reconcileActionAuthorizations(folders: data.snapshot.folders)
        let original = grant.actionAuthorizations
        grant = try JSONDecoder().decode(AssistantGrant.self, from: JSONEncoder().encode(grant))
        grant.reconcileActionAuthorizations(folders: data.snapshot.folders)
        #expect(grant.actionAuthorizations == original)
        grant.allowText = true; grant.replyAccountIDs = [first]
        grant.reconcileActionAuthorizations(folders: data.snapshot.folders)
        #expect(grant.actionAuthorizations == original)
        grant.folderIDs.remove(firstFolders[0].id)
        grant.reconcileActionAuthorizations(folders: data.snapshot.folders)
        #expect(grant.actionAuthorizations[first]?.generation != original[first]?.generation)
        #expect(grant.actionAuthorizations[second] == original[second])
        let restricted = grant.actionAuthorizations[first]?.generation
        grant.folderIDs.insert(firstFolders[0].id)
        grant.reconcileActionAuthorizations(folders: data.snapshot.folders)
        #expect(grant.actionAuthorizations[first]?.generation == restricted)
        grant.enabled = false; grant.reconcileActionAuthorizations(folders: data.snapshot.folders)
        #expect(grant.actionAuthorizations.isEmpty)
        grant.enabled = true; grant.reconcileActionAuthorizations(folders: data.snapshot.folders)
        #expect(grant.actionAuthorizations[second]?.generation != original[second]?.generation)
    }
    @Test func liveLabelRefreshRemovesDeletedGrantsPreservesRenamesAndShowsNewLabelsOff() async throws {
        let suite = "CuMail.labels.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = URL(fileURLWithPath: "/tmp/mmh-ui-\(UUID().uuidString)")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let data = try SyntheticFixtures.make(), repository = data.repository(), service = InboxService(repository: repository)
        let account = try #require(data.snapshot.accounts.first { $0.provider == .gmail })
        let original = data.snapshot.folders.filter { $0.accountID == account.id }
        let removed = try #require(original.first), kept = try #require(original.last)
        #expect(removed.id != kept.id)
        let controller = AssistantController(defaults: defaults, directory: directory)
        await controller.configure(service: service, accounts: data.snapshot.accounts, folders: data.snapshot.folders) { id, scope in try await repository.text(for: id, scope: scope) }
        await controller.setAccountFolders(account.id, allowed: true)
        await controller.setEnabled(true)
        let renamed = try MailFolder(id: kept.id, accountID: account.id, providerID: kept.providerID, name: "Umbenannt", role: kept.role)
        let added = try MailFolder(id: FolderID(), accountID: account.id, providerID: "Label_new", name: "Neu", role: .custom)
        let current = data.snapshot.folders.filter { $0.id != removed.id && $0.id != kept.id } + [renamed, added]
        await controller.refreshFolders(current)
        #expect(!controller.folders.contains { $0.id == removed.id })
        #expect(!controller.grant.folderIDs.contains(removed.id))
        #expect(controller.grant.folderIDs.contains(renamed.id))
        #expect(controller.folders.contains { $0.id == renamed.id && $0.name == "Umbenannt" })
        #expect(controller.folders.contains { $0.id == added.id })
        #expect(!controller.grant.folderIDs.contains(added.id))
        await controller.suspend()
        let restored = AssistantController(defaults: defaults, directory: directory)
        await restored.configure(service: service, accounts: data.snapshot.accounts, folders: current) { id, scope in try await repository.text(for: id, scope: scope) }
        #expect(restored.grant.folderIDs == controller.grant.folderIDs)
        await restored.revoke()
    }
    @Test func wholeAccountGrantPersistsAndRevokesWithoutIncludingNewFoldersOrOtherAccounts() async throws {
        let suite = "CuMail.assistant.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = URL(fileURLWithPath: "/tmp/mmh-ui-\(UUID().uuidString)")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let data = try SyntheticFixtures.make(), repository = data.repository(), service = InboxService(repository: repository)
        let first = try #require(data.snapshot.accounts.first { $0.provider == .imap })
        let second = try #require(data.snapshot.accounts.first { $0.provider == .gmail })
        let controller = AssistantController(defaults: defaults, directory: directory)
        await controller.configure(service: service, accounts: data.snapshot.accounts, folders: data.snapshot.folders) { id, scope in try await repository.text(for: id, scope: scope) }
        await controller.setAccountFolders(first.id, allowed: true)
        await controller.setAccountFolders(second.id, allowed: true)
        await controller.setReplies(first.id, allowed: true)
        await controller.setEnabled(true)
        #expect(controller.running)
        #expect(controller.grant.folderIDs == Set(data.snapshot.folders.filter { $0.accountID == first.id || $0.accountID == second.id }.map(\.id)))
        await controller.suspend()
        let added = try MailFolder(id: FolderID(), accountID: first.id, providerID: "new-private-folder", name: "Neu", role: .custom)
        let restored = AssistantController(defaults: defaults, directory: directory)
        await restored.configure(service: service, accounts: data.snapshot.accounts, folders: data.snapshot.folders + [added]) { id, scope in try await repository.text(for: id, scope: scope) }
        #expect(restored.running && restored.grant.accountIDs == [first.id, second.id])
        #expect(!restored.grant.folderIDs.contains(added.id))
        await restored.setAccountFolders(first.id, allowed: false)
        #expect(restored.running && restored.grant.accountIDs == [second.id])
        #expect(restored.grant.replyAccountIDs.isEmpty)
        #expect(restored.grant.folderIDs == Set(data.snapshot.folders.filter { $0.accountID == second.id }.map(\.id)))
        await restored.revoke()
    }
    @Test func consentDefaultsOffPersistsOnlySelectedFoldersAndRevokeClearsEverything() async throws {
        let suite = "MikeMailHub.assistant.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = URL(fileURLWithPath: "/tmp/mmh-ui-\(UUID().uuidString)")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let data = try SyntheticFixtures.make(), repository = data.repository(), service = InboxService(repository: repository)
        let controller = AssistantController(defaults: defaults, directory: directory)
        await controller.configure(service: service, accounts: data.snapshot.accounts, folders: data.snapshot.folders) { id, scope in try await repository.text(for: id, scope: scope) }
        #expect(!controller.grant.enabled && !controller.grant.allowText && controller.grant.folderIDs.isEmpty && !controller.running)
        await controller.setEnabled(true)
        #expect(!controller.running && !FileManager.default.fileExists(atPath: directory.path))
        let folder = data.snapshot.folders[0]; await controller.setFolder(folder, allowed: true)
        #expect(controller.running && controller.grant.folderIDs == [folder.id])
        await controller.suspend(); #expect(!controller.running && controller.grant.enabled)
        await controller.resume(); #expect(controller.running)
        await controller.setText(true)
        #expect(controller.running && controller.grant.allowText)
        await controller.setReplies(folder.accountID, allowed: true)
        #expect(controller.grant.replyAccountIDs == [folder.accountID])
        await controller.suspend()
        let restored = AssistantController(defaults: defaults, directory: directory)
        await restored.configure(service: service, accounts: data.snapshot.accounts, folders: data.snapshot.folders) { id, scope in try await repository.text(for: id, scope: scope) }
        #expect(restored.running && restored.grant.folderIDs == [folder.id])
        #expect(restored.grant.replyAccountIDs == [folder.accountID])
        await restored.revoke()
        #expect(!restored.running && !restored.grant.enabled && !restored.grant.allowText && restored.grant.accountIDs.isEmpty && restored.grant.folderIDs.isEmpty)
        #expect(!AssistantController(defaults: defaults, directory: directory).grant.enabled)
        #expect(restored.grant.replyAccountIDs.isEmpty)
    }
    @Test func deletedFolderRevokesMembershipAndConcurrentRevokeWins() async throws {
        let directory = URL(fileURLWithPath: "/tmp/mmh-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try SyntheticFixtures.make(), repository = data.repository(), service = InboxService(repository: repository)
        let controller = AssistantController(defaults: nil, directory: directory)
        let folder = data.snapshot.folders[0]
        await controller.configure(service: service, accounts: data.snapshot.accounts, folders: data.snapshot.folders) { id, scope in try await repository.text(for: id, scope: scope) }
        await controller.setFolder(folder, allowed: true); await controller.setEnabled(true)
        await controller.configure(service: service, accounts: data.snapshot.accounts, folders: data.snapshot.folders.filter { $0.id != folder.id }) { id, scope in try await repository.text(for: id, scope: scope) }
        #expect(!controller.running && controller.grant.folderIDs.isEmpty)
        await controller.configure(service: service, accounts: data.snapshot.accounts, folders: data.snapshot.folders) { id, scope in try await repository.text(for: id, scope: scope) }
        let enabling = Task { await controller.setFolder(folder, allowed: true) }
        await Task.yield(); await controller.revoke(); await enabling.value
        #expect(!controller.running && !controller.grant.enabled && controller.grant.folderIDs.isEmpty)
        await controller.revoke()
    }
}
