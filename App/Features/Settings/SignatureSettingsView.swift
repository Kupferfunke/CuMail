import SwiftUI
import MailDomain
import MailApplication
import MailRendering
import UniformTypeIdentifiers

struct SignatureFormEntry: Identifiable {
    var id: UUID
    var name: String
    var html: String
}
struct SignatureForm {
    var entries: [SignatureFormEntry] = []
    var defaultID: UUID?

    func uniqueName(_ proposed: String) -> String {
        let base = String(proposed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        let stem = base.isEmpty ? "Signatur" : base
        let existing = Set(entries.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var name = stem, number = 2
        while existing.contains(name.lowercased()) { name = "\(stem) \(number)"; number += 1 }
        return name
    }

    mutating func append(name: String, html: String) throws -> UUID {
        guard entries.count < 20 else { throw SignatureEditingFailure.tooMany }
        let item = SignatureFormEntry(id: UUID(), name: uniqueName(name), html: html)
        entries.append(item)
        if defaultID == nil { defaultID = item.id }
        return item.id
    }

    func validatedLibrary() throws -> SignatureLibrary {
        var names = Set<String>()
        let validated = try entries.map { item -> NamedMailSignature in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80, (try? ComposeValidation.header(name)) != nil else { throw SignatureEditingFailure.name }
            guard names.insert(name.lowercased()).inserted else { throw SignatureEditingFailure.duplicateName }
            guard !item.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SignatureEditingFailure.empty }
            guard item.html.utf8.count <= 32768 else { throw SignatureEditingFailure.tooLarge }
            let content: MailSignature
            do { content = try MailSignature(html: item.html) }
            catch { throw SignatureEditingFailure.html }
            guard !content.html.isEmpty else { throw SignatureEditingFailure.empty }
            return NamedMailSignature(id: item.id, name: name, content: content)
        }
        let result = SignatureLibrary(entries: validated, defaultID: defaultID)
        try result.validate()
        return result
    }
}

enum SignatureEditingFailure: Error, LocalizedError, Equatable {
    case name, duplicateName, empty, tooLarge, tooMany, html, unreadable, encoding
    var errorDescription: String? {
        switch self {
        case .name: "Jede Signatur braucht einen Namen mit höchstens 80 Zeichen, ohne Zeilenumbrüche."
        case .duplicateName: "Zwei Signaturen haben denselben Namen. Bitte benenne eine davon um."
        case .empty: "Eine Signatur ist leer. Füge Inhalt ein oder entferne den leeren Eintrag."
        case .tooLarge: "Die HTML-Datei oder Signatur ist zu gross. Erlaubt sind höchstens 32 KiB."
        case .tooMany: "Pro Konto sind bis zu 20 Signaturen möglich. Entferne zuerst einen nicht mehr benötigten Eintrag."
        case .html: "Dieses HTML konnte nicht als Signatur übernommen werden. Bitte prüfe den Inhalt."
        case .unreadable: "Diese Datei konnte nicht gelesen werden. Wähle eine lokale HTML-Datei (.html oder .htm)."
        case .encoding: "Die Datei ist nicht als UTF-8 oder UTF-16 lesbar. Bitte exportiere sie in einem dieser Formate."
        }
    }
}

enum SignatureHTMLFile {
    static func read(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL, ["html", "htm"].contains(url.pathExtension.lowercased()) else { throw SignatureEditingFailure.unreadable }
        do {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true else { throw SignatureEditingFailure.unreadable }
            guard let size = info.fileSize, size <= 32768 else { throw SignatureEditingFailure.tooLarge }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            // Bound the read as well as the size check: the file may change after selection.
            var data = Data()
            while data.count <= 32768, let part = try file.read(upToCount: 32769 - data.count), !part.isEmpty { data.append(part) }
            guard data.count <= 32768 else { throw SignatureEditingFailure.tooLarge }
            let decoded: String?
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { decoded = String(data: data, encoding: .utf16) }
            else { decoded = String(data: data, encoding: .utf8) }
            guard let decoded else { throw SignatureEditingFailure.encoding }
            let html = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
            guard html.utf8.count <= 32768 else { throw SignatureEditingFailure.tooLarge }
            let signature: MailSignature
            do { signature = try MailSignature(html: html) }
            catch { throw SignatureEditingFailure.html }
            guard !signature.html.isEmpty else { throw SignatureEditingFailure.empty }
            // Keep the selected source for editing; saving performs the same sanitization.
            return html
        } catch let error as SignatureEditingFailure { throw error }
        catch { throw SignatureEditingFailure.unreadable }
    }
}

struct SignatureSettingsView: View {
    @Bindable var model: InboxModel
    @Environment(\.colorScheme) private var scheme
    @ViewState private var selected: AccountID?
    @ViewState private var forms: [AccountID: SignatureForm] = [:]
    @ViewState private var selections: [AccountID: UUID] = [:]
    @ViewState private var dirty: Set<AccountID> = []
    @ViewState private var busy = false
    @ViewState private var notice: String?
    @ViewState private var failed = false
    @ViewState private var preview: SafeMailHTML?
    @ViewState private var removing: UUID?
    @ViewState private var importing = false
    @ViewState private var resetting = false

    private var form: SignatureForm { selected.flatMap { forms[$0] } ?? SignatureForm() }
    private var selectedID: UUID? { selected.flatMap { selections[$0] } ?? form.entries.first?.id }
    private var entry: SignatureFormEntry? { form.entries.first { $0.id == selectedID } }
    private func field(_ key: WritableKeyPath<SignatureFormEntry, String>) -> Binding<String> {
        Binding(get: { entry?[keyPath: key] ?? "" }, set: { value in
            guard let account = selected, var updated = forms[account], let index = updated.entries.firstIndex(where: { $0.id == selectedID }) else { return }
            updated.entries[index][keyPath: key] = value
            forms[account] = updated; dirty.insert(account); notice = nil; failed = false
        })
    }
    private var signatureSelection: Binding<UUID?> {
        Binding(get: { selectedID }, set: { value in if let account = selected { selections[account] = value; notice = nil } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Deine Signaturen.").font(Brand.headline(25))
                if model.accounts.isEmpty {
                    ContentUnavailableView("Noch kein Konto", systemImage: "signature", description: Text("Verbinde zuerst ein Postfach unter «Konten»."))
                } else {
                    Picker("Postfach", selection: $selected) {
                        ForEach(model.accounts) { account in Text(account.address.value).tag(Optional(account.id)) }
                    }.accessibilityIdentifier("signature-account")
                    if busy { ProgressView("Signaturen werden verarbeitet …").controlSize(.small) }
                    if selected.flatMap({ forms[$0] }) == nil, !busy {
                        HStack {
                            Text(notice ?? "Signaturen werden geladen …").font(.system(size: 12)).foregroundStyle(.secondary)
                            if failed { Button("Erneut laden") { Task { await load() } }.accessibilityIdentifier("signature-retry") }
                        }
                    }
                    HStack {
                        Picker("Signatur", selection: signatureSelection) {
                            if form.entries.isEmpty { Text("Noch keine Signatur").tag(UUID?.none) }
                            ForEach(form.entries) { item in
                                Text(item.name + (item.id == form.defaultID && item.name != "Standard" ? " · Standard" : "")).tag(Optional(item.id))
                            }
                        }.accessibilityIdentifier("signature-choice")
                        Button { add(copy: false) } label: { Image(systemName: "plus") }
                            .help("Neue Signatur").accessibilityLabel("Neue Signatur").accessibilityIdentifier("signature-add")
                            .disabled(form.entries.count >= 20)
                        Button { add(copy: true) } label: { Image(systemName: "doc.on.doc") }
                            .help("Signatur duplizieren").accessibilityLabel("Signatur duplizieren").accessibilityIdentifier("signature-duplicate")
                            .disabled(entry == nil || form.entries.count >= 20)
                        Button { removing = selectedID } label: { Image(systemName: "minus") }
                            .help("Signatur entfernen").accessibilityLabel("Signatur entfernen").accessibilityIdentifier("signature-remove")
                            .disabled(entry == nil)
                    }
                    HStack {
                        Button("HTML-Datei importieren …") { importing = true }
                            .accessibilityIdentifier("signature-import")
                            .help("Fügt die gewählte HTML-Datei als neue Signatur hinzu")
                            .disabled(selected.flatMap({ forms[$0] }) == nil || form.entries.count >= 20)
                        Spacer()
                        if let selected, dirty.contains(selected) {
                            Button("Änderungen verwerfen …") { resetting = true }
                                .accessibilityIdentifier("signature-reset")
                        }
                    }
                    if let entry {
                        HStack {
                            TextField("Name, z. B. Geschäftlich", text: field(\.name))
                                .accessibilityLabel("Name der Signatur").accessibilityIdentifier("signature-name")
                            if form.defaultID == entry.id {
                                Label("Standard", systemImage: "star.fill").font(.system(size: 11)).foregroundStyle(Brand.accent(scheme))
                            } else {
                                Button("Als Standard") { updateDefault(entry.id) }.accessibilityIdentifier("signature-set-default")
                            }
                        }
                        HStack {
                            Text("HTML-Signatur").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("Bis 32 KiB · Vorschau darunter").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        TextEditor(text: field(\.html)).font(.system(size: 11, design: .monospaced))
                            .frame(height: 100).scrollContentBackground(.hidden).padding(8)
                            .background(Brand.surface(scheme), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.2)))
                            .accessibilityLabel("HTML-Signatur").accessibilityIdentifier("signature-html")
                        if let preview {
                            SignaturePreview(html: preview).frame(height: 100)
                        } else {
                            Text(entry.html.isEmpty ? "Füge deine Signatur als HTML ein. Formatierungen, Links und Tabellen werden unterstützt." : "Die Vorschau konnte nicht erstellt werden.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                        }
                    } else {
                        ContentUnavailableView("Dein eigener Abschluss", systemImage: "signature", description: Text("Mit + legst du deine erste Signatur an. Sie wird automatisch der Standard für dieses Konto."))
                    }
                    HStack {
                        Text(notice ?? (selected.map { dirty.contains($0) } == true ? "Änderungen noch nicht gesichert." : "Externe Bilder werden in der Vorschau nicht geladen."))
                            .font(.system(size: 11)).foregroundStyle(failed ? Color.red : Color.secondary).lineLimit(2)
                        Spacer()
                        Button("Sichern") { Task { await save() } }
                            .buttonStyle(.borderedProminent).disabled(selected == nil || selected.map { !dirty.contains($0) } == true)
                            .accessibilityIdentifier("signature-save")
                    }
                    Text("Der Standard wird bei neuen Nachrichten und Antworten eingefügt. Im Mailfenster kannst du eine andere oder «Keine Signatur» wählen. Bestehende Entwürfe behalten ihre Signatur.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if dirty.contains(where: { $0 != selected }) {
                        Text("Auch in anderen Postfächern sind noch Änderungen offen. Wähle das jeweilige Postfach und sichere sie dort.")
                            .font(.system(size: 11)).foregroundStyle(Brand.accent(scheme))
                    }
                }
            }.padding(20).disabled(busy)
        }
        .task { if selected == nil { selected = model.accounts.first?.id }; await load() }
        .onChange(of: selected) { _, _ in Task { await load() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.html], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { Task { await importFile(url) } }
            else if case .failure = result { notice = SignatureEditingFailure.unreadable.errorDescription; failed = true }
        }
        .task(id: entry?.html) {
            preview = nil
            do {
                try await Task.sleep(for: .milliseconds(200))
                let html = entry?.html ?? ""
                guard html.utf8.count <= 32768 else { preview = nil; return }
                preview = html.isEmpty ? nil : try MailHTMLSanitizer.signature(html)
            } catch is CancellationError {} catch { preview = nil }
        }
        .alert("Signatur entfernen?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Abbrechen", role: .cancel) { removing = nil }
            Button("Entfernen", role: .destructive) { remove() }
        } message: { Text("Die Änderung wird mit «Sichern» übernommen. Bereits begonnene Nachrichten behalten ihre Signatur. Bei Bedarf wird die erste verbleibende Signatur zum Standard.") }
        .confirmationDialog("Ungesicherte Signaturänderungen dieses Postfachs verwerfen?", isPresented: $resetting, titleVisibility: .visible) {
            Button("Gespeicherten Stand laden", role: .destructive) {
                if let selected { forms[selected] = nil; dirty.remove(selected); Task { await load() } }
            }
            Button("Abbrechen", role: .cancel) { }
        } message: { Text("Die zuletzt gesicherten Signaturen werden wieder angezeigt. Andere Postfächer und bestehende Entwürfe bleiben erhalten.") }
    }
    private func load() async {
        guard let account = selected else { return }
        notice = nil; failed = false
        guard forms[account] == nil, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let library = try await model.signatureLibrary(account: account)
            forms[account] = SignatureForm(entries: library.entries.map { SignatureFormEntry(id: $0.id, name: $0.name, html: $0.content.html) }, defaultID: library.defaultID)
            selections[account] = library.defaultID ?? library.entries.first?.id
        } catch { notice = "Die Signaturen konnten nicht geladen werden."; failed = true }
    }
    private func add(copy: Bool) {
        guard let account = selected, var updated = forms[account], updated.entries.count < 20 else { return }
        let base = copy ? String((entry?.name ?? "Signatur").prefix(50)) + " Kopie" : "Signatur"
        guard let id = try? updated.append(name: base, html: copy ? entry?.html ?? "" : "") else { return }
        forms[account] = updated; selections[account] = id; dirty.insert(account); notice = nil; failed = false
    }
    private func importFile(_ url: URL) async {
        guard let account = selected, forms[account] != nil, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let html = try await Task.detached { try SignatureHTMLFile.read(url) }.value
            guard var updated = forms[account] else { return }
            let name = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: #"^\d+[-_ ]+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            let id = try updated.append(name: name, html: html)
            forms[account] = updated; selections[account] = id; dirty.insert(account)
            notice = "Datei als neue Signatur importiert. Mit «Sichern» übernehmen."; failed = false
        } catch { notice = (error as? SignatureEditingFailure)?.errorDescription ?? "Die Datei konnte nicht importiert werden."; failed = true }
    }
    private func updateDefault(_ id: UUID) {
        guard let account = selected else { return }
        forms[account]?.defaultID = id; dirty.insert(account); notice = nil
    }
    private func remove() {
        guard let account = selected, let id = removing, var updated = forms[account] else { return }
        updated.entries.removeAll { $0.id == id }
        if updated.defaultID == id { updated.defaultID = updated.entries.first?.id }
        forms[account] = updated; selections[account] = updated.defaultID ?? updated.entries.first?.id
        dirty.insert(account); removing = nil; notice = nil
    }
    private func save() async {
        guard let account = selected, let pending = forms[account] else { return }
        busy = true; defer { busy = false }
        do {
            let library = try pending.validatedLibrary()
            try await model.saveSignatureLibrary(library, account: account)
            forms[account] = SignatureForm(entries: library.entries.map { SignatureFormEntry(id: $0.id, name: $0.name, html: $0.content.html) }, defaultID: library.defaultID)
            dirty.remove(account); notice = "Signaturen und Standard für dieses Postfach gesichert."; failed = false
        } catch { notice = (error as? SignatureEditingFailure)?.errorDescription ?? "Die Signaturen konnten nicht gesichert werden. Deine Änderungen bleiben hier erhalten. Bitte erneut versuchen."; failed = true }
    }
}

struct SignaturePreview: View {
    let html: SafeMailHTML
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        SafeMailWebView(html: html, dark: false, allowRemoteImages: false, openLink: { _ in }, failed: {})
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Signaturvorschau")
    }
}
