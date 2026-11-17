import Foundation
import Testing
import GRDB
import MailDomain
import MailApplication
import MailDemo
@testable import MailPersistence

struct DesktopNotificationStoreTests {
    @Test func changedUIDValiditySilencesReimportWithNewLocalIDs() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), original = data.snapshot.messages[0], now = Date()
        let account = original.accountID, folder = try #require(data.snapshot.folders.first { $0.accountID == account && $0.role == .inbox })
        var repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(data.snapshot); try await repo.close()
        func epoch(_ value: Int) async throws {
            let db = try DatabaseQueue(path: test.paths.database.path, configuration: IndexDatabase.configuration(key: test.key))
            try await db.write { try $0.execute(sql: "INSERT INTO sync_states(account_id,folder_id,uid_validity,last_success) VALUES(?,?,?,?) ON CONFLICT(account_id,folder_id) DO UPDATE SET uid_validity=excluded.uid_validity", arguments: [account.description, folder.id.description, value, now.timeIntervalSince1970]) }
            try db.close()
        }
        func incoming(_ validity: UInt32) throws -> MailSnapshot {
            let item = try MailMessage(id: MessageID(), accountID: account, locator: .imap(mailbox: folder.providerID, uidValidity: validity, uid: 9999),
                threadID: nil, folderIDs: [folder.id], subject: "Synthetic UID reset", sender: original.sender, recipients: [],
                receivedAt: now.addingTimeInterval(10), isUnread: true, isFlagged: false, preview: nil)
            return try MailSnapshot(accounts: data.snapshot.accounts, folders: data.snapshot.folders, threads: [], messages: [item])
        }
        try await epoch(1)
        repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        #expect(try await repo.consumeInboxNotifications(account: account, now: now) == nil)
        try await repo.upsert(incoming(1))
        #expect(try await repo.consumeInboxNotifications(account: account, now: now.addingTimeInterval(11))?.count == 1)
        try await repo.close(); try await epoch(2)
        repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.upsert(incoming(2))
        #expect(try await repo.consumeInboxNotifications(account: account, now: now.addingTimeInterval(12)) == nil)
        #expect(try await repo.consumeInboxNotifications(account: account, now: now.addingTimeInterval(13)) == nil)
        try await repo.close()
    }
    @Test func migrationKeepsMetadataAndDurableClaimsDoNotRepeatAfterRestart() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        try test.paths.prepare()
        let data = try SyntheticFixtures.make(), original = data.snapshot.messages[0], now = Date()
        let old = try DatabaseQueue(path: test.paths.database.path, configuration: IndexDatabase.configuration(key: test.key))
        try IndexSchema.migrator().migrate(old, upTo: "v9")
        try await old.write { try IndexWriter.upsert(data.snapshot, db: $0) }
        try old.close()
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        #expect(try await repo.summary().schemaVersion == 14)
        #expect(try await repo.consumeInboxNotifications(account: original.accountID, now: now) == nil)
        let incoming = try MailMessage(id: MessageID(), accountID: original.accountID,
            locator: .imap(mailbox: "INBOX", uidValidity: 1, uid: 90_001), threadID: nil, folderIDs: original.folderIDs,
            subject: "Synthetic new mail", sender: original.sender, recipients: [], receivedAt: now.addingTimeInterval(10),
            isUnread: true, isFlagged: false, preview: nil)
        try await repo.upsert(MailSnapshot(accounts: data.snapshot.accounts, folders: data.snapshot.folders, threads: [], messages: [incoming]))
        let delta = try await repo.consumeInboxNotifications(account: original.accountID, now: now.addingTimeInterval(11))
        #expect(delta?.count == 1 && delta?.newest.id == incoming.id)
        try await repo.close()
        let reopened = try EncryptedMailRepository(paths: test.paths, key: test.key)
        #expect(try await reopened.consumeInboxNotifications(account: original.accountID, now: now.addingTimeInterval(30)) == nil)
        #expect(try await reopened.summary().messageCount == data.snapshot.messages.count + 1)
        try await reopened.close()
    }
    @Test func removalAndRebuildResetOnlyAccountBoundNotificationState() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), id = data.snapshot.accounts[0].id
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(data.snapshot)
        _ = try await repo.consumeInboxNotifications(account: id)
        await #expect(throws: MailFailure.notFound) { try await repo.consumeInboxNotifications(account: AccountID()) }
        try await repo.replaceMetadata(with: data.snapshot)
        #expect(try await repo.consumeInboxNotifications(account: id) == nil)
        try await repo.markAccountForRemoval(id)
        await #expect(throws: MailFailure.notFound) { try await repo.consumeInboxNotifications(account: id) }
        try await repo.finishAccountRemoval(id)
        try await repo.close()
        let db = try DatabaseQueue(path: test.paths.database.path, configuration: IndexDatabase.configuration(key: test.key))
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM desktop_notification_state WHERE account_id=?", arguments: [id.description]) } == 0)
        try db.close()
    }
}
