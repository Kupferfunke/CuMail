import AppKit
import Observation
import SwiftUI
import CryptoKit
import UniformTypeIdentifiers
import MailDomain
import MailApplication
import MailSecurity
import MailGoogle

enum ComposerSignatureSelection: Hashable {
    case none, saved(UUID), snapshot
}

@MainActor @Observable
final class ComposerEditor {
    var draft: LocalDraft
    let accountName: String
    let isDemo: Bool
    var dirty = false
    var busy = false
    var saving = false
    var message: String?
    var keychainNeeded = false
    var hasConflict = false
    var signatureLibrary = SignatureLibrary()
    var signaturesLoading = false
    var signatureError: String?
    var recipientHistory: [UsedRecipient] = []
    @ObservationIgnored private var loadingRecipientHistory = false
    @ObservationIgnored private var signatureReloadPending = false
    @ObservationIgnored private let repository: any DraftRepository
    @ObservationIgnored private let submission: SubmissionService
    @ObservationIgnored private let imap: IMAPConfiguration?
    @ObservationIgnored private let google: GmailSubmission?
    var isGoogle: Bool { google != nil }
    @ObservationIgnored private let grantAccess: @MainActor () async -> Void
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Bool, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reviewedDraft: LocalDraft?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var closeAfterSuccessfulSend: (() -> Void)?
    @ObservationIgnored var afterSuccessfulSend: (() -> Void)?
    @ObservationIgnored private var completionDelivered = false
    init(draft: LocalDraft, accountName: String, isDemo: Bool, repository: any DraftRepository,
         submission: SubmissionService, imap: IMAPConfiguration?, google: GmailSubmission? = nil, grantAccess: @escaping @MainActor () async -> Void) {
        self.draft = draft; self.accountName = accountName; self.isDemo = isDemo; self.repository = repository
        self.submission = submission; self.imap = imap; self.google = google; self.grantAccess = grantAccess
    }
    var statusText: String {
        if busy { return "Vorgang läuft … Dieses Fenster bitte geöffnet lassen." }
        if saving { return "Entwurf wird gesichert …" }
        if dirty { return "Noch nicht gesichert" }
        switch draft.status {
        case .editing: return "Entwurf lokal verschlüsselt gesichert"
        case .sending: return "Versand läuft"
        case .failed: return "Server hat die Nachricht nicht angenommen. Du kannst sie bearbeiten und erneut senden."
        case .uncertain: return "Versand unklar. Nicht erneut senden. Prüfe den Gesendet-Ordner oder frage den Empfänger."
        case .accepted: return "Vom Mailserver angenommen. Die Gesendet-Kopie ist noch nicht bestätigt. Nicht erneut senden."
        case .sent: return "Vom Mailserver angenommen · Gesendet-Kopie bestätigt. Dies ist keine Zustellbestätigung."
        }
    }
    var signatureSelection: ComposerSignatureSelection {
        guard let content = draft.signature, content.enabled else { return .none }
        if let match = signatureLibrary.entries.first(where: {
            $0.id == draft.signatureID && $0.content == content && $0.name == draft.signatureName
        }) { return .saved(match.id) }
        return .snapshot
    }
    func loadSignatures() async {
        guard !Task.isCancelled else { return }
        if signaturesLoading { signatureReloadPending = true; return }
        signaturesLoading = true; defer { signaturesLoading = false }
        repeat {
            signatureReloadPending = false
            do { signatureLibrary = try await repository.signatureLibrary(account: draft.accountID); signatureError = nil }
            catch { signatureError = "Signaturen konnten nicht geladen werden." }
        } while signatureReloadPending && !Task.isCancelled
    }
    func loadRecipientHistory() async {
        guard !loadingRecipientHistory, let history = repository as? any RecipientHistoryRepository else { return }
        loadingRecipientHistory = true; defer { loadingRecipientHistory = false }
        if let loaded = try? await history.recipientHistory(), !Task.isCancelled { recipientHistory = loaded }
    }
    func otherRecipientAddresses(excluding path: WritableKeyPath<LocalDraft, String>) -> Set<String> {
        Set([\LocalDraft.to, \.cc, \.bcc].filter { $0 != path }.flatMap {
            draft[keyPath: $0].split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        })
    }
    func selectSignature(_ selection: ComposerSignatureSelection) {
        switch selection {
        case .none: change { $0.useSignature(nil) }
        case .saved(let id):
            guard let selected = signatureLibrary.entries.first(where: { $0.id == id }) else { return }
            change { $0.useSignature(selected) }
        case .snapshot: break
        }
    }
    func change(_ update: (inout LocalDraft) -> Void) {
        guard draft.status.editable, !busy else { return }
        update(&draft); dirty = true; generation += 1; message = nil
        reviewedDraft = nil
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)); guard let self else { return }; _ = await flush() }
            catch { }
        }
    }
    @discardableResult func flush() async -> Bool {
        if let saveTask { return await saveTask.value }
        let task = Task { @MainActor [self] in
            saving = true; defer { saving = false }
            while dirty {
                let version = generation, snapshot = draft
                do {
                    let saved = try await repository.saveDraft(snapshot, expectedRevision: snapshot.revision)
                    draft.revision = saved.revision; draft.modifiedAt = saved.modifiedAt
                    if generation == version { dirty = false }
                } catch { report(error); return false }
            }
            return true
        }
        saveTask = task
        let result = await task.value; saveTask = nil
        if result { NotificationCenter.default.post(name: .localDraftsDidChange, object: nil) }
        return result
    }
    func review() async -> Bool {
        guard !busy, !isDemo, draft.status.editable, imap != nil || google != nil else { return false }
        busy = true; defer { busy = false }
        reviewedDraft = nil
        guard await flush() else { return false }
        let snapshot = draft
        do {
            try draft.validateSubmission()
            if let google { try await google.review(account: draft.accountID) }
            else { guard try await repository.smtpProfile(account: draft.accountID) != nil else { throw ComposeFailure.missingConfiguration } }
            guard !dirty, draft == snapshot else { throw ComposeFailure.conflict }
            reviewedDraft = snapshot
            return true
        } catch { report(error); return false }
    }
    func send() async {
        // A confirmation is single-use and bound to the complete reviewed content.
        // MCP has no reference to this editor and cannot manufacture this state.
        guard !busy, !isDemo, imap != nil || google != nil, let reviewedDraft else { return }
        self.reviewedDraft = nil
        guard !dirty, draft == reviewedDraft else { report(ComposeFailure.conflict); return }
        busy = true; message = nil; defer { finishSubmission() }
        do {
            let references = draft.attachments
            let attachments = try await Task.detached { try references.map(Self.loadAttachment) }.value
            if let google { draft = try await google.send(id: draft.id, account: draft.accountID, expectedRevision: draft.revision, attachments: attachments) }
            else if let imap { draft = try await submission.send(id: draft.id, account: draft.accountID, expectedRevision: draft.revision, attachments: attachments, imap: imap) }
        } catch {
            // Reload the durable state even when recording a receipt failed.
            if let saved = try? await repository.draft(id: draft.id, account: draft.accountID) { draft = saved }
            report(error)
        }
    }
    /// The user's single Send click is the confirmation. Validation, autosave
    /// and exact-revision checks still run before contacting the mail server.
    func sendFromComposer() async {
        if await review() { await send() }
    }
    /// Only a durable provider acceptance closes an actively sending window.
    /// Opening an existing receipt, a rejection or an uncertain result stays visible.
    func finishSubmission() {
        busy = false
        NotificationCenter.default.post(name: .localDraftsDidChange, object: nil)
        guard !completionDelivered, !dirty, draft.status == .accepted || draft.status == .sent else { return }
        completionDelivered = true
        NotificationCenter.default.post(name: .mailSubmissionDidComplete, object: nil,
                                        userInfo: ["status": draft.status.rawValue])
        closeAfterSuccessfulSend?()
        afterSuccessfulSend?()
    }
    func beginAssistantDirectSend(_ expected: LocalDraft) throws {
        guard !isDemo, !busy, !dirty, !saving, draft == expected, draft.status.editable,
              window?.attachedSheet == nil else { throw ComposeFailure.conflict }
        reviewedDraft = nil; message = nil; busy = true
    }
    func reconcile() async {
        guard !busy, imap != nil || google != nil else { return }
        busy = true; defer { busy = false }
        do {
            if let google { draft = try await google.reconcile(id: draft.id, account: draft.accountID) }
            else if let imap { draft = try await submission.reconcile(id: draft.id, account: draft.accountID, imap: imap) }
            message = draft.status == .sent ? nil : "Noch keine bestätigte Gesendet-Kopie gefunden. Es wurde nichts erneut versendet."
        }
        catch { report(error) }
    }
    func completeSentCopy() async {
        guard !busy, let imap else { return }
        busy = true; defer { busy = false }
        do {
            let references = draft.attachments
            let attachments = try await Task.detached { try references.map(Self.loadAttachment) }.value
            draft = try await submission.completeSentCopy(id: draft.id, account: draft.accountID, imap: imap, attachments: attachments)
            message = draft.status == .sent ? nil : "Die Kopie ist noch nicht bestätigt. Es wurde keine Nachricht erneut versendet."
        } catch { report(error) }
    }
    func saveAtGoogle() async {
        guard let google, !busy, draft.status.editable else { return }
        busy = true; defer { busy = false }
        guard await flush() else { return }
        do {
            let references = draft.attachments
            let attachments = try await Task.detached { try references.map(Self.loadAttachment) }.value
            draft = try await google.saveAtGoogle(id: draft.id, account: draft.accountID, expectedRevision: draft.revision, attachments: attachments)
            message = "Entwurf bei Gmail gesichert. Lokales Verwerfen entfernt diese Kopie bei Gmail nicht."
        } catch {
            if let saved = try? await repository.draft(id: draft.id, account: draft.accountID) { draft = saved }
            report(error)
        }
    }
    func discard() async -> Bool {
        guard !busy else { return false }
        busy = true; defer { busy = false }
        guard await flush() else { return false }
        do { try await repository.discardDraft(id: draft.id, account: draft.accountID, expectedRevision: draft.revision); return true }
        catch { report(error); return false }
    }
    func saveConflictAsCopy() async {
        guard hasConflict, !busy else { return }
        busy = true; debounce?.cancel(); defer { busy = false }
        do {
            var copy = LocalDraft(accountID: draft.accountID, sender: draft.sender)
            copy.to = draft.to; copy.cc = draft.cc; copy.bcc = draft.bcc; copy.subject = draft.subject
            copy.body = draft.body; copy.quotation = draft.quotation; copy.sourceMessageID = draft.sourceMessageID; copy.signature = draft.signature; copy.signatureID = draft.signatureID; copy.signatureName = draft.signatureName
            copy.attachments = draft.attachments; copy.inReplyTo = draft.inReplyTo; copy.references = draft.references
            copy = try await repository.saveDraft(copy, expectedRevision: 0)
            let editor = ComposerEditor(draft: copy, accountName: accountName, isDemo: isDemo,
                repository: repository, submission: submission, imap: imap, google: google, grantAccess: grantAccess)
            ComposerWindows.shared.open(editor)
            draft = try await repository.draft(id: draft.id, account: draft.accountID)
            dirty = false; hasConflict = false; message = "Deine Änderungen wurden in einem getrennten Entwurf gesichert."
        } catch { report(error) }
    }
    func allowKeychain() async { await grantAccess(); keychainNeeded = false; message = "Schlüsselbundzugriff freigegeben. Starte den gewünschten Vorgang erneut." }
    func addAttachments() {
        guard !busy, draft.status.editable else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.prompt = "Anhängen"; panel.message = "Bis 20 MB insgesamt. Die App merkt sich nur den Dateizugriff; die Dateien müssen beim Versand unverändert verfügbar sein."
        panel.begin { [weak self] result in
            guard result == .OK, let self else { return }
            let urls = panel.urls
            Task { @MainActor in
                busy = true; defer { busy = false }
                do {
                    guard draft.attachments.count + urls.count <= 20 else { throw ComposeFailure.tooLarge }
                    let references = try await Task.detached { try urls.map(Self.reference) }.value
                    var updated = draft; updated.attachments += references; try updated.validateStorage()
                    busy = false; change { $0.attachments = updated.attachments }
                } catch { report(error) }
            }
        }
    }
    nonisolated private static func reference(_ url: URL) throws -> DraftAttachment {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try readFile(url)
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        let filename = url.lastPathComponent
        try ComposeValidation.header(filename)
        return DraftAttachment(filename: filename, mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", byteCount: data.count, bookmark: bookmark, digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    nonisolated static func loadAttachment(_ reference: DraftAttachment) throws -> OutgoingAttachment {
        do { return try resolveAttachment(reference) }
        catch let error as ComposeFailure { throw error }
        catch { throw ComposeFailure.attachmentUnavailable }
    }
    nonisolated private static func resolveAttachment(_ reference: DraftAttachment) throws -> OutgoingAttachment {
        var stale = false
        let url = try URL(resolvingBookmarkData: reference.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw ComposeFailure.attachmentUnavailable }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try readFile(url)
        guard data.count == reference.byteCount, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == reference.digest else { throw ComposeFailure.attachmentChanged }
        return OutgoingAttachment(reference: reference, data: data)
    }
    nonisolated private static func readFile(_ url: URL) throws -> Data {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size <= 20_000_000 else { throw ComposeFailure.tooLarge }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var result = Data()
        while let chunk = try handle.read(upToCount: min(65_536, 20_000_001 - result.count)), !chunk.isEmpty {
            result.append(chunk)
            guard result.count <= 20_000_000 else { throw ComposeFailure.tooLarge }
        }
        guard result.count == size else { throw ComposeFailure.attachmentChanged }
        return result
    }
    func report(_ error: any Error) {
        keychainNeeded = error is KeychainFailure
        hasConflict = (error as? ComposeFailure) == .conflict
        message = Self.safeError(error)
    }
    static func safeError(_ error: any Error) -> String {
        if error is GmailFailure || error is MailFailure { return InboxModel.networkError(error) }
        if error is KeychainFailure { return "Der Schlüsselbund benötigt einmalig deine Freigabe. Künftige lokale Updates behalten dieselbe App-Signatur." }
        switch error as? ComposeFailure {
        case .invalidAddress: return "Bitte reine E-Mail-Adressen eingeben, durch Komma getrennt. Anzeigenamen und internationale Adressteile werden noch nicht unterstützt."
        case .invalidHeader: return "Ein Adress-, Betreff- oder Anhangfeld enthält ungültige Zeichen. Bitte prüfen."
        case .missingRecipients: return "Bitte mindestens einen Empfänger eintragen."
        case .tooLarge: return "Grössenlimit erreicht: 256 KiB Text, 20 Anhänge / 20 MB; der Server kann ein kleineres Versandlimit setzen. Entwürfe zusammen: 10 MiB / 100 Einträge."
        case .conflict: return "Dieser Entwurf wurde bereits geändert. Deine Eingaben bleiben hier erhalten. Sichere sie als getrennten Entwurf, um beide Stände zu behalten."
        case .missingConfiguration: return "Bitte zuerst unter Einstellungen → Konten → Versand den SMTP-Zugang einrichten."
        case .missingCredential: return "Für diesen Versandserver fehlt das Passwort. Bitte in den Versandeinstellungen hinterlegen."
        case .attachmentChanged, .attachmentUnavailable: return "Ein Anhang fehlt oder wurde verändert. Entferne ihn und wähle die aktuelle Datei erneut aus."
        case .uncertain: return "Der Versandstatus ist unklar. Bitte nicht erneut senden; prüfe den Gesendet-Ordner."
        case .locked: return "Dieser Entwurf oder dieses Konto hat bereits einen laufenden bzw. ungeklärten Vorgang."
        case .accountMismatch: return "Absender und Konto passen nicht zusammen. Es wurde nichts versendet."
        default: return "Der Vorgang konnte nicht abgeschlossen werden. Prüfe Verbindung und Versandeinstellungen. Dein Entwurf bleibt erhalten."
        }
    }
}

@MainActor
final class ComposerWindows {
    static let shared = ComposerWindows()
    private var controllers: [UUID: ComposerController] = [:]
    var hasOpenWindows: Bool { !controllers.isEmpty }
    func beginAssistantDirectSend(_ draft: LocalDraft) throws -> ComposerEditor? {
        let editor = controllers[draft.id]?.editor
        try editor?.beginAssistantDirectSend(draft)
        return editor
    }
    func openAssistantReview(_ editor: ComposerEditor) throws {
        if let existing = controllers[editor.draft.id]?.editor {
            guard !existing.busy, !existing.dirty, !existing.saving, existing.draft == editor.draft else { throw ComposeFailure.conflict }
        } else {
            guard controllers.values.filter({ $0.editor.draft.assistantOrigin != nil }).count < 3 else { throw ComposeFailure.locked }
        }
        open(editor)
    }
    func open(_ editor: ComposerEditor) {
        if let existing = controllers[editor.draft.id] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = ComposerController(editor: editor)
        controllers[editor.draft.id] = controller
        controller.onClose = { [weak self] in self?.controllers.removeValue(forKey: editor.draft.id) }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func flushAll() async -> Bool {
        for controller in Array(controllers.values) {
            guard !controller.editor.busy, await controller.editor.flush() else { controller.window?.makeKeyAndOrderFront(nil); return false }
        }
        return true
    }
}

@MainActor
final class ComposerController: NSWindowController, NSWindowDelegate {
    let editor: ComposerEditor
    var onClose: (() -> Void)?
    private var canClose = false
    init(editor: ComposerEditor) {
        self.editor = editor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: editor.draft.quotation == nil ? 720 : 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Nachricht · \(editor.accountName)"; window.identifier = NSUserInterfaceItemIdentifier("composer-\(editor.draft.id)")
        window.minSize = NSSize(width: 640, height: 600); window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self; editor.window = window
        editor.closeAfterSuccessfulSend = { [weak self] in
            self?.canClose = true
            self?.close()
        }
        window.contentView = NSHostingView(rootView: ComposerView(editor: editor, closeAfterDiscard: { [weak self] in self?.canClose = true; self?.close() }))
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if canClose { return true }
        guard !editor.busy else { editor.message = "Bitte warte, bis der laufende Vorgang abgeschlossen ist."; return false }
        Task { if await editor.flush() { canClose = true; close() } }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .localDraftsDidChange, object: nil)
        onClose?()
    }
}
