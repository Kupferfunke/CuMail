import Foundation
import Testing
import GRDB
import MailDomain
import MailApplication
import MailDemo
@testable import MailPersistence

struct AttachmentStorageTests {
    @Test func withdrawEmptyMicrosoftSchemaPreservesAccountsAndOldChecksums() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        try test.paths.prepare()
        let snapshot = try SyntheticFixtures.make().snapshot
        let old = try DatabaseQueue(path: test.paths.database.path, configuration: IndexDatabase.configuration(key: test.key))
        try IndexSchema.migrator().migrate(old, upTo: "v8")
        try await old.write { try IndexWriter.upsert(snapshot, db: $0) }
        let digest = try await old.read { try String.fetchOne($0, sql: "SELECT digest FROM schema_checksums WHERE version=8") }
        try old.close()
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        #expect(try await repo.summary().schemaVersion == 14)
        #expect(try await repo.summary().messageCount == snapshot.messages.count)
        try await repo.close()
        let db = try DatabaseQueue(path: test.paths.database.path, configuration: IndexDatabase.configuration(key: test.key))
        #expect(try await db.read { try !$0.tableExists("graph_profiles") && !$0.tableExists("graph_draft_bindings") })
        #expect(try await db.read { try String.fetchOne($0, sql: "SELECT digest FROM schema_checksums WHERE version=8") } == digest)
        try db.close()
    }
    @Test func migrationRejectsUnexpectedMicrosoftDataInsteadOfDeletingIt() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        try test.paths.prepare()
        let data = try SyntheticFixtures.make()
        let db = try DatabaseQueue(path: test.paths.database.path, configuration: IndexDatabase.configuration(key: test.key))
        try IndexSchema.migrator().migrate(db, upTo: "v8")
        try await db.write { sql in
            try IndexWriter.upsert(data.snapshot, db: sql)
            try sql.execute(sql: "INSERT INTO graph_profiles(account_id,client_id,tenant,user_id,manage_mail,send_mail) VALUES(?, 'synthetic', 'organizations', 'synthetic',0,0)", arguments: [data.snapshot.accounts[0].id.description])
        }
        try db.close()
        #expect(throws: (any Error).self) { try EncryptedMailRepository(paths: test.paths, key: test.key) }
        let preserved = try DatabaseQueue(path: test.paths.database.path, configuration: IndexDatabase.configuration(key: test.key))
        #expect(try await preserved.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM graph_profiles") } == 1)
        try preserved.close()
    }
    @Test func partialFilesArePrivateBudgetedCancellableAndNotPublished() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let store = try ManagedTemporaryStore(root: test.paths.cache, budget: 16, maximumFileBytes: 16)
        let account = try AccountID(), job = try await store.beginDownload(account: account, maximumBytes: 12)
        try await store.append(Data("small".utf8), to: job)
        #expect(await store.byteCount() == 5)
        let partial = try #require(FileManager.default.contentsOfDirectory(at: test.paths.cache, includingPropertiesForKeys: nil).first { $0.pathExtension == "partial" })
        #expect((try FileManager.default.attributesOfItem(atPath: partial.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        await #expect(throws: LocalStoreFailure.budgetExceeded) { try await store.beginDownload(account: account, maximumBytes: 8) }
        await #expect(throws: AttachmentFailure.tooLarge) { try await store.append(Data(repeating: 0, count: 8), to: job) }
        try await store.abort(job)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(await store.byteCount() == 0)
        await #expect(throws: MailFailure.notFound) { try await store.finish(job) }
    }
    @Test func crashRecoveryRemovesPartialAndTypedOrphansAndRespectsExport() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let store = try ManagedTemporaryStore(root: test.paths.cache)
        let job = try await store.beginDownload(account: AccountID(), maximumBytes: 1024)
        try await store.append(Data("partial".utf8), to: job)
        let orphan = test.paths.cache.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("orphan".utf8).write(to: orphan)
        let outside = test.directory.appendingPathComponent("export.pdf")
        try Data("user export".utf8).write(to: outside)
        let recovered = try ManagedTemporaryStore(root: test.paths.cache)
        try await recovered.recover()
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(try FileManager.default.contentsOfDirectory(at: test.paths.cache, includingPropertiesForKeys: nil).allSatisfy { $0.lastPathComponent == "register.json" })
        #expect(try String(contentsOf: outside, encoding: .utf8) == "user export")
        try await store.abort(job)
    }
    @Test func previewTypeUsesBytesAndLeaseSurvivesUntilAllReadersClose() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let store = try ManagedTemporaryStore(root: test.paths.cache)
        let account = try AccountID(), job = try await store.beginDownload(account: account, maximumBytes: 1024)
        try await store.append(Data("%PDF-1.4\nsynthetic".utf8), to: job)
        let lease = try await store.finish(job, mimeType: "application/pdf")
        #expect(lease.url.pathExtension == "pdf")
        #expect(try lease.url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil)
        let second = try await store.acquire(lease.fileID, account: account)
        try await store.discard(lease)
        #expect(FileManager.default.fileExists(atPath: second.url.path))
        try await store.discard(second)
        #expect(await store.byteCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: second.url.path))
    }
    @Test func exportIsByteExactAtomicQuarantinedAndDoesNotFollowSymlink() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let store = try ManagedTemporaryStore(root: test.paths.cache)
        let bytes = Data(repeating: 0x41, count: 150_000)
        let lease = try await store.create(bytes, account: AccountID())
        let target = test.directory.appendingPathComponent("saved.pdf")
        try AttachmentExporter.export(source: lease.url, destination: target)
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try target.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil)
        try Data("old user file".utf8).write(to: target)
        try AttachmentExporter.export(source: lease.url, destination: target)
        #expect(try Data(contentsOf: target) == bytes)
        let link = test.directory.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: (any Error).self) { try AttachmentExporter.export(source: lease.url, destination: link) }
        #expect(try Data(contentsOf: target) == bytes)
        try await store.discard(lease)
        #expect(try Data(contentsOf: target) == bytes)
    }
    @Test func filenamesScopesAndUntrustedPreviewTypesAreBounded() throws {
        let data = try SyntheticFixtures.make(), message = try #require(data.snapshot.messages.first { !$0.attachments.isEmpty })
        let attachment = try #require(message.attachments.first)
        #expect(throws: MailFailure.permissionDenied) { try AttachmentRequest(message: message, attachment: attachment, scope: AccessScope(accountIDs: [])) }
        let other = try #require(data.snapshot.messages.first { $0.id != message.id })
        #expect(throws: MailFailure.permissionDenied) { try AttachmentRequest(message: other, attachment: attachment, scope: data.scope) }
        let name = AttachmentSafety.filename("../../a\\b:\u{202E}evil.app\n")
        #expect(!name.contains("/") && !name.contains("\\") && !name.contains(":"))
        #expect(!name.hasPrefix(".") && !name.contains("\u{202E}"))
        #expect(AttachmentSafety.filename(String(repeating: "ä", count: 500)).utf8.count <= 180)
        #expect(AttachmentSafety.previewExtension(mimeType: "application/pdf", prefix: Data("<html>".utf8)) == nil)
        #expect(AttachmentSafety.previewExtension(mimeType: "image/svg+xml", prefix: Data("<svg>".utf8)) == nil)
        #expect(AttachmentSafety.previewExtension(mimeType: "text/html", prefix: Data("<html>".utf8)) == nil)
    }
}
