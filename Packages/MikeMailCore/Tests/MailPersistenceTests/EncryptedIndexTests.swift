import Foundation
import Testing
import GRDB
import MailDomain
import MailApplication
import MailDemo
@testable import MailPersistence

struct TestWorkspace {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MikeMailHubTests-\(UUID())", isDirectory: true)
    var paths: WorkspacePaths { WorkspacePaths(root: directory.appendingPathComponent("Index"), cache: directory.appendingPathComponent("Cache")) }
    let key = Data(repeating: 0xA7, count: 32) // Public synthetic test material only.
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

struct EncryptedIndexTests {
    @Test func phaseThreeMigrationPreservesProfilesAndUIDsAndRequiresWriteOptIn() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        try test.paths.prepare()
        let data = try SyntheticFixtures.make(), account = data.snapshot.accounts[0]
        let message = data.snapshot.messages[0], folder = try #require(message.folderIDs.first)
        let old = try DatabaseQueue(path: test.paths.database.path, configuration: IndexDatabase.configuration(key: test.key))
        try IndexSchema.migrator().migrate(old, upTo: "v3")
        try await old.write { db in
            try IndexWriter.upsert(data.snapshot, db: db, includeReadingMetadata: false)
            try db.execute(sql: "UPDATE accounts SET status='connected' WHERE id=?", arguments: [account.id.description])
            try db.execute(sql: "INSERT INTO imap_profiles VALUES(?, 'mail.example.invalid', 993, 'implicitTLS', 'reader@example.invalid')", arguments: [account.id.description])
            try db.execute(sql: "UPDATE account_settings SET text_index_enabled=1 WHERE account_id=?", arguments: [account.id.description])
            try db.execute(sql: "INSERT INTO sync_states(account_id,folder_id,uid_validity,server_count,indexed_count) VALUES(?,?,1,3,3)", arguments: [account.id.description, folder.description])
        }
        try old.close()
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        #expect(try await repo.summary().schemaVersion == 14)
        #expect(try await repo.summary().messageCount == 10)
        #expect(try await repo.imapConfigurations().first?.username == "reader@example.invalid")
        let settings = try await repo.settings(for: account.id)
        #expect(settings.textIndexEnabled && !settings.serverActionsEnabled)
        let restored = try await repo.message(id: message.id, in: data.scope)
        #expect(restored.locator == message.locator)
        #expect(!restored.threadingHeadersLoaded && restored.references.isEmpty)
        let checkpoint = try #require(try await repo.imapCheckpoint(account: account.id, folder: folder))
        #expect(checkpoint.uidValidity == 1 && checkpoint.knownUIDs.isEmpty)
        #expect(try await repo.pendingMailActions(account: account.id).isEmpty)
        try await repo.close()
        let backups = try FileManager.default.contentsOfDirectory(at: test.paths.backups, includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        let backup = try DatabaseQueue(path: backups[0].path, configuration: IndexDatabase.configuration(key: test.key, readonly: true))
        #expect(try await backup.read { try IndexSchema.verify($0) } == 3)
        try backup.close()
    }
    @Test func phaseTwoMigrationPreservesPhaseOneDataPreferencesAndBackup() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        try test.paths.prepare()
        let data = try SyntheticFixtures.make()
        let old = try DatabaseQueue(path: test.paths.database.path, configuration: IndexDatabase.configuration(key: test.key))
        try IndexSchema.migrator().migrate(old, upTo: "v2")
        try await old.write { db in
            try IndexWriter.upsert(data.snapshot, db: db, includeReadingMetadata: false)
            try db.execute(sql: "UPDATE accounts SET name='Preserved preference' WHERE id=?", arguments: [data.snapshot.accounts[0].id.description])
        }
        try old.close()
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        #expect(try await repo.summary().schemaVersion == 14)
        #expect(try await repo.summary().messageCount == 10)
        #expect(try await repo.settings(for: data.snapshot.accounts[0].id).displayName == "Preserved preference")
        #expect(try await repo.imapConfigurations().isEmpty)
        try await repo.close()
        let backups = try FileManager.default.contentsOfDirectory(at: test.paths.backups, includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        let backup = try DatabaseQueue(path: backups[0].path, configuration: IndexDatabase.configuration(key: test.key, readonly: true))
        #expect(try await backup.read { try IndexSchema.verify($0) } == 2)
        #expect(try await backup.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM messages") } == 10)
        try backup.close()
    }
    @Test func databaseSidecarsCannotRedirectWritesOutsideThePrivateDirectory() throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        try test.paths.prepare()
        let external = test.directory.appendingPathComponent("not-owned.txt")
        try Data("untouched".utf8).write(to: external)
        let link = URL(fileURLWithPath: test.paths.database.path + "-wal")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        #expect(throws: LocalStoreFailure.invalidInput) { try EncryptedMailRepository(paths: test.paths, key: test.key) }
        #expect(try String(contentsOf: external, encoding: .utf8) == "untouched")
        try FileManager.default.removeItem(at: external) // Also reject a dangling sidecar link.
        #expect(throws: LocalStoreFailure.invalidInput) { try EncryptedMailRepository(paths: test.paths, key: test.key) }
        #expect(!FileManager.default.fileExists(atPath: external.path))
    }
    @Test func encryptedMetadataSurvivesRestartAndRejectsWrongOrMissingKeys() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make()
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(data.snapshot)
        #expect(try await repo.summary().messageCount == 10)
        let wal = try Data(contentsOf: URL(fileURLWithPath: test.paths.database.path + "-wal"))
        #expect(wal.count > 32)
        #expect(wal.range(of: Data(data.snapshot.messages[0].subject.utf8)) == nil)
        #expect(wal.range(of: Data(data.snapshot.accounts[0].address.value.utf8)) == nil)
        try await repo.close()
        let bytes = try Data(contentsOf: test.paths.database)
        #expect(!bytes.starts(with: Data("SQLite format 3".utf8)))
        #expect(bytes.range(of: Data(data.snapshot.messages[0].subject.utf8)) == nil)
        #expect(throws: LocalStoreFailure.wrongKeyOrCorrupt) {
            _ = try EncryptedMailRepository(paths: test.paths, key: Data(repeating: 0xB8, count: 32))
        }
        let reopened = try EncryptedMailRepository(paths: test.paths, key: test.key)
        let page = try await reopened.messages(filter: MessageFilter(), page: PageRequest(), in: data.scope)
        #expect(page.items.map(\.id) == data.snapshot.messages.map(\.id))
        #expect(page.items.allSatisfy { $0.preview == nil })
        #expect(page.coverage.metadataOnly)
        try await reopened.close()
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = ["-readonly", test.paths.database.path, "SELECT count(*) FROM sqlite_master;"]
        sqlite.standardError = Pipe(); sqlite.standardOutput = Pipe()
        try sqlite.run(); sqlite.waitUntilExit()
        #expect(sqlite.terminationStatus != 0)
        #expect(try Data(contentsOf: test.paths.database) == bytes)
    }

    @Test func accountAndFolderScopesApplyToSearchIDsAndThreads() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), message = data.snapshot.messages[0]
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.upsert(data.snapshot)
        let other = AccessScope(accountIDs: [data.snapshot.accounts[1].id])
        await #expect(throws: MailFailure.notFound) { try await repo.message(id: message.id, in: other) }
        await #expect(throws: MailFailure.notFound) { try await repo.thread(id: message.threadID!, page: PageRequest(), in: other) }
        #expect(try await repo.messages(filter: MessageFilter(), page: PageRequest(), in: other).items.allSatisfy { $0.accountID == data.snapshot.accounts[1].id })
        for scope in [AccessScope(accountIDs: []), AccessScope(accountIDs: data.scope.accountIDs, folderIDs: [])] {
            #expect(try await repo.messages(filter: MessageFilter(), page: PageRequest(), in: scope).items.isEmpty)
            await #expect(throws: MailFailure.notFound) { try await repo.message(id: message.id, in: scope) }
        }
        let wrongFolder = AccessScope(accountIDs: [message.accountID], folderIDs: [data.snapshot.folders.first { $0.accountID != message.accountID }!.id])
        #expect(try await repo.messages(filter: MessageFilter(), page: PageRequest(), in: wrongFolder).items.isEmpty)
        try await repo.close()
    }

    @Test func ftsSearchIsParameterizedAndExcludesUnapprovedText() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make()
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.upsert(data.snapshot)
        for (text, expected) in [("ruckmeldungen",1),("Materialstudie.pdf",1),("Material",2),("Grammatur",0),("Donnerstag",0),("*",0)] {
            var query = MessageFilter(); query.text = text
            let matches = try await repo.messages(filter: query, page: PageRequest(), in: data.scope)
            #expect(matches.items.count == expected, "Query: \(text)")
        }
        #expect(try await repo.summary().messageCount == 10)
        try await repo.close()
    }

    @Test func keysetPaginationIsBoundToItsAccountAndFilter() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make()
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.upsert(data.snapshot)
        var ids: [MessageID] = []; var cursor: String?
        repeat {
            let page = try await repo.messages(filter: MessageFilter(), page: PageRequest(limit: 3, cursor: cursor), in: data.scope)
            ids += page.items.map(\.id); cursor = page.nextCursor
        } while cursor != nil
        #expect(ids == data.snapshot.messages.map(\.id))
        let first = try await repo.messages(filter: MessageFilter(), page: PageRequest(limit: 2), in: data.scope)
        await #expect(throws: MailFailure.invalidInput) {
            try await repo.messages(filter: MessageFilter(), page: PageRequest(cursor: first.nextCursor), in: AccessScope(accountIDs: [data.snapshot.accounts[0].id]))
        }
        var changed = MessageFilter(); changed.unreadOnly = true
        await #expect(throws: MailFailure.invalidInput) { try await repo.messages(filter: changed, page: PageRequest(cursor: first.nextCursor), in: data.scope) }
        try await repo.close()
    }

    @Test func migrationPreservesDataAndCreatesEncryptedBackup() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        try test.paths.prepare()
        let old = try DatabaseQueue(path: test.paths.database.path, configuration: IndexDatabase.configuration(key: test.key))
        try IndexSchema.migrator().migrate(old, upTo: "v1")
        let account = try SyntheticFixtures.make().snapshot.accounts[0]
        try await old.write {
            try $0.execute(sql: "INSERT INTO accounts(id,provider,name,address,status) VALUES(?,?,?,?,?)",
                           arguments: [account.id.description, account.provider.rawValue, account.name, account.address.value, account.status.rawValue])
        }
        try old.close()
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        #expect(try await repo.settings(for: account.id).displayName == account.name)
        #expect(try await repo.summary().schemaVersion == 14)
        try await repo.close()
        let backups = try FileManager.default.contentsOfDirectory(at: test.paths.backups, includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        let backup = try DatabaseQueue(path: backups[0].path, configuration: IndexDatabase.configuration(key: test.key, readonly: true))
        #expect(try await backup.read { try IndexSchema.verify($0) } == 1)
        #expect(try await backup.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM accounts") } == 1)
        try backup.close()
        #expect(!(try Data(contentsOf: backups[0])).starts(with: Data("SQLite format 3".utf8)))
    }

    @Test func failedMigrationRollsBackWithoutDeletingTheOldIndex() throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        try test.paths.prepare()
        let old = try DatabaseQueue(path: test.paths.database.path, configuration: IndexDatabase.configuration(key: test.key))
        try IndexSchema.migrator().migrate(old, upTo: "v1")
        try old.write { try $0.execute(sql: "INSERT INTO app_state VALUES('keep','migration-sentinel'); CREATE TABLE search_content(conflict TEXT);") }
        try old.close()
        #expect(throws: LocalStoreFailure.unavailable) { _ = try EncryptedMailRepository(paths: test.paths, key: test.key) }
        let check = try DatabaseQueue(path: test.paths.database.path, configuration: IndexDatabase.configuration(key: test.key))
        #expect(try check.read { try IndexSchema.verify($0) } == 1)
        #expect(try check.read { try String.fetchOne($0, sql: "SELECT value FROM app_state WHERE key='keep'") } == "migration-sentinel")
        #expect(try check.read { try $0.tableExists("account_settings") } == false)
        try check.close()
    }

    @Test func databaseForeignKeysRejectCrossAccountRelations() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make()
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.upsert(data.snapshot)
        let db = try DatabaseQueue(path: test.paths.database.path, configuration: IndexDatabase.configuration(key: test.key))
        let message = data.snapshot.messages[0]
        let otherFolder = data.snapshot.folders.first { $0.accountID != message.accountID }!
        await #expect(throws: DatabaseError.self) {
            try await db.write { try $0.execute(sql: "INSERT INTO message_locations(message_id,account_id,folder_id) VALUES(?,?,?)",
                                         arguments: [message.id.description,message.accountID.description,otherFolder.id.description]) }
        }
        #expect(try await repo.message(id: message.id, in: data.scope).folderIDs == message.folderIDs)
        try db.close()
        try await repo.close()
    }

    @Test func optInTextBudgetsAndOptOutRemoveFtsMatches() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), message = data.snapshot.messages[0]
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.upsert(data.snapshot)
        await #expect(throws: LocalStoreFailure.textIndexDisabled) { try await repo.storeExtract("EinzigartigerSuchbeleg", for: message.id, account: message.accountID) }
        var settings = try await repo.settings(for: message.accountID)
        settings.textIndexEnabled = true; settings.messageTextLimit = 25; settings.accountTextBudget = 30
        try await repo.saveSettings(settings)
        try await repo.storeExtract("EinzigartigerSuchbeleg 🦊🦊🦊", for: message.id, account: message.accountID)
        let text = try #require(try await repo.extractedText(for: message.id, account: message.accountID))
        #expect(text.utf8.count <= 25); #expect(!text.contains("\u{FFFD}"))
        var search = MessageFilter(); search.text = "EinzigartigerSuchbeleg"
        #expect(try await repo.messages(filter: search, page: PageRequest(), in: data.scope).items.map(\.id) == [message.id])
        let other = data.snapshot.messages.first { $0.accountID == message.accountID && $0.id != message.id }!
        await #expect(throws: LocalStoreFailure.budgetExceeded) { try await repo.storeExtract("Budgetueberschreitung", for: other.id, account: other.accountID) }
        settings.textIndexEnabled = false
        try await repo.saveSettings(settings)
        #expect(try await repo.summary().indexedTextCount == 0)
        #expect(try await repo.messages(filter: search, page: PageRequest(), in: data.scope).items.isEmpty)
        try await repo.close()
    }

    @Test func providerBatchAndSyncCursorCommitTogetherOrRollBack() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), original = data.snapshot.messages[0]
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        let checkpoint = try LocalSyncCheckpoint(accountID: original.accountID, folderID: original.folderIDs.first!,
                                                cursor: "synthetic-before", updatedAt: Date())
        try await repo.upsert(data.snapshot, checkpoint: checkpoint)
        func copy(id: MessageID, subject: String) throws -> MailMessage {
            try MailMessage(id: id, accountID: original.accountID, locator: original.locator,
                threadID: original.threadID, folderIDs: original.folderIDs, subject: subject, sender: original.sender,
                recipients: original.recipients, receivedAt: original.receivedAt,
                isUnread: true, isFlagged: false, preview: nil)
        }
        let changed = try copy(id: original.id, subject: "Must roll back")
        let duplicate = try copy(id: MessageID(), subject: "Duplicate provider identity")
        let batch = try MailSnapshot(accounts: data.snapshot.accounts, folders: data.snapshot.folders,
                                     threads: data.snapshot.threads, messages: [changed, duplicate])
        let after = try LocalSyncCheckpoint(accountID: original.accountID, folderID: original.folderIDs.first!,
                                           cursor: "synthetic-after", updatedAt: Date())
        await #expect(throws: LocalStoreFailure.invalidInput) { try await repo.upsert(batch, checkpoint: after) }
        #expect(try await repo.message(id: original.id, in: data.scope).subject == original.subject)
        #expect(try await repo.syncCursor(account: original.accountID, folder: original.folderIDs.first!) == "synthetic-before")
        #expect(try await repo.summary().messageCount == 10)
        try await repo.close()
    }

    @Test func optOutPurgesOldEncryptedBackupsAndCheckpointsTheWAL() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), message = data.snapshot.messages[0]
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.upsert(data.snapshot)
        var prefs = try await repo.settings(for: message.accountID)
        prefs.textIndexEnabled = true; try await repo.saveSettings(prefs)
        try await repo.storeExtract("MustDisappearAfterOptOut", for: message.id, account: message.accountID)
        let reader = try DatabaseQueue(path: test.paths.database.path, configuration: IndexDatabase.configuration(key: test.key))
        try IndexDatabase.backup(reader, paths: test.paths, key: test.key)
        #expect(try FileManager.default.contentsOfDirectory(at: test.paths.backups, includingPropertiesForKeys: nil).count == 1)
        try reader.close()
        prefs.textIndexEnabled = false; try await repo.saveSettings(prefs)
        #expect(try FileManager.default.contentsOfDirectory(at: test.paths.backups, includingPropertiesForKeys: nil).isEmpty)
        #expect(PrivateFiles.size(URL(fileURLWithPath: test.paths.database.path + "-wal")) == 0)
        #expect(try await repo.extractedText(for: message.id, account: message.accountID) == nil)
        let inspect = try DatabaseQueue(path: test.paths.database.path, configuration: IndexDatabase.configuration(key: test.key, readonly: true))
        let columns = try await inspect.read { try $0.columns(in: "messages").map(\.name) }
        #expect(Set(columns).isDisjoint(with: ["password", "token", "body", "html", "mime", "preview"]))
        #expect(try await inspect.read { try Int.fetchOne($0, sql: "SELECT v FROM search_index_config WHERE k='secure-delete'") } == 1)
        print("SQLCipher runtime: \(try await repo.summary().cipherVersion)")
        try inspect.close(); try await repo.close()
    }
}
