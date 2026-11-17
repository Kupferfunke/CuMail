import Foundation
import Testing
import GRDB
import MailApplication
import MailDomain
import MailDemo
@testable import MailPersistence

struct RecipientHistoryTests {
    private func fixture() throws -> MailSnapshot {
        let seed = try SyntheticFixtures.make(), account = seed.snapshot.accounts[0]
        let folders = seed.snapshot.folders.filter { $0.accountID == account.id }
        let sent = try #require(folders.first { $0.role == .sent }), inbox = try #require(folders.first { $0.role == .inbox })
        var messages: [MailMessage] = []
        for i in 0..<4 {
            let recipients = try [MailPerson(name: "Anna Beispiel", address: EmailAddress("anna@example.invalid")),
                                  MailPerson(name: "Alex Beispiel", address: EmailAddress("alex@example.invalid"))]
            messages.append(try MailMessage(id: MessageID(), accountID: account.id,
                locator: .imap(mailbox: i == 3 ? inbox.providerID : sent.providerID, uidValidity: 1, uid: UInt32(i + 1)),
                threadID: nil, folderIDs: [i == 3 ? inbox.id : sent.id], internetMessageID: "<history-\(i)@example.invalid>", subject: "Synthetic \(i)",
                sender: i == 3 ? recipients[0] : MailPerson(name: "Sender", address: account.address),
                recipients: i == 0 ? recipients : i == 3 ? [try MailPerson(name: "Never sent", address: EmailAddress("unused@example.invalid"))] : [recipients[0]],
                receivedAt: Date(timeIntervalSince1970: 100 + Double(i)), isUnread: false, isFlagged: false, preview: nil))
        }
        return try MailSnapshot(accounts: [account], folders: folders, threads: [], messages: messages)
    }

    @Test func migrationLearnsExistingSentMailAndRepeatedSyncNeverInflatesFrequency() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }; try test.paths.prepare()
        let snapshot = try fixture()
        let old = try DatabaseQueue(path: test.paths.database.path, configuration: IndexDatabase.configuration(key: test.key))
        try IndexSchema.migrator().migrate(old, upTo: "v13")
        try await old.write { try IndexWriter.upsert(snapshot, db: $0) }
        try old.close()
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        let initial = try await repo.recipientHistory()
        #expect(initial.map(\.address) == ["anna@example.invalid", "alex@example.invalid"])
        #expect(initial.map(\.useCount) == [3, 1])
        try await repo.upsert(snapshot); try await repo.upsert(snapshot)
        #expect(try await repo.recipientHistory() == initial)
        try await repo.close()
        let reopened = try EncryptedMailRepository(paths: test.paths, key: test.key)
        #expect(try await reopened.recipientHistory() == initial)
        #expect(try await reopened.summary().schemaVersion == 14)
        try await reopened.close()
        let backups = try FileManager.default.contentsOfDirectory(at: test.paths.backups, includingPropertiesForKeys: nil)
        #expect(backups.contains { $0.lastPathComponent.hasPrefix("before-migration-") })
    }

    @Test func onlyAcceptedRecipientsAreLearnedOnceAndSurviveReceiptPurging() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let snapshot = try fixture(), account = snapshot.accounts[0]
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(snapshot)
        var draft = LocalDraft(accountID: account.id, sender: account.address.value)
        draft.to = "new@example.invalid"; draft.cc = "NEW@example.invalid, copy@example.invalid"; draft.bcc = "blind@example.invalid"
        draft = try await repo.saveDraft(draft, expectedRevision: 0)
        #expect(try await repo.recipientHistory().count == 2)
        draft.internetMessageID = "<local-accepted@example.invalid>"; draft.status = .sending
        draft = try await repo.saveDraft(draft, expectedRevision: draft.revision)
        #expect(try await repo.recipientHistory().count == 2)
        draft.status = .accepted; draft = try await repo.saveDraft(draft, expectedRevision: draft.revision)
        draft.status = .sent; draft.purgeContent(); draft = try await repo.saveDraft(draft, expectedRevision: draft.revision)
        let history = try await repo.recipientHistory()
        #expect(history.filter { ["new@example.invalid", "copy@example.invalid", "blind@example.invalid"].contains($0.address) }.count == 3)
        #expect(history.first { $0.address == "new@example.invalid" }?.useCount == 1)
        #expect(draft.to.isEmpty && draft.bcc.isEmpty)
        // A later server copy with the same Message-ID is the same use.
        let original = snapshot.messages[0]
        let copy = try MailMessage(id: MessageID(), accountID: account.id,
            locator: .imap(mailbox: "sent", uidValidity: 1, uid: 50), threadID: nil, folderIDs: original.folderIDs, internetMessageID: draft.internetMessageID,
            subject: "Server copy", sender: original.sender,
            recipients: [try MailPerson(name: "New", address: EmailAddress("new@example.invalid"))],
            receivedAt: draft.modifiedAt, isUnread: false, isFlagged: false, preview: nil)
        try await repo.upsert(MailSnapshot(accounts: [account], folders: snapshot.folders, threads: [], messages: [copy]))
        #expect(try await repo.recipientHistory().first { $0.address == "new@example.invalid" }?.useCount == 1)
        try await repo.close()
    }
}
