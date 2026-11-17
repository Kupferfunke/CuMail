import Foundation
import Testing
import MailDomain
import MailApplication
import MailSecurity
import MailDemo
@testable import MailPersistence

actor SyntheticSecrets: CredentialStore, DatabaseKeyStore {
    private var key: Data?
    private var items: [CredentialReference: Data] = [:]
    private var denyDeletion = false
    func read(_ reference: CredentialReference) -> Data? { items[reference] }
    func save(_ secret: Data, for reference: CredentialReference) { items[reference] = secret }
    func delete(_ reference: CredentialReference) throws {
        if denyDeletion { throw KeychainFailure.lockedOrInteractionRequired }
        items.removeValue(forKey: reference)
    }
    func databaseKey(createIfMissing: Bool) throws -> Data {
        if let key { return key }
        guard createIfMissing else { throw KeychainFailure.missingDatabaseKey }
        let value = Data(repeating: 0xD4, count: 32); key = value; return value
    }
    func deleteDatabaseKey() { key = nil }
    func setDeletionDenied(_ value: Bool) { denyDeletion = value }
}

struct LifecycleTests {
    @Test func realIMAPProfileCheckpointRebuildAndRemovalRemainAccountScoped() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let demo = try SyntheticFixtures.make(), secrets = SyntheticSecrets()
        var work = try await LocalMailWorkspace.open(paths: test.paths, credentials: secrets, syntheticSnapshot: demo.snapshot)
        let a = MailAccount(id: try AccountID(), name: "Synthetic IMAP A", address: try EmailAddress("a@example.invalid"), provider: .imap, status: .connected)
        let b = MailAccount(id: try AccountID(), name: "Synthetic IMAP B", address: try EmailAddress("b@example.invalid"), provider: .imap, status: .connected)
        for account in [a,b] {
            let config = try IMAPConfiguration(accountID: account.id, host: "mail.example.invalid", port: 993, security: .implicitTLS, username: account.address.value)
            let folder = try MailFolder(id: IMAPIdentity.folder(account: account.id, mailbox: "INBOX"), accountID: account.id, providerID: "INBOX", name: "Posteingang", role: .inbox)
            try await work.repository.addIMAPAccount(account, configuration: config, folders: [folder])
            await secrets.save(Data("synthetic-secret".utf8), for: CredentialReference(accountID: account.id, purpose: .incomingPassword))
            let message = try MailMessage(id: IMAPIdentity.message(account: account.id, mailbox: "INBOX", validity: 7, uid: 42),
                accountID: account.id, locator: .imap(mailbox: "INBOX", uidValidity: 7, uid: 42), threadID: nil, folderIDs: [folder.id],
                subject: account.name, sender: MailPerson(name: "Synthetic Sender", address: EmailAddress("sender@example.invalid")),
                recipients: [], receivedAt: Date(), isUnread: true, isFlagged: false, preview: nil)
            let batch = try IMAPFolderBatch(uidValidity: 7, totalOnServer: 1, flags: [IMAPFlags(uid: 42, unread: true, flagged: false)], newMessages: [message])
            try await work.repository.applyIMAPBatch(batch, account: account, folder: folder)
        }
        try await work.close()
        work = try await LocalMailWorkspace.open(paths: test.paths, credentials: secrets, syntheticSnapshot: demo.snapshot)
        #expect(try await work.repository.imapConfigurations().count == 2)
        #expect(try await work.repository.imapSummaries().count == 2)
        let scoped = try await work.repository.messages(filter: MessageFilter(), page: PageRequest(), in: AccessScope(accountIDs: [a.id]))
        #expect(scoped.items.count == 1 && scoped.items[0].accountID == a.id)
        try await work.removeAccount(a.id)
        #expect(try await work.repository.imapConfigurations().map(\.accountID) == [b.id])
        #expect(await secrets.read(CredentialReference(accountID: a.id, purpose: .incomingPassword)) == nil)
        #expect(await secrets.read(CredentialReference(accountID: b.id, purpose: .incomingPassword)) != nil)
        #expect(try await work.summary().messageCount == 11)
        try await work.rebuildIndex()
        #expect(try await work.summary().messageCount == 10)
        #expect(try await work.repository.imapConfigurations().map(\.accountID) == [b.id])
        #expect(try await work.repository.folders(in: AccessScope(accountIDs: [b.id])).count == 1)
        #expect(try await work.repository.imapSummaries().isEmpty)
        #expect(await secrets.read(CredentialReference(accountID: b.id, purpose: .incomingPassword)) != nil)
        try await work.clearLocalData()
        #expect(try await work.repository.imapConfigurations().isEmpty)
        #expect(await secrets.read(CredentialReference(accountID: b.id, purpose: .incomingPassword)) == nil)
        try await work.close()
    }
    @Test func settingsRebuildDeletionAndClearSurviveRestart() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), secrets = SyntheticSecrets()
        let first = data.snapshot.accounts[0], second = data.snapshot.accounts[1], message = data.snapshot.messages[0]
        let a = CredentialReference(accountID: first.id, purpose: .incomingPassword)
        let b = CredentialReference(accountID: second.id, purpose: .oauthRefreshToken)
        await secrets.save(Data("synthetic-a".utf8), for: a); await secrets.save(Data("synthetic-b".utf8), for: b)
        var work = try await LocalMailWorkspace.open(paths: test.paths, credentials: secrets, syntheticSnapshot: data.snapshot)
        var prefs = try await work.settings(for: first.id)
        prefs.displayName = "Mein Testatelier"; prefs.textIndexEnabled = true
        try await work.saveSettings(prefs)
        try await work.storeExtract("RebuildTestwort", for: message.id, account: first.id)
        try await work.close()
        work = try await LocalMailWorkspace.open(paths: test.paths, credentials: secrets, syntheticSnapshot: data.snapshot)
        #expect(try await work.settings(for: first.id) == prefs)
        #expect(try await work.summary().indexedTextCount == 1)
        try await work.rebuildIndex()
        #expect(try await work.settings(for: first.id) == prefs)
        #expect(try await work.summary().indexedTextCount == 0)
        #expect(await secrets.read(a) != nil)
        let lease = try await work.temporaryFiles.create(Data("temporary".utf8), account: first.id)
        try await work.removeAccount(first.id)
        #expect(!FileManager.default.fileExists(atPath: lease.url.path))
        #expect(await secrets.read(a) == nil); #expect(await secrets.read(b) != nil)
        #expect(try await work.summary().accountCount == 2)
        try await work.close()
        work = try await LocalMailWorkspace.open(paths: test.paths, credentials: secrets, syntheticSnapshot: data.snapshot)
        #expect(try await work.summary().accountCount == 2)
        try await work.rebuildIndex()
        #expect(try await work.summary().accountCount == 2)
        try await work.clearLocalData()
        #expect(await secrets.read(b) == nil)
        #expect(try await work.summary().messageCount == 0)
        try await work.close()
        work = try await LocalMailWorkspace.open(paths: test.paths, credentials: secrets, syntheticSnapshot: data.snapshot)
        #expect(try await work.summary().accountCount == 0)
        try await work.restoreSyntheticData()
        #expect(try await work.summary().messageCount == 10)
        #expect(try await work.settings(for: first.id).textIndexEnabled == false)
        try await work.close()
    }

    @Test func interruptedCredentialCleanupIsHiddenAndRetriedAtRestart() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), secrets = SyntheticSecrets(), account = data.snapshot.accounts[0].id
        let work = try await LocalMailWorkspace.open(paths: test.paths, credentials: secrets, syntheticSnapshot: data.snapshot)
        let reference = CredentialReference(accountID: account, purpose: .incomingPassword)
        await secrets.save(Data("synthetic".utf8), for: reference)
        await secrets.setDeletionDenied(true)
        await #expect(throws: KeychainFailure.lockedOrInteractionRequired) { try await work.removeAccount(account) }
        #expect(try await work.repository.accounts(in: data.scope).count == 2)
        #expect(try await work.repository.pendingAccountRemovals() == [account])
        try await work.close()
        await secrets.setDeletionDenied(false)
        let reopened = try await LocalMailWorkspace.open(paths: test.paths, credentials: secrets, syntheticSnapshot: data.snapshot)
        #expect(try await reopened.repository.pendingAccountRemovals().isEmpty)
        #expect(await secrets.read(reference) == nil)
        #expect(try await reopened.summary().accountCount == 2)
        try await reopened.close()
    }

    @Test func missingKeyCannotReplaceAnExistingDatabase() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let data = try SyntheticFixtures.make(), secrets = SyntheticSecrets()
        let work = try await LocalMailWorkspace.open(paths: test.paths, credentials: secrets, syntheticSnapshot: data.snapshot)
        try await work.close()
        let before = try Data(contentsOf: test.paths.database)
        await secrets.deleteDatabaseKey()
        await #expect(throws: KeychainFailure.missingDatabaseKey) {
            try await LocalMailWorkspace.open(paths: test.paths, credentials: secrets, syntheticSnapshot: data.snapshot)
        }
        #expect(try Data(contentsOf: test.paths.database) == before)
    }
}

struct TemporaryStoreTests {
    @Test func releasedFileExpiresWithoutAnotherUserAction() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let cache = try ManagedTemporaryStore(root: test.paths.cache, lifetime: 0.05)
        let lease = try await cache.create(Data("timer".utf8), account: AccountID())
        try await Task.sleep(for: .milliseconds(100))
        #expect(FileManager.default.fileExists(atPath: lease.url.path))
        try await cache.release(lease)
        for _ in 0..<50 {
            if !FileManager.default.fileExists(atPath: lease.url.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: lease.url.path))
    }
    @Test func leasesBudgetTTLAndExportsAreRespected() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let account = try AccountID(), other = try AccountID(), now = Date()
        let cache = try ManagedTemporaryStore(root: test.paths.cache, budget: 10, lifetime: 60, maximumFileBytes: 10)
        let export = test.directory.appendingPathComponent("user-export.txt")
        try Data("user export".utf8).write(to: export)
        let lease = try await cache.create(Data(repeating: 1, count: 8), account: account, now: now)
        await #expect(throws: MailFailure.notFound) { try await cache.acquire(lease.fileID, account: other, now: now) }
        await #expect(throws: LocalStoreFailure.budgetExceeded) { try await cache.create(Data(repeating: 2, count: 3), account: account, now: now) }
        try await cache.cleanup(now: now.addingTimeInterval(70))
        #expect(FileManager.default.fileExists(atPath: lease.url.path)) // Active display survives TTL.
        try await cache.release(lease, now: now.addingTimeInterval(70))
        try await cache.cleanup(now: now.addingTimeInterval(129))
        #expect(FileManager.default.fileExists(atPath: lease.url.path))
        try await cache.cleanup(now: now.addingTimeInterval(130))
        #expect(!FileManager.default.fileExists(atPath: lease.url.path))
        #expect(try String(contentsOf: export, encoding: .utf8) == "user export")
        #expect(await cache.byteCount() == 0)
    }
    @Test func restartPrunesOrphansAndDoesNotFollowSymlinks() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let account = try AccountID(), now = Date()
        let cache = try ManagedTemporaryStore(root: test.paths.cache, lifetime: 60)
        let lease = try await cache.create(Data("synthetic".utf8), account: account, now: now)
        let orphan = test.paths.cache.appendingPathComponent(UUID().uuidString.lowercased() + ".cache")
        try Data("crash orphan".utf8).write(to: orphan)
        let reopened = try ManagedTemporaryStore(root: test.paths.cache, lifetime: 60)
        try await reopened.recover(now: now.addingTimeInterval(61))
        #expect(!FileManager.default.fileExists(atPath: lease.url.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        let outside = test.directory.appendingPathComponent("outside.txt")
        try Data("not a cache".utf8).write(to: outside)
        let link = test.paths.cache.appendingPathComponent(UUID().uuidString.lowercased() + ".cache")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try await reopened.recover(now: now)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "not a cache")
        let directoryLink = test.directory.appendingPathComponent("linked-cache")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: test.paths.cache)
        #expect(throws: LocalStoreFailure.invalidInput) { try ManagedTemporaryStore(root: directoryLink) }
        let mode = try FileManager.default.attributesOfItem(atPath: test.paths.cache.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700)
    }
}
