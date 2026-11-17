import Foundation
import Testing
import GRDB
import MailApplication
import MailDomain
import MailDemo
@testable import MailPersistence

struct FullMailTests {
    private func fixture(_ repo: EncryptedMailRepository) async throws -> (MailAccount, MailFolder) {
        let id = try AccountID()
        let account = MailAccount(id: id, name: "Full mailbox", address: try EmailAddress("\(id)@example.invalid"), provider: .imap, status: .connected)
        let folder = try MailFolder(id: IMAPIdentity.folder(account: account.id, mailbox: "INBOX"), accountID: account.id, providerID: "INBOX", name: "Inbox", role: .inbox)
        try await repo.addIMAPAccount(account, configuration: IMAPConfiguration(accountID: account.id, host: "imap.example.invalid", port: 993, security: .implicitTLS, username: account.address.value), folders: [folder])
        return (account, folder)
    }
    private func messages(_ range: ClosedRange<Int>, account: MailAccount, folder: MailFolder, validity: UInt32 = 7) throws -> [MailMessage] {
        try range.map { n in
            try MailMessage(id: IMAPIdentity.message(account: account.id, mailbox: folder.providerID, validity: validity, uid: UInt32(n)),
                accountID: account.id, locator: .imap(mailbox: folder.providerID, uidValidity: validity, uid: UInt32(n)), threadID: nil, folderIDs: [folder.id],
                subject: "Synthetic \(n)", sender: MailPerson(name: "Sender", address: EmailAddress("sender@example.invalid")), recipients: [],
                receivedAt: Date(timeIntervalSince1970: Double(n)), isUnread: true, isFlagged: false, preview: nil, threadingHeadersLoaded: true)
        }
    }
    @Test func resumesAcrossRestartAndPrunesOnlyAfterCompleteScanBeyond200() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        var repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        let (account, folder) = try await fixture(repo)
        var scan = try await repo.fullMailScan(account: account.id, scope: folder.id.description, anchor: nil)
        _ = try await repo.applyFullMailPage(scan, account: account, folders: [folder], messages: messages(142...241, account: account, folder: folder), providerThreads: [:], nextCursor: "page2", uidValidity: 7, serverCount: 241)
        try await repo.close()
        repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        scan = try await repo.fullMailScan(account: account.id, scope: folder.id.description, anchor: nil)
        #expect(scan.cursor == "page2")
        _ = try await repo.applyFullMailPage(scan, account: account, folders: [folder], messages: messages(42...141, account: account, folder: folder), providerThreads: [:], nextCursor: "page3", uidValidity: 7, serverCount: 241)
        scan = try await repo.fullMailScan(account: account.id, scope: folder.id.description, anchor: nil)
        let count = try await repo.applyFullMailPage(scan, account: account, folders: [folder], messages: messages(1...41, account: account, folder: folder), providerThreads: [:], nextCursor: nil, uidValidity: 7, serverCount: 241)
        #expect(count == 241)
        #expect(try await repo.summary().messageCount == 241)
        #expect(try await repo.imapSummaries().first?.indexedCount == 241)
        scan = try await repo.fullMailScan(account: account.id, scope: folder.id.description, anchor: nil)
        _ = try await repo.applyFullMailPage(scan, account: account, folders: [folder], messages: messages(1...100, account: account, folder: folder), providerThreads: [:], nextCursor: "next", uidValidity: 7, serverCount: 100)
        #expect(try await repo.summary().messageCount == 241)
        let stale = scan
        scan = try await repo.fullMailScan(account: account.id, scope: folder.id.description, anchor: nil)
        await #expect(throws: SearchFailure.invalidCursor) {
            try await repo.applyFullMailPage(stale, account: account, folders: [folder], messages: [], providerThreads: [:], nextCursor: nil, uidValidity: 7, serverCount: 100)
        }
        _ = try await repo.applyFullMailPage(scan, account: account, folders: [folder], messages: [], providerThreads: [:], nextCursor: nil, uidValidity: 7, serverCount: 100)
        #expect(try await repo.summary().messageCount == 100)
        try await repo.close()
    }
    @Test func signatureBelongsToAccountAndDraftSnapshotSurvivesChangeAndRebuild() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        let (a, _) = try await fixture(repo), (b, _) = try await fixture(repo)
        let signature = try MailSignature(html: "<div style=\"color:#A85429;font-size:12px\"><b>Mike</b><br>CuMail<br><a href=\"mailto:mike@example.invalid\">Kontakt</a></div>")
        try await repo.saveSignature(signature, account: a.id)
        #expect(try await repo.signature(account: b.id) == nil)
        var draft = LocalDraft(accountID: a.id, sender: a.address.value)
        draft.body = "Hello"; draft.signature = try await repo.signature(account: a.id)
        draft = try await repo.saveDraft(draft, expectedRevision: 0)
        try await repo.saveSignature(MailSignature(html: "<b>Changed</b>"), account: a.id)
        #expect(try await repo.draft(id: draft.id, account: a.id).signature == signature)
        try await repo.replaceMetadata(with: MailSnapshot(accounts: [], folders: [], threads: [], messages: []))
        #expect(try await repo.signature(account: a.id)?.plainText == "Changed")
        #expect(try await repo.draft(id: draft.id, account: a.id).signature == signature)
        draft.status = .sending; draft = try await repo.saveDraft(draft, expectedRevision: draft.revision)
        draft.signature = try MailSignature(html: "<b>Unexpected</b>")
        await #expect(throws: ComposeFailure.locked) { try await repo.saveDraft(draft, expectedRevision: draft.revision) }
        try await repo.close()
    }
    @Test func developmentCleanupPreservesRealDraftsAndSignatures() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repo.seedIfNeeded(SyntheticFixtures.make().snapshot)
        let (account, _) = try await fixture(repo)
        var draft = LocalDraft(accountID: account.id, sender: account.address.value); draft.body = "Keep me"
        draft = try await repo.saveDraft(draft, expectedRevision: 0)
        try await repo.saveSignature(MailSignature(html: "<b>Keep signature</b>"), account: account.id)
        try await repo.removeDevelopmentFixtures()
        #expect(try await repo.summary().accountCount == 1)
        #expect(try await repo.draft(id: draft.id, account: account.id).body == "Keep me")
        #expect(try await repo.signature(account: account.id) != nil)
        try await repo.close()
    }
}
