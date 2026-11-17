import Foundation
import Testing
import MailApplication
import MailDomain
import MailDemo
import MailRendering
@testable import MailPersistence

private actor ComposeKeys: CredentialStore {
    var values: [CredentialReference: Data] = [:]
    func read(_ reference: CredentialReference) -> Data? { values[reference] }
    func save(_ secret: Data, for reference: CredentialReference) { values[reference] = secret }
    func delete(_ reference: CredentialReference) { values.removeValue(forKey: reference) }
}
private actor SMTPAuthorization {
    private var checks = 0
    let revokeAt: Int
    init(_ revokeAt: Int) { self.revokeAt = revokeAt }
    func check() throws {
        checks += 1
        if checks >= revokeAt { throw MailFailure.permissionDenied }
    }
}
private actor SubmissionStub: SMTPSubmissionSession {
    let failure: ComposeFailure?
    var sends = 0
    init(failure: ComposeFailure? = nil) { self.failure = failure }
    func connect() { }
    func prepare(_ draft: LocalDraft, attachments: [OutgoingAttachment]) -> PreparedSubmission {
        PreparedSubmission(rawMessage: "synthetic-own-message", sender: draft.sender, recipients: [draft.to])
    }
    func submit(_ prepared: PreparedSubmission) throws { sends += 1; if let failure { throw failure } }
    func disconnect() { }
}
private actor SentStub: SentCopySession {
    var exists: Bool
    var appends = 0
    let failAppend: Bool
    var failConnect: Bool
    init(exists: Bool = false, failAppend: Bool = false, failConnect: Bool = false) {
        self.exists = exists; self.failAppend = failAppend; self.failConnect = failConnect
    }
    func connect() throws { if failConnect { throw ComposeFailure.connection } }
    func enableConnection() { failConnect = false }
    func contains(messageID: String, folder: String) -> Bool { exists }
    func append(_ rawMessage: String, folder: String) throws { appends += 1; if failAppend { throw ComposeFailure.uncertain }; exists = true }
    func disconnect() { }
}

private struct DraftHarness {
    let test = TestWorkspace()
    let repository: EncryptedMailRepository
    let account: MailAccount
    let config: IMAPConfiguration
    let profile: SMTPProfile
    let keys = ComposeKeys()
    init(policy: SentCopyPolicy = .appendToFolder) async throws {
        let data = try SyntheticFixtures.make()
        let selectedAccount = data.snapshot.accounts[0]
        account = selectedAccount
        config = try IMAPConfiguration(accountID: account.id, host: "mail.example.invalid", port: 993, security: .implicitTLS, username: account.address.value)
        let folder = try #require(data.snapshot.folders.first { $0.accountID == selectedAccount.id && $0.role == .sent })
        profile = try SMTPProfile(accountID: account.id, host: "smtp.example.invalid", port: 465, security: .implicitTLS, username: account.address.value, sentPolicy: policy, sentFolder: folder.providerID)
        repository = try EncryptedMailRepository(paths: test.paths, key: test.key)
        try await repository.seedIfNeeded(data.snapshot)
        try await repository.saveSMTPProfile(profile)
        for purpose in [CredentialReference.Purpose.incomingPassword, .outgoingPassword] {
            await keys.save(Data("public synthetic test secret".utf8), for: CredentialReference(accountID: account.id, purpose: purpose))
        }
    }
    func draft() async throws -> LocalDraft {
        var draft = LocalDraft(accountID: account.id, sender: account.address.value)
        draft.to = "recipient@example.invalid"; draft.subject = "Synthetic draft"; draft.body = "PRIVATE-DRAFT-TEST-ONLY-9ec2"
        return try await repository.saveDraft(draft, expectedRevision: 0)
    }
    func service(_ smtp: SubmissionStub, _ sent: SentStub) -> SubmissionService {
        SubmissionService(repository: repository, credentials: keys, smtp: { _, _ in smtp }, sent: { _, _ in sent })
    }
    func close() async throws { try await repository.close(); test.cleanup() }
}

struct DraftTests {
    @Test func formattedQuotationSurvivesEncryptedRestartAndLocksDuringSending() async throws {
        let h = try await DraftHarness()
        var draft = try await h.draft()
        draft.quotation = try DraftQuotation(heading: "Original:", plainText: "Formatted original", html: MailHTMLSanitizer.sanitize("<p style='color:#123456'><b>Formatted original</b></p>"))
        draft = try await h.repository.saveDraft(draft, expectedRevision: draft.revision)
        let html = draft.outgoingHTML
        try await h.repository.close()
        let reopened = try EncryptedMailRepository(paths: h.test.paths, key: h.test.key)
        var loaded = try await reopened.draft(id: draft.id, account: h.account.id)
        #expect(loaded == draft && loaded.outgoingHTML == html)
        loaded.status = .sending
        loaded = try await reopened.saveDraft(loaded, expectedRevision: loaded.revision)
        var modified = loaded; modified.quotation = nil
        await #expect(throws: ComposeFailure.locked) { try await reopened.saveDraft(modified, expectedRevision: modified.revision) }
        try await reopened.close(); h.test.cleanup()
    }
    @Test(arguments: [1, 2, 3]) func smtpRevalidatesAuthorizationIncludingAfterDurableIntent(revokeAt: Int) async throws {
        let h = try await DraftHarness(), smtp = SubmissionStub(), sent = SentStub()
        let draft = try await h.draft(), authorization = SMTPAuthorization(revokeAt)
        await #expect(throws: MailFailure.permissionDenied) {
            try await h.service(smtp, sent).send(id: draft.id, account: h.account.id, expectedRevision: draft.revision, attachments: [], imap: h.config, authorize: { try await authorization.check() })
        }
        #expect(await smtp.sends == 0)
        #expect(await sent.appends == 0)
        let saved = try await h.repository.draft(id: draft.id, account: h.account.id)
        #expect(saved.status == (revokeAt == 3 ? .failed : .editing))
        try await h.close()
    }
    @Test func draftSurvivesRestartEncryptedAndRejectsStaleRevisionAndWrongAccount() async throws {
        let h = try await DraftHarness()
        let initial = try await h.draft()
        var modified = initial; modified.body += " updated"
        let saved = try await h.repository.saveDraft(modified, expectedRevision: initial.revision)
        await #expect(throws: ComposeFailure.conflict) { try await h.repository.saveDraft(initial, expectedRevision: initial.revision) }
        let other = try AccountID()
        await #expect(throws: ComposeFailure.accountMismatch) { try await h.repository.draft(id: initial.id, account: other) }
        try await h.repository.close()
        let raw = try Data(contentsOf: h.test.paths.database)
        #expect(raw.range(of: Data(initial.body.utf8)) == nil)
        let reopened = try EncryptedMailRepository(paths: h.test.paths, key: h.test.key)
        #expect(try await reopened.draft(id: saved.id, account: h.account.id) == saved)
        try await reopened.close(); h.test.cleanup()
    }
    @Test func acceptedSendCreatesOneSentCopyPurgesOwnBodyAndCannotSendAgain() async throws {
        let h = try await DraftHarness(), smtp = SubmissionStub(), sent = SentStub()
        let draft = try await h.draft(), service = h.service(smtp, sent)
        let result = try await service.send(id: draft.id, account: h.account.id, expectedRevision: draft.revision, attachments: [], imap: h.config)
        #expect(result.status == .sent && result.body.isEmpty && result.to.isEmpty && result.operationID != nil)
        #expect(await smtp.sends == 1)
        #expect(await sent.appends == 1)
        await #expect(throws: ComposeFailure.locked) { try await service.send(id: draft.id, account: h.account.id, expectedRevision: result.revision, attachments: [], imap: h.config) }
        #expect(await smtp.sends == 1)
        try await h.close()
    }
    @Test func ambiguousSMTPNeverAppendsOrResendsAndRetainsRecoveryDraft() async throws {
        let h = try await DraftHarness(), smtp = SubmissionStub(failure: .uncertain), sent = SentStub()
        let draft = try await h.draft(), service = h.service(smtp, sent)
        let result = try await service.send(id: draft.id, account: h.account.id, expectedRevision: draft.revision, attachments: [], imap: h.config)
        #expect(result.status == .uncertain && result.body == draft.body)
        let checked = try await service.reconcile(id: draft.id, account: h.account.id, imap: h.config)
        #expect(checked.status == .uncertain)
        await #expect(throws: ComposeFailure.locked) { try await service.send(id: draft.id, account: h.account.id, expectedRevision: result.revision, attachments: [], imap: h.config) }
        #expect(await smtp.sends == 1)
        #expect(await sent.appends == 0)
        try await h.close()
    }
    @Test func explicitSMTPRejectionAllowsUserToEditWithoutAutomaticRetry() async throws {
        let h = try await DraftHarness(), smtp = SubmissionStub(failure: .rejected), sent = SentStub()
        let draft = try await h.draft()
        var result = try await h.service(smtp, sent).send(id: draft.id, account: h.account.id, expectedRevision: draft.revision, attachments: [], imap: h.config)
        #expect(result.status == .failed && result.body == draft.body)
        result.to = "corrected@example.invalid"
        _ = try await h.repository.saveDraft(result, expectedRevision: result.revision)
        #expect(await smtp.sends == 1)
        #expect(await sent.appends == 0)
        try await h.close()
    }
    @Test func interruptedSubmissionBecomesUncertainAndCannotBeEdited() async throws {
        let h = try await DraftHarness()
        var draft = try await h.draft(); draft.status = .sending; draft.operationID = UUID(); draft.internetMessageID = "<crash@example.invalid>"
        draft = try await h.repository.saveDraft(draft, expectedRevision: draft.revision)
        try await h.repository.recoverInterruptedSubmissions()
        var recovered = try await h.repository.draft(id: draft.id, account: h.account.id)
        #expect(recovered.status == .uncertain && recovered.internetMessageID == draft.internetMessageID)
        recovered.body = "Overwrite"
        await #expect(throws: ComposeFailure.locked) { try await h.repository.saveDraft(recovered, expectedRevision: recovered.revision) }
        await #expect(throws: ComposeFailure.locked) { try await h.repository.discardDraft(id: recovered.id, account: recovered.accountID, expectedRevision: recovered.revision) }
        try await h.close()
    }
    @Test func ambiguousAppendIsNeverRepeatedEvenWhenSearchIsEmpty() async throws {
        let h = try await DraftHarness(), smtp = SubmissionStub(), sent = SentStub(failAppend: true)
        let draft = try await h.draft(), service = h.service(smtp, sent)
        let result = try await service.send(id: draft.id, account: h.account.id, expectedRevision: draft.revision, attachments: [], imap: h.config)
        #expect(result.status == .accepted && result.appendAttempted)
        _ = try await service.reconcile(id: result.id, account: result.accountID, imap: h.config)
        await #expect(throws: ComposeFailure.locked) { try await service.completeSentCopy(id: result.id, account: result.accountID, imap: h.config, attachments: []) }
        #expect(await smtp.sends == 1)
        #expect(await sent.appends == 1)
        try await h.close()
    }
    @Test func acceptedSendCanRecoverCopyWithoutResubmittingSMTP() async throws {
        let h = try await DraftHarness(), smtp = SubmissionStub(), sent = SentStub(failConnect: true)
        let draft = try await h.draft(), service = h.service(smtp, sent)
        let result = try await service.send(id: draft.id, account: h.account.id, expectedRevision: draft.revision, attachments: [], imap: h.config)
        #expect(result.status == .accepted && !result.appendAttempted)
        await sent.enableConnection()
        let repaired = try await service.completeSentCopy(id: result.id, account: result.accountID, imap: h.config, attachments: [])
        #expect(repaired.status == .sent && repaired.internetMessageID == result.internetMessageID)
        #expect(await smtp.sends == 1)
        #expect(await sent.appends == 1)
        try await h.close()
    }
    @Test(arguments: [SentCopyPolicy.appendToFolder, .providerManaged])
    func providerExistingCopyIsNotDuplicated(policy: SentCopyPolicy) async throws {
        let h = try await DraftHarness(policy: policy), smtp = SubmissionStub(), sent = SentStub(exists: true)
        let draft = try await h.draft()
        let result = try await h.service(smtp, sent).send(id: draft.id, account: h.account.id, expectedRevision: draft.revision, attachments: [], imap: h.config)
        #expect(result.status == .sent && !result.appendAttempted)
        #expect(await sent.appends == 0)
        try await h.close()
    }
    @Test func metadataRebuildPreservesOwnDraftButAccountRemovalCascades() async throws {
        let h = try await DraftHarness(), draft = try await h.draft()
        let data = try SyntheticFixtures.make()
        try await h.repository.replaceMetadata(with: data.snapshot)
        #expect(try await h.repository.draft(id: draft.id, account: h.account.id).body == draft.body)
        try await h.repository.markAccountForRemoval(h.account.id)
        try await h.repository.finishAccountRemoval(h.account.id)
        await #expect(throws: ComposeFailure.accountMismatch) { try await h.repository.draft(id: draft.id, account: h.account.id) }
        try await h.close()
    }
    @Test func changedSMTPHostDoesNotReceiveStoredCredentialWithoutExplicitChoice() async throws {
        let h = try await DraftHarness(), smtp = SubmissionStub(), sent = SentStub()
        let changed = try SMTPProfile(accountID: h.account.id, host: "different.example.invalid", port: 465, security: .implicitTLS, username: h.account.address.value, sentPolicy: .appendToFolder, sentFolder: h.profile.sentFolder)
        await #expect(throws: ComposeFailure.missingCredential) { try await h.service(smtp, sent).configure(changed, password: nil, reuseIncoming: false) }
        #expect(try await h.repository.smtpProfile(account: h.account.id) == h.profile)
        try await h.close()
    }
}
