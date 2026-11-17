import AppKit
import SwiftUI
import Observation
import QuickLookUI
import MailDomain
import MailApplication
import MailPersistence
import MailDemo

struct PreparedAttachment: Identifiable {
    let id = UUID()
    let metadata: AttachmentMetadata
    let lease: TemporaryLease
    let isDemo: Bool
    var canPreview: Bool { ["pdf", "png", "jpg", "txt"].contains(lease.url.pathExtension) }
}

@MainActor @Observable
final class AttachmentController {
    typealias Downloader = @Sendable (AttachmentRequest, @escaping AttachmentSink, @escaping AttachmentProgress) async throws -> Void
    var selected: AttachmentID?
    var busy = false
    var received: Int64 = 0
    var expected: Int64?
    var status: String?
    var failed = false
    var prepared: PreparedAttachment?
    var exporting = false
    @ObservationIgnored private let store: ManagedTemporaryStore
    @ObservationIgnored private let download: Downloader
    @ObservationIgnored private let storageChanged: @MainActor () async -> Void
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var heldLease: TemporaryLease?
    @ObservationIgnored private var savePanel: NSSavePanel?

    init(store: ManagedTemporaryStore, storageChanged: @escaping @MainActor () async -> Void = {}, download: @escaping Downloader) { self.store = store; self.storageChanged = storageChanged; self.download = download }

    func open(message: MailMessage, attachment: AttachmentMetadata, scope: AccessScope, isDemo: Bool) {
        guard !busy, !exporting, !stopping, heldLease == nil else { return }
        selected = attachment.id; received = 0; expected = nil; status = nil; failed = false
        let request: AttachmentRequest
        do { request = try AttachmentRequest(message: message, attachment: attachment, scope: scope) }
        catch { status = Self.errorText(error); failed = true; return }
        let id = UUID(); operation = id; busy = true
        task = Task { [self] in
            var writing: TemporaryDownload?
            do {
                let job = try await store.beginDownload(account: message.accountID, maximumBytes: AttachmentRequest.byteLimit)
                writing = job
                let sink: AttachmentSink = { [store] in try await store.append($0, to: job) }
                let progress: AttachmentProgress = { [weak self] received, expected in
                    await self?.update(id: id, received: received, expected: expected)
                }
                if isDemo { try await SyntheticAttachmentSource().download(request, sink: sink, progress: progress) }
                else { try await download(request, sink, progress) }
                try Task.checkCancellation()
                let lease = try await store.finish(job, mimeType: attachment.mimeType)
                writing = nil
                guard operation == id, !Task.isCancelled else { try await store.discard(lease); throw CancellationError() }
                heldLease = lease
                prepared = PreparedAttachment(metadata: attachment, lease: lease, isDemo: isDemo)
                status = "Temporär geladen. Schliessen entfernt die interne Datei."
            } catch {
                if let writing { try? await store.abort(writing) }
                if operation == id { failed = !(error is CancellationError); status = Self.errorText(error) }
            }
            if operation == id { await storageChanged(); busy = false }
        }
    }
    private func update(id: UUID, received: Int64, expected: Int64?) {
        guard operation == id else { return }
        self.received = received; self.expected = expected
    }
    func cancel() { task?.cancel(); status = "Download wird abgebrochen …" }
    func closePreview() {
        guard !exporting, !stopping else { return }
        prepared = nil
        guard let lease = heldLease else { return }
        heldLease = nil; busy = true
        task = Task {
            do { try await store.discard(lease) }
            catch { failed = true; status = "Die temporäre Datei konnte noch nicht entfernt werden. Die Bereinigung versucht es erneut." }
            await storageChanged(); busy = false
        }
    }
    func stopAndWait() async {
        guard !stopping else { return }
        stopping = true; defer { stopping = false }
        savePanel?.cancel(nil); savePanel = nil
        let old = task; operation = UUID(); busy = true; prepared = nil
        old?.cancel(); await old?.value
        busy = false; exporting = false
        if let lease = heldLease { heldLease = nil; try? await store.discard(lease) }
        await storageChanged()
    }
    func save() {
        guard let item = prepared, !exporting else { return }
        let panel = NSSavePanel(); savePanel = panel; exporting = true
        panel.nameFieldStringValue = AttachmentSafety.filename(item.metadata.filename)
        panel.title = "Anhang sichern"; panel.prompt = "Sichern"
        panel.canCreateDirectories = true
        panel.message = "Die gewählte Datei bleibt als Benutzerexport erhalten."
        panel.begin { [weak self] response in
            guard let self else { return }
            self.savePanel = nil
            guard response == .OK, let url = panel.url else { self.exporting = false; return }
            self.task = Task {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() }; self.exporting = false }
                do {
                    let worker = Task.detached { try AttachmentExporter.export(source: item.lease.url, destination: url) }
                    try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    self.failed = false; self.status = "Anhang am gewählten Ort gesichert."
                } catch { self.failed = true; self.status = Self.errorText(error) }
            }
        }
    }
    static func errorText(_ error: any Error) -> String {
        if error is CancellationError { return "Download abgebrochen. Unvollständige Dateien werden entfernt." }
        switch error as? AttachmentFailure {
        case .tooLarge: return "Dieser Anhang überschreitet das Downloadlimit von 8 MiB. Bei IMAP zählt die Übertragungskodierung mit."
        case .changed: return "Der Anhang hat sich auf dem Server geändert. Bitte zuerst synchronisieren."
        case .invalidData: return "Die Anhangdaten sind unvollständig oder ungültig."
        case .unsupportedEncoding: return "Diese Anhangkodierung wird noch nicht unterstützt."
        case .previewUnavailable: return "Für diesen Dateityp ist hier keine Vorschau verfügbar."
        case .busy: return "Ein Anhang wird bereits geladen."
        default: break
        }
        if error is LocalStoreFailure { return "Die temporäre Datei konnte nicht sicher angelegt werden oder das Speicherbudget ist belegt." }
        if error is CocoaError { return "Die Datei konnte am gewählten Ort nicht gesichert werden. Bitte den Zielordner prüfen." }
        return InboxModel.networkError(error)
    }
}

struct AttachmentSheet: View {
    @Bindable var controller: AttachmentController
    let item: PreparedAttachment
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AttachmentSafety.filename(item.metadata.filename)).font(Brand.headline(23)).lineLimit(2)
            Text(item.isDemo ? "Synthetischer Testanhang · kein Originaldokument" : "Temporäre Vorschau · keine Änderung an der Nachricht")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if item.canPreview { AttachmentQuickLook(url: item.lease.url).frame(minHeight: 320).accessibilityIdentifier("attachment-preview") }
            else { ContentUnavailableView("Keine Vorschau", systemImage: "doc", description: Text("Du kannst diesen Dateityp über «Sichern unter …» speichern.")) }
            if let status = controller.status { Text(status).font(.system(size: 12)).foregroundStyle(controller.failed ? Color.red : .secondary).accessibilityIdentifier("attachment-status") }
            HStack {
                Text("Interne Datei wird beim Schliessen entfernt.").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Schliessen") { controller.closePreview() }.keyboardShortcut(.cancelAction).disabled(controller.exporting).accessibilityIdentifier("attachment-close")
                Button("Sichern unter …") { controller.save() }.disabled(controller.exporting).accessibilityIdentifier("attachment-save")
            }
        }.padding(24).frame(width: 660, height: 530).interactiveDismissDisabled(controller.exporting)
    }
}

private struct AttachmentQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false; view.shouldCloseWithWindow = true; view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL } }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.previewItem = nil; view.close() }
}
