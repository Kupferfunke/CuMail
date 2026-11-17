import Foundation
import Testing
import GRDB
import MailDomain
import MailApplication
import MailDemo
import MailSecurity
@testable import MailPersistence

struct ReleaseStorageTests {
    private func preferences() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["appearance": "Hell", "assistantGrant.v1": Data("synthetic-grants".utf8),
                                                              "assistantTunnel.v1": Data("synthetic-tunnel-settings".utf8)], format: .binary, options: 0)
    }
    @Test func encryptedBackupRestoresWALDraftsSignaturesOrderAndPreferences() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), account = data.snapshot.accounts[0]
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(data.snapshot)
        let signature = NamedMailSignature(name: "Formal", content: try MailSignature(html: "<p>Synthetic signature</p>"))
        let library = SignatureLibrary(entries: [signature], defaultID: signature.id)
        try await repo.saveSignatureLibrary(library, account: account.id)
        let order = Array(data.snapshot.folders.filter { $0.accountID == account.id }.map(\.id).reversed())
        try await repo.saveFolderOrder(order, account: account.id)
        var draft = LocalDraft(accountID: account.id, sender: account.address.value)
        draft.body = "Unsaved on server, preserved in WAL"; draft.signature = signature.content; draft.signatureID = signature.id; draft.signatureName = signature.name
        draft.attachments = [DraftAttachment(filename: "synthetic.txt", mimeType: "text/plain", byteCount: 12,
                                             bookmark: Data("synthetic-bookmark".utf8), digest: String(repeating: "a", count: 64))]
        let saved = try await repo.saveDraft(draft, expectedRevision: 0)
        let prefs = try preferences()
        let backup = try await repo.recoveryBackup(key: test.key, preferences: prefs)
        #expect(backup.accountCount == 3 && backup.messageCount == data.snapshot.messages.count)
        #expect(backup.signatureCount == 1 && backup.draftCount == 1)
        #expect(!(try Data(contentsOf: backup.url.appendingPathComponent("mail-index.sqlite"))).starts(with: Data("SQLite format 3".utf8)))
        #expect(!(try Data(contentsOf: backup.url.appendingPathComponent("manifest.aesgcm"))).contains(Data("synthetic-grants".utf8)))
        let restoredPaths = WorkspacePaths(root: test.directory.appendingPathComponent("Restored"), cache: test.directory.appendingPathComponent("RestoredCache"))
        let restoredPrefs = try LocalBackupRestore.restore(backup.url, to: restoredPaths, key: test.key)
        #expect(restoredPrefs == prefs)
        let restored = try EncryptedMailRepository(paths: restoredPaths, key: test.key)
        #expect(try await restored.signatureLibrary(account: account.id) == library)
        #expect(try await restored.folderOrder(account: account.id) == order)
        #expect(try await restored.draft(id: saved.id, account: account.id) == saved)
        let originalRows = try await repo.messages(filter: MessageFilter(), page: PageRequest(), in: data.scope).items
        let restoredRows = try await restored.messages(filter: MessageFilter(), page: PageRequest(), in: data.scope).items
        #expect(originalRows == restoredRows)
        #expect(throws: LocalStoreFailure.conflictingDataLocations) { try LocalBackupRestore.restore(backup.url, to: restoredPaths, key: test.key) }
        try await restored.close(); try await repo.close()
    }
    @Test func migrationMovesVerifiedWorkspaceAndCacheAndSurvivesRestart() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), secrets = SyntheticSecrets()
        let old = try await LocalMailWorkspace.open(paths: test.paths, credentials: secrets, syntheticSnapshot: data.snapshot)
        let reference = CredentialReference(accountID: data.snapshot.accounts[0].id, purpose: .incomingPassword)
        await secrets.save(Data("retained-synthetic-secret".utf8), for: reference)
        let sourceKey = try await secrets.databaseKey(createIfMissing: false)
        try await old.close()
        let originalFile = try Data(contentsOf: test.paths.database)
        let target = WorkspacePaths(root: test.directory.appendingPathComponent("CuMail"), cache: test.directory.appendingPathComponent("CuMailCache"),
                                    legacyRoot: test.paths.root, legacyCache: test.paths.cache)
        let prefs = try preferences()
        var migrated = try await LocalMailWorkspace.open(paths: target, credentials: secrets, syntheticSnapshot: data.snapshot, preferences: prefs)
        #expect(!FileManager.default.fileExists(atPath: test.paths.root.path))
        #expect(!FileManager.default.fileExists(atPath: test.paths.cache.path))
        #expect(try await migrated.summary().messageCount == data.snapshot.messages.count)
        #expect(try await secrets.databaseKey(createIfMissing: false) == sourceKey)
        #expect(await secrets.read(reference) == Data("retained-synthetic-secret".utf8))
        let copies = try await migrated.recoveryBackups()
        #expect(copies.count == 1)
        #expect(try RecoveryBackup.verify(copies[0].url, key: sourceKey).preferences == prefs)
        #expect(!originalFile.isEmpty)
        #expect(try target.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == false)
        #expect(try target.recoveryBackups.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == false)
        #expect(try target.cache.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try await migrated.close()
        migrated = try await LocalMailWorkspace.open(paths: target, credentials: secrets, syntheticSnapshot: data.snapshot)
        #expect(try await migrated.recoveryBackups().count == 1)
        #expect(try await migrated.summary().accountCount == 3)
        try await migrated.close()
    }
    @Test func conflictAndMissingKeyNeverReplaceExistingData() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), secrets = SyntheticSecrets()
        let old = try await LocalMailWorkspace.open(paths: test.paths, credentials: secrets, syntheticSnapshot: data.snapshot)
        try await old.close()
        let target = WorkspacePaths(root: test.directory.appendingPathComponent("CuMail"), cache: test.directory.appendingPathComponent("CuMailCache"), legacyRoot: test.paths.root)
        try FileManager.default.createDirectory(at: target.root, withIntermediateDirectories: true)
        let sentinel = target.root.appendingPathComponent("existing-data")
        try Data("untouched".utf8).write(to: sentinel)
        await #expect(throws: LocalStoreFailure.conflictingDataLocations) {
            try await LocalMailWorkspace.open(paths: target, credentials: secrets, syntheticSnapshot: data.snapshot)
        }
        #expect(try Data(contentsOf: sentinel) == Data("untouched".utf8))
        try FileManager.default.removeItem(at: target.root)
        await secrets.deleteDatabaseKey()
        await #expect(throws: KeychainFailure.missingDatabaseKey) {
            try await LocalMailWorkspace.open(paths: target, credentials: secrets, syntheticSnapshot: data.snapshot)
        }
        #expect(FileManager.default.fileExists(atPath: test.paths.database.path))
        #expect(!FileManager.default.fileExists(atPath: target.root.path))
    }
    @Test func tamperedOrWrongKeyBackupCannotBeRestored() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(SyntheticFixtures.make().snapshot)
        let backup = try await repo.recoveryBackup(key: test.key, preferences: preferences())
        #expect(throws: LocalStoreFailure.invalidBackup) { try RecoveryBackup.verify(backup.url, key: Data(repeating: 1, count: 32)) }
        let file = backup.url.appendingPathComponent("mail-index.sqlite")
        let handle = try FileHandle(forUpdating: file); try handle.seek(toOffset: 128); try handle.write(contentsOf: Data(repeating: 0xFF, count: 32)); try handle.close()
        let restored = WorkspacePaths(root: test.directory.appendingPathComponent("Restore"), cache: test.directory.appendingPathComponent("RestoreCache"))
        #expect(throws: LocalStoreFailure.invalidBackup) { try LocalBackupRestore.restore(backup.url, to: restored, key: test.key) }
        #expect(!FileManager.default.fileExists(atPath: restored.root.path))
        #expect(try await repo.summary().messageCount == 10)
        try await repo.close()
    }
    @Test func failedMigrationBackupLeavesSourceAndRetriesSafely() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), secrets = SyntheticSecrets()
        let old = try await LocalMailWorkspace.open(paths: test.paths, credentials: secrets, syntheticSnapshot: data.snapshot)
        try await old.close()
        try FileManager.default.removeItem(at: test.paths.recoveryBackups)
        try Data("blocking-file".utf8).write(to: test.paths.recoveryBackups)
        let target = WorkspacePaths(root: test.directory.appendingPathComponent("CuMail"), cache: test.directory.appendingPathComponent("CuMailCache"), legacyRoot: test.paths.root)
        await #expect(throws: LocalStoreFailure.invalidInput) {
            try await LocalMailWorkspace.open(paths: target, credentials: secrets, syntheticSnapshot: data.snapshot)
        }
        #expect(FileManager.default.fileExists(atPath: test.paths.database.path))
        #expect(!FileManager.default.fileExists(atPath: target.root.path))
        try FileManager.default.removeItem(at: test.paths.recoveryBackups)
        let retried = try await LocalMailWorkspace.open(paths: target, credentials: secrets, syntheticSnapshot: data.snapshot)
        #expect(try await retried.summary().messageCount == 10)
        try await retried.close()
    }
    @Test func recoveryRetentionPreservesDailyCopiesAndBothNewest() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(SyntheticFixtures.make().snapshot)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for day in (0..<9).reversed() {
            _ = try await repo.recoveryBackup(key: test.key, preferences: preferences(), now: now.addingTimeInterval(-Double(day) * 86400))
        }
        _ = try await repo.recoveryBackup(key: test.key, preferences: preferences(), now: now.addingTimeInterval(60))
        let kept = try RecoveryBackup.list(in: test.paths.recoveryBackups, key: test.key)
        #expect(kept.count == 8)
        #expect(kept[0].createdAt == now.addingTimeInterval(60) && kept[1].createdAt == now)
        #expect(kept.last?.createdAt == now.addingTimeInterval(-6 * 86400))
        try await repo.close()
    }
    @Test func routineMaintenancePreservesRecoveryAndExplicitClearRemovesIt() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), secrets = SyntheticSecrets()
        let work = try await LocalMailWorkspace.open(paths: test.paths, credentials: secrets, syntheticSnapshot: data.snapshot)
        let backup = try await work.createRecoveryBackup(preferences: preferences())
        try await work.rebuildIndex()
        #expect(FileManager.default.fileExists(atPath: backup.url.path))
        #expect(try await work.verifyRecoveryBackup(backup).messageCount == 10)
        try await work.clearLocalData()
        #expect(!FileManager.default.fileExists(atPath: backup.url.path))
        #expect(try await work.recoveryBackups().isEmpty)
        #expect(try await work.summary().accountCount == 0)
        try await work.close()
    }
}
