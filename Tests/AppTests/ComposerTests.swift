import Foundation
import AppKit
import SwiftUI
import Testing
import CryptoKit
import MailDomain
import MailApplication
import MailDemo
import MailPersistence
import MailRendering
@testable import MikeMailHub

private actor NoSMTP: SMTPSubmissionSession {
    func connect() throws { throw ComposeFailure.unavailable }
    func prepare(_ draft: LocalDraft, attachments: [OutgoingAttachment]) throws -> PreparedSubmission { throw ComposeFailure.unavailable }
    func submit(_ prepared: PreparedSubmission) throws { throw ComposeFailure.unavailable }
    func disconnect() { }
}
private actor NoSent: SentCopySession {
    func connect() throws { throw ComposeFailure.unavailable }
    func contains(messageID: String, folder: String) -> Bool { false }
    func append(_ rawMessage: String, folder: String) throws { throw ComposeFailure.unavailable }
    func disconnect() { }
}
private actor ApprovedSMTP: SMTPSubmissionSession {
    var sends = 0
    let ambiguous: Bool
    init(ambiguous: Bool) { self.ambiguous = ambiguous }
    func connect() { }
    func prepare(_ draft: LocalDraft, attachments: [OutgoingAttachment]) -> PreparedSubmission {
        PreparedSubmission(rawMessage: "synthetic-only", sender: draft.sender, recipients: [draft.to])
    }
    func submit(_ prepared: PreparedSubmission) throws {
        sends += 1
        if ambiguous { throw ComposeFailure.uncertain }
    }
    func disconnect() { }
}

private actor GatedDraftRepository: DraftRepository {
    let base: EncryptedMailRepository
    var pauseSave = false
    var pauseLibrary = false
    var saveWaiting = false
    var libraryWaiting = false
    var discardCalls = 0
    private var saveGate: CheckedContinuation<Void, Never>?
    private var libraryGate: CheckedContinuation<Void, Never>?
    init(_ base: EncryptedMailRepository) { self.base = base }
    func pauseNextSave() { pauseSave = true }
    func pauseNextLibraryRead() { pauseLibrary = true }
    func releaseSave() { saveGate?.resume(); saveGate = nil; saveWaiting = false }
    func releaseLibrary() { libraryGate?.resume(); libraryGate = nil; libraryWaiting = false }
    func signatureLibrary(account: AccountID) async throws -> SignatureLibrary {
        let snapshot = try await base.signatureLibrary(account: account)
        if pauseLibrary { pauseLibrary = false; libraryWaiting = true; await withCheckedContinuation { libraryGate = $0 } }
        return snapshot
    }
    func drafts(account: AccountID) async throws -> [LocalDraft] { try await base.drafts(account: account) }
    func draft(id: UUID, account: AccountID) async throws -> LocalDraft { try await base.draft(id: id, account: account) }
    func saveDraft(_ draft: LocalDraft, expectedRevision: Int) async throws -> LocalDraft {
        if pauseSave { pauseSave = false; saveWaiting = true; await withCheckedContinuation { saveGate = $0 } }
        return try await base.saveDraft(draft, expectedRevision: expectedRevision)
    }
    func discardDraft(id: UUID, account: AccountID, expectedRevision: Int) async throws {
        discardCalls += 1
        try await base.discardDraft(id: id, account: account, expectedRevision: expectedRevision)
    }
    func recoverInterruptedSubmissions() async throws { try await base.recoverInterruptedSubmissions() }
    func smtpProfile(account: AccountID) async throws -> SMTPProfile? { try await base.smtpProfile(account: account) }
    func saveSMTPProfile(_ profile: SMTPProfile) async throws { try await base.saveSMTPProfile(profile) }
}

@MainActor @Suite(.serialized)
struct ComposerTests {
    @Test func formattedReplySurvivesEditingSignatureChangesAndReopening() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CuMail-formatted-composer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try EncryptedMailRepository(paths: WorkspacePaths(root: root, cache: root.appendingPathComponent("Cache")), key: Data(repeating: 42, count: 32))
        let data = try SyntheticFixtures.make(), account = data.snapshot.accounts[0]
        try await repo.seedIfNeeded(data.snapshot)
        let source = try #require(data.snapshot.messages.first { $0.accountID == account.id })
        let html = try MailHTMLSanitizer.sanitize("<table width='500' style='border-collapse:collapse'><tr><td style='padding:24px;background-color:#f3eee5'><h2 style='color:#A85429'>Gemeinsam weiterdenken.</h2><p>Das <b>Original</b> bleibt formatiert.</p></td></tr></table>")
        var draft = try DraftBuilder.response(to: source, kind: .reply, sender: account.address.value, ownAddresses: [account.address.value], quote: html.plainText, htmlQuote: html)
        draft.body = "Hoi Lena\n\nDanke für deine Nachricht. Das sieht gut aus!"
        draft = try await repo.saveDraft(draft, expectedRevision: 0)
        let service = SubmissionService(repository: repo, credentials: InMemoryCredentialStore(), smtp: { _, _ in NoSMTP() }, sent: { _, _ in NoSent() })
        let editor = ComposerEditor(draft: draft, accountName: account.name, isDemo: true, repository: repo, submission: service, imap: nil, grantAccess: {})
        editor.change { $0.signature = try? MailSignature(html: "<p>Freundliche Grüsse<br><b>Max Beispiel</b></p>"); $0.body += "\n\nBis bald." }
        #expect(await editor.flush())
        let saved = try await repo.draft(id: draft.id, account: account.id)
        #expect(saved.quotation == draft.quotation && saved.outgoingHTML?.contains("<table") == true)
        let reopened = ComposerEditor(draft: saved, accountName: account.name, isDemo: true, repository: repo, submission: service, imap: nil, grantAccess: {})
        await reopened.loadSignatures()
        let controller = ComposerController(editor: reopened)
        controller.showWindow(nil)
        try await Task.sleep(for: .milliseconds(450))
        if let directory = ProcessInfo.processInfo.environment["CUMAIL_HTML_RENDER_DIR"], let view = controller.window?.contentView {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("composer-html-reply.png"))
        }
        #expect(reopened.draft.quotation?.html.preview.bodyMarkup.contains("<table") == true)
        controller.close(); controller.window?.contentView = nil
        try await Task.sleep(for: .milliseconds(50)); try await repo.close()
    }
    @Test func signatureUpdateDuringInitialLoadIsNotLostAndDiscardRunsOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CuMail-composer-races-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try EncryptedMailRepository(paths: WorkspacePaths(root: root, cache: root.appendingPathComponent("Cache")), key: Data(repeating: 42, count: 32))
        let data = try SyntheticFixtures.make(), account = data.snapshot.accounts[0]
        try await base.seedIfNeeded(data.snapshot)
        let original = NamedMailSignature(name: "Original", content: try MailSignature(html: "<p>Original signature</p>"))
        let replacement = NamedMailSignature(name: "Latest", content: try MailSignature(html: "<p>Latest signature</p>"))
        try await base.saveSignatureLibrary(SignatureLibrary(entries: [original], defaultID: original.id), account: account.id)
        let repo = GatedDraftRepository(base)
        let service = SubmissionService(repository: repo, credentials: InMemoryCredentialStore(), smtp: { _, _ in NoSMTP() }, sent: { _, _ in NoSent() })
        let draft = try await base.saveDraft(LocalDraft(accountID: account.id, sender: account.address.value), expectedRevision: 0)
        let editor = ComposerEditor(draft: draft, accountName: account.name, isDemo: true, repository: repo, submission: service, imap: nil, grantAccess: {})
        await repo.pauseNextLibraryRead()
        let initialLoad = Task { await editor.loadSignatures() }
        for _ in 0..<100 { if await repo.libraryWaiting { break }; try await Task.sleep(for: .milliseconds(10)) }
        let pausedLibrary = await repo.libraryWaiting
        let latest = SignatureLibrary(entries: [original, replacement], defaultID: replacement.id)
        try await base.saveSignatureLibrary(latest, account: account.id)
        await editor.loadSignatures() // The settings-changed notification arrives during the initial read.
        await repo.releaseLibrary(); await initialLoad.value
        #expect(pausedLibrary)
        #expect(editor.signatureLibrary == latest)
        #expect(editor.signatureSelection == .none) // Refreshing choices never rewrites the draft.

        editor.change { $0.body = "Synthetic unsent draft" }
        await repo.pauseNextSave()
        let first = Task { await editor.discard() }
        for _ in 0..<100 { if await repo.saveWaiting { break }; try await Task.sleep(for: .milliseconds(10)) }
        let pausedSave = await repo.saveWaiting
        let second = Task { await editor.discard() }
        await Task.yield()
        await repo.releaseSave()
        let firstResult = await first.value, secondResult = await second.value
        #expect(pausedSave && firstResult && !secondResult)
        #expect(await repo.discardCalls == 1)
        #expect(try await base.drafts(account: account.id).isEmpty)
        try await base.close()
    }
    @Test(arguments: [false, true]) func signatureChoiceReplacesOnlySignatureAndSurvivesReopening(reply: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CuMail-signature-selection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try EncryptedMailRepository(paths: WorkspacePaths(root: root, cache: root.appendingPathComponent("Cache")), key: Data(repeating: 42, count: 32))
        let data = try SyntheticFixtures.make(), account = data.snapshot.accounts[0], other = data.snapshot.accounts[1]
        try await repo.seedIfNeeded(data.snapshot)
        let formal = NamedMailSignature(name: "Formal", content: try MailSignature(html: "<p>FORMAL-SIGNATURE</p>"))
        var short = NamedMailSignature(name: "Short", content: try MailSignature(html: "<p>SHORT-SIGNATURE</p>"))
        let foreign = NamedMailSignature(name: "Foreign", content: try MailSignature(html: "<p>OTHER-ACCOUNT</p>"))
        try await repo.saveSignatureLibrary(SignatureLibrary(entries: [formal, short], defaultID: formal.id), account: account.id)
        try await repo.saveSignatureLibrary(SignatureLibrary(entries: [foreign], defaultID: foreign.id), account: other.id)
        let source = try #require(data.snapshot.messages.first { $0.accountID == account.id })
        var draft = reply ? try DraftBuilder.response(to: source, kind: .reply, sender: account.address.value, ownAddresses: [account.address.value], quote: "Quoted message remains untouched") : LocalDraft(accountID: account.id, sender: account.address.value)
        draft.body = "My own text" + draft.body
        draft.useSignature(try await repo.signatureLibrary(account: account.id).defaultSignature)
        let body = draft.body
        draft = try await repo.saveDraft(draft, expectedRevision: 0)
        let submission = SubmissionService(repository: repo, credentials: InMemoryCredentialStore(), smtp: { _, _ in NoSMTP() }, sent: { _, _ in NoSent() })
        let editor = ComposerEditor(draft: draft, accountName: account.name, isDemo: true, repository: repo, submission: submission, imap: nil, grantAccess: {})
        await editor.loadSignatures()
        #expect(editor.signatureSelection == .saved(formal.id))
        editor.selectSignature(.saved(short.id))
        #expect(editor.draft.body == body && editor.draft.signatureID == short.id)
        #expect(editor.draft.outgoingPlainText == body + "\n\nSHORT-SIGNATURE")
        #expect(!editor.draft.outgoingHTML!.contains("FORMAL-SIGNATURE"))
        editor.selectSignature(.saved(foreign.id))
        #expect(editor.draft.signatureID == short.id)
        #expect(await editor.flush())

        // Editing the account library cannot silently rewrite an existing draft.
        short.content = try MailSignature(html: "<p>NEW-SHORT-SIGNATURE</p>")
        try await repo.saveSignatureLibrary(SignatureLibrary(entries: [formal, short], defaultID: short.id), account: account.id)
        await editor.loadSignatures()
        #expect(editor.signatureSelection == .snapshot)
        #expect(editor.draft.outgoingPlainText == body + "\n\nSHORT-SIGNATURE")
        editor.selectSignature(.saved(short.id))
        #expect(editor.draft.outgoingPlainText == body + "\n\nNEW-SHORT-SIGNATURE")
        editor.selectSignature(.none)
        #expect(editor.draft.outgoingPlainText == body && editor.draft.outgoingHTML == nil)
        #expect(await editor.flush())
        let saved = try await repo.draft(id: draft.id, account: account.id)
        let reopened = ComposerEditor(draft: saved, accountName: account.name, isDemo: true, repository: repo, submission: submission, imap: nil, grantAccess: {})
        await reopened.loadSignatures()
        #expect(reopened.signatureSelection == .none && reopened.draft.body == body)
        #expect(try await repo.signatureLibrary(account: account.id).defaultID == short.id)
        try await repo.close()
    }

    @Test(arguments: [false, true], [ComposeKind.reply, .replyAll, .forward])
    func sendNeedsExactSingleUseNativeReviewAndNeverRetries(ambiguous: Bool, kind: ComposeKind) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MMH-approval-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try EncryptedMailRepository(paths: WorkspacePaths(root: root, cache: root.appendingPathComponent("Cache")), key: Data(repeating: 42, count: 32))
        let data = try SyntheticFixtures.make(), account = data.snapshot.accounts[0]
        try await repo.seedIfNeeded(data.snapshot)
        let sent = try #require(data.snapshot.folders.first { $0.accountID == account.id && $0.role == .sent })
        let profile = try SMTPProfile(accountID: account.id, host: "smtp.example.invalid", port: 465, security: .implicitTLS, username: account.address.value, sentPolicy: .providerManaged, sentFolder: sent.providerID)
        try await repo.saveSMTPProfile(profile)
        let keys = InMemoryCredentialStore(), smtp = ApprovedSMTP(ambiguous: ambiguous)
        try await keys.save(Data("public-synthetic-secret".utf8), for: CredentialReference(accountID: account.id, purpose: .outgoingPassword))
        try await keys.save(Data("public-synthetic-secret".utf8), for: CredentialReference(accountID: account.id, purpose: .incomingPassword))
        let service = SubmissionService(repository: repo, credentials: keys, smtp: { _, _ in smtp }, sent: { _, _ in NoSent() })
        let inbox = InboxModel(dataset: data)
        await inbox.start(autoSelectDemo: false)
        for _ in 0..<200 { if !inbox.isLoading { break }; try await Task.sleep(for: .milliseconds(10)) }
        let source = try #require(inbox.displayedMessages.first)
        let next = try #require(inbox.displayedMessages.dropFirst().first)
        inbox.selection = [source.id]
        var draft = try DraftBuilder.response(to: source, kind: kind, sender: account.address.value,
            ownAddresses: [account.address.value], quote: "Synthetic source")
        draft.to = "synthetic@example.invalid"; draft.body = "Original reviewed text"
        draft = try await repo.saveDraft(draft, expectedRevision: 0)
        draft = try await repo.draft(id: draft.id, account: account.id)
        #expect(draft.sourceMessageID == source.id)
        let imap = try IMAPConfiguration(accountID: account.id, host: "imap.example.invalid", port: 993, security: .implicitTLS, username: account.address.value)
        let editor = ComposerEditor(draft: draft, accountName: "Synthetic only", isDemo: false, repository: repo, submission: service, imap: imap, grantAccess: {})
        inbox.bindSendContinuation(to: editor)
        let controller = ComposerController(editor: editor)
        controller.showWindow(nil)
        defer { controller.close() }
        #expect(controller.window?.isVisible == true)
        await editor.send(); #expect(await smtp.sends == 0)
        #expect(await editor.review())
        try editor.beginAssistantDirectSend(editor.draft)
        editor.change { $0.body = "Must not change while sending" }
        #expect(!editor.dirty)
        editor.busy = false
        // A direct send invalidates an already granted native confirmation too.
        await editor.send(); #expect(await smtp.sends == 0)
        #expect(await editor.review())
        editor.change { $0.body = "Changed after review" }
        #expect(throws: ComposeFailure.conflict) { try editor.beginAssistantDirectSend(editor.draft) }
        await editor.send(); #expect(await smtp.sends == 0)
        #expect(await editor.review())
        let signature = NamedMailSignature(name: "Changed signature", content: try MailSignature(html: "<p>Signature after review</p>"))
        try await repo.saveSignatureLibrary(SignatureLibrary(entries: [signature], defaultID: signature.id), account: account.id)
        await editor.loadSignatures(); editor.selectSignature(.saved(signature.id))
        await editor.send(); #expect(await smtp.sends == 0)
        // The Send button now validates and submits in one deliberate action.
        await editor.sendFromComposer(); #expect(await smtp.sends == 1)
        #expect(editor.draft.status == (ambiguous ? .uncertain : .accepted))
        #expect(controller.window?.isVisible == ambiguous)
        #expect(!editor.busy)
        for _ in 0..<100 { if ambiguous || inbox.selectedMessage?.id == next.id { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(inbox.selectedMessage?.id == (ambiguous ? source.id : next.id))
        // A saved receipt can still be reopened for checking the sent-copy status.
        if !ambiguous {
            let receipt = ComposerController(editor: ComposerEditor(draft: editor.draft, accountName: "Synthetic receipt", isDemo: false,
                repository: repo, submission: service, imap: imap, grantAccess: {}))
            receipt.showWindow(nil)
            #expect(receipt.window?.isVisible == true)
            receipt.close()
            receipt.window?.contentView = nil
        }
        await editor.send(); #expect(await smtp.sends == 1)
        #expect(await editor.review() == false)
        controller.window?.contentView = nil
        // Detach SwiftUI before closing its temporary repository: the view's
        // signature-loading task can start on the next main-loop iteration.
        try await Task.sleep(for: .milliseconds(100))
        try await repo.close()
    }
    @Test(arguments: [DraftStatus.sent, .accepted, .uncertain, .failed])
    func directSendClosesOnlyOnProviderAcceptance(status: DraftStatus) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CuMail-window-result-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try EncryptedMailRepository(paths: WorkspacePaths(root: root, cache: root.appendingPathComponent("Cache")), key: Data(repeating: 42, count: 32))
        let data = try SyntheticFixtures.make(), account = data.snapshot.accounts[0]
        try await repo.seedIfNeeded(data.snapshot)
        let service = SubmissionService(repository: repo, credentials: InMemoryCredentialStore(), smtp: { _, _ in NoSMTP() }, sent: { _, _ in NoSent() })
        var draft = LocalDraft(accountID: account.id, sender: account.address.value)
        draft.to = "synthetic@example.invalid"; draft.body = "Window lifecycle only"
        let editor = ComposerEditor(draft: draft, accountName: "Synthetic only", isDemo: false, repository: repo, submission: service, imap: nil, grantAccess: {})
        let controller = ComposerController(editor: editor)
        controller.showWindow(nil)
        defer { controller.close() }
        try editor.beginAssistantDirectSend(draft)
        draft.status = status
        editor.draft = draft
        editor.finishSubmission()
        #expect(controller.window?.isVisible == (status == .uncertain || status == .failed))
        #expect(!editor.busy)
        controller.window?.contentView = nil
        try await Task.sleep(for: .milliseconds(100))
        try await repo.close()
    }
    @Test func attachmentBookmarkRejectsChangedAndMissingSelectedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MikeMailAttachmentTest-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.txt"), data = Data("public test attachment".utf8)
        try data.write(to: file)
        let bookmark = try file.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        let reference = DraftAttachment(filename: "synthetic.txt", mimeType: "text/plain", byteCount: data.count, bookmark: bookmark, digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        #expect(try ComposerEditor.loadAttachment(reference).data == data)
        try Data("different bytes".utf8).write(to: file)
        #expect(throws: ComposeFailure.attachmentChanged) { try ComposerEditor.loadAttachment(reference) }
        try FileManager.default.removeItem(at: file)
        #expect(throws: ComposeFailure.attachmentUnavailable) { try ComposerEditor.loadAttachment(reference) }
    }
    @Test func independentWindowsAutosaveAndConflictPreservesUnsavedText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MikeMailComposerTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try EncryptedMailRepository(paths: WorkspacePaths(root: root, cache: root.appendingPathComponent("Cache")), key: Data(repeating: 42, count: 32))
        let data = try SyntheticFixtures.make(), account = data.snapshot.accounts[0]
        try await repo.seedIfNeeded(data.snapshot)
        let service = SubmissionService(repository: repo, credentials: InMemoryCredentialStore(), smtp: { _, _ in NoSMTP() }, sent: { _, _ in NoSent() })
        func create(_ draft: LocalDraft) -> ComposerEditor {
            ComposerEditor(draft: draft, accountName: account.name, isDemo: true, repository: repo, submission: service, imap: nil, grantAccess: {})
        }
        let first = create(try await repo.saveDraft(LocalDraft(accountID: account.id, sender: account.address.value), expectedRevision: 0))
        let second = create(try await repo.saveDraft(LocalDraft(accountID: account.id, sender: account.address.value), expectedRevision: 0))
        let staleEditor = create(first.draft)
        first.change { $0.subject = "First synthetic window"; $0.body = "First isolated text" }
        second.change { $0.subject = "Second synthetic window"; $0.body = "Second isolated text" }
        #expect(await first.flush()); #expect(await second.flush())
        #expect(try await repo.draft(id: first.draft.id, account: account.id).body == "First isolated text")
        #expect(try await repo.draft(id: second.draft.id, account: account.id).body == "Second isolated text")
        staleEditor.change { $0.body = "Unsaved conflict kept in window" }
        #expect(await staleEditor.flush() == false)
        #expect(staleEditor.dirty && staleEditor.draft.body == "Unsaved conflict kept in window" && staleEditor.message != nil)
        #expect(try await repo.draft(id: first.draft.id, account: account.id).body == "First isolated text")
        // The native layout remains usable at its minimum size in both themes.
        _ = NSApplication.shared; AppResources.registerFonts()
        for scheme in [ColorScheme.light, .dark] {
            let hosting = NSHostingView(rootView: ComposerView(editor: first, closeAfterDiscard: {}).environment(\.colorScheme, scheme))
            hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 690)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            if let path = ProcessInfo.processInfo.environment["MIKE_MAIL_COMPOSER_RENDER_DIR"] {
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("composer-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        try await repo.close()
    }
}
