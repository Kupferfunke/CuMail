import Foundation
import Testing
import GRDB
import MailDomain
import MailApplication
import MailDemo
@testable import MailPersistence

struct PersonalMailTests {
    @Test func migrationPreservesOldSignaturesAndDraftSnapshots() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        try test.paths.prepare()
        let data = try SyntheticFixtures.make(), account = data.snapshot.accounts[0]
        let signature = try MailSignature(html: "<p>Original signature</p>")
        var draft = LocalDraft(accountID: account.id, sender: account.address.value)
        draft.signature = signature; draft.body = "Existing draft"; draft.revision = 1
        let payload = try JSONEncoder().encode(draft), signaturePayload = try JSONEncoder().encode(signature)
        let old = try DatabaseQueue(path: test.paths.database.path, configuration: IndexDatabase.configuration(key: test.key))
        try IndexSchema.migrator().migrate(old, upTo: "v12")
        let draftID = draft.id.uuidString
        try await old.write { db in
            try IndexWriter.upsert(data.snapshot, db: db)
            try db.execute(sql: "INSERT INTO account_signatures(account_id,payload) VALUES(?,?)", arguments: [account.id.description, signaturePayload])
            try db.execute(sql: "INSERT INTO local_drafts VALUES(?,?,1,'editing',0,?)", arguments: [draftID, account.id.description, payload])
        }
        try old.close()
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        #expect(try await repo.summary().schemaVersion == 14)
        let library = try await repo.signatureLibrary(account: account.id)
        #expect(library.entries.count == 1 && library.defaultSignature?.content == signature)
        #expect(library.defaultSignature?.name == "Standard")
        let restored = try await repo.draft(id: draft.id, account: account.id)
        #expect(restored.signature == signature && restored.signatureID == nil)
        #expect(restored.body == "Existing draft")
        try await repo.close()
        #expect(try FileManager.default.contentsOfDirectory(at: test.paths.backups, includingPropertiesForKeys: nil).count == 1)
    }

    @Test func librariesKeepOneDefaultAndRejectCrossAccountOrInvalidReplacement() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        var repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        let data = try SyntheticFixtures.make(), a = data.snapshot.accounts[0], b = data.snapshot.accounts[1]
        try await repo.seedIfNeeded(data.snapshot)
        let formal = NamedMailSignature(name: "Formal", content: try MailSignature(html: "<p>Formal signature</p>"))
        let short = NamedMailSignature(name: "Short", content: try MailSignature(html: "<p>Short signature</p>"))
        var library = SignatureLibrary(entries: [formal, short], defaultID: formal.id)
        try await repo.saveSignatureLibrary(library, account: a.id)
        await #expect(throws: ComposeFailure.accountMismatch) { try await repo.saveSignatureLibrary(library, account: b.id) }
        await #expect(throws: ComposeFailure.invalidHeader) {
            try await repo.saveSignatureLibrary(SignatureLibrary(entries: [formal, short]), account: a.id)
        }
        var duplicate = short; duplicate.name = "formal"
        await #expect(throws: ComposeFailure.invalidHeader) {
            try await repo.saveSignatureLibrary(SignatureLibrary(entries: [formal, duplicate], defaultID: formal.id), account: a.id)
        }
        #expect(try await repo.signatureLibrary(account: a.id) == library)
        library.defaultID = short.id
        try await repo.saveSignatureLibrary(library, account: a.id)
        #expect(try await repo.signature(account: a.id) == short.content)
        try await repo.close()
        repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        #expect(try await repo.signatureLibrary(account: a.id) == library)
        #expect(try await repo.signatureLibrary(account: b.id).entries.isEmpty)
        library.entries.removeAll { $0.id == short.id }; library.defaultID = formal.id
        try await repo.saveSignatureLibrary(library, account: a.id)
        #expect(try await repo.signature(account: a.id) == formal.content)
        try await repo.close()
    }

    @Test func folderOrderSurvivesRestartAndMetadataRefreshAndRejectsForeignFolders() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        var repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        let data = try SyntheticFixtures.make(), a = data.snapshot.accounts[0].id, b = data.snapshot.accounts[1].id
        try await repo.seedIfNeeded(data.snapshot)
        let order = Array(data.snapshot.folders.filter { $0.accountID == a }.map(\.id).reversed())
        let foreign = try #require(data.snapshot.folders.first { $0.accountID == b }).id
        try await repo.saveFolderOrder(order, account: a)
        await #expect(throws: MailFailure.permissionDenied) { try await repo.saveFolderOrder(order + [foreign], account: a) }
        await #expect(throws: LocalStoreFailure.invalidInput) { try await repo.saveFolderOrder(order + [order[0]], account: a) }
        try await repo.replaceMetadata(with: data.snapshot)
        #expect(try await repo.folderOrder(account: a) == order)
        try await repo.close()
        repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        #expect(try await repo.folderOrder(account: a) == order)
        #expect(try await repo.folderOrder(account: b).isEmpty)
        try await repo.saveFolderOrder([], account: a)
        #expect(try await repo.folderOrder(account: a).isEmpty)
        try await repo.close()
    }
}
