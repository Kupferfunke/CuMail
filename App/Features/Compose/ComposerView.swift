import SwiftUI
import AppKit
import MailRendering
import MailApplication
import MailDomain

struct ComposerView: View {
    @Bindable var editor: ComposerEditor
    let closeAfterDiscard: () -> Void
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @ViewState private var confirmingDiscard = false
    @ViewState private var quotationExpanded = true
    @ViewState private var quotationHeight: CGFloat = 220
    @ViewState private var quotationFailed = false
    private func field(_ path: WritableKeyPath<LocalDraft, String>) -> Binding<String> {
        Binding(get: { editor.draft[keyPath: path] }, set: { value in editor.change { $0[keyPath: path] = value } })
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 7) {
                    Eyebrow(text: editor.isDemo ? "DEMO · ENTWURF" : editor.draft.assistantOrigin != nil ? "KI-NACHRICHT · DEINE FREIGABE" : "DEINE WORTE. DEIN ABSENDER.").foregroundStyle(Brand.accent(scheme))
                    Text(composerTitle).font(Brand.headline(26))
                }
                Spacer()
                Button { Task { await editor.sendFromComposer() } } label: {
                    Label("Senden", systemImage: "paperplane.fill")
                }.buttonStyle(.borderedProminent).tint(Brand.accent(scheme)).foregroundStyle(scheme == .dark ? Brand.ink : Brand.paper)
                    .disabled(editor.isDemo || editor.busy || !editor.draft.status.editable)
                    .accessibilityIdentifier("compose-send")
                    .keyboardShortcut(.return, modifiers: [.command])
            }.padding(24)
            Divider()
            if editor.draft.assistantOrigin != nil && editor.draft.status.editable {
                Text("Von deinem Assistenten vorbereitet. Prüfe Empfänger und Text. Mit «Senden» verschickst du diese Nachricht.")
                    .font(.system(size: 12)).foregroundStyle(Brand.secondary(scheme)).padding(.horizontal, 24).padding(.top, 14)
                    .accessibilityIdentifier("compose-assistant-review")
            }
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Von").frame(width: 55, alignment: .leading).foregroundStyle(Brand.secondary(scheme))
                    Text(editor.draft.sender).fontWeight(.semibold).textSelection(.enabled).accessibilityIdentifier("compose-sender")
                    Text("· \(editor.accountName)").foregroundStyle(Brand.secondary(scheme))
                    Spacer()
                }
                recipientRow("An", field: \.to, id: "compose-to")
                recipientRow("Cc", field: \.cc, id: "compose-cc")
                recipientRow("Bcc", field: \.bcc, id: "compose-bcc")
                row("Betreff", field: \.subject, id: "compose-subject")
            }.padding(.horizontal, 24).padding(.vertical, 18).zIndex(1)
            Divider()
            if editor.draft.status == .sent {
                VStack(spacing: 16) {
                    Image(systemName: "paperplane.circle").font(.system(size: 48, weight: .light)).foregroundStyle(Brand.accent(scheme))
                    Text("Deine Nachricht ist unterwegs.").font(Brand.headline(25))
                    Text("Die lokale Entwurfskopie wurde entfernt.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let quotation = editor.draft.quotation {
                ScrollView {
                    VStack(spacing: 0) {
                        bodyEditor.frame(height: 200)
                        signatureSection
                        quotationSection(quotation)
                    }
                }.background(Brand.surface(scheme)).accessibilityIdentifier("compose-content-scroll")
            } else {
                bodyEditor
                signatureSection
            }
            if !editor.draft.attachments.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(editor.draft.attachments) { file in
                            HStack {
                                Image(systemName: "paperclip")
                                Text(file.filename).lineLimit(1)
                                Text(file.byteCount.formatted(.byteCount(style: .file))).foregroundStyle(.secondary)
                                Spacer()
                                Button { editor.change { $0.attachments.removeAll { $0.id == file.id } } } label: { Image(systemName: "xmark.circle") }
                                    .accessibilityLabel("\(file.filename) entfernen").disabled(editor.busy || !editor.draft.status.editable)
                            }.font(.system(size: 12))
                        }
                    }.padding(.horizontal, 24).padding(.vertical, 10)
                }.frame(maxHeight: 100)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button { editor.addAttachments() } label: { Label("Datei anhängen …", systemImage: "paperclip") }
                        .disabled(editor.busy || !editor.draft.status.editable).accessibilityIdentifier("compose-attachment")
                    Spacer()
                    if [.accepted, .uncertain].contains(editor.draft.status) {
                        Button("Gesendet-Kopie prüfen") { Task { await editor.reconcile() } }.disabled(editor.busy).accessibilityIdentifier("compose-reconcile")
                        if !editor.isGoogle && editor.draft.status == .accepted && !editor.draft.appendAttempted {
                            Button("Fehlende Kopie ablegen") { Task { await editor.completeSentCopy() } }.disabled(editor.busy)
                                .help("Legt nur die bereits angenommene Nachricht in Gesendet ab; kein erneuter Versand.")
                        }
                    }
                    if editor.draft.status.editable {
                        Button("Verwerfen …", role: .destructive) { confirmingDiscard = true }.disabled(editor.busy)
                    }
                    if editor.isGoogle && editor.draft.status.editable {
                        Button("Bei Gmail sichern") { Task { await editor.saveAtGoogle() } }.disabled(editor.busy).accessibilityIdentifier("compose-google-save")
                    }
                    Button("Sichern") { Task { _ = await editor.flush() } }.disabled(!editor.dirty || editor.busy).accessibilityIdentifier("compose-save")
                }
                Label(editor.statusText, systemImage: editor.draft.status == .sent ? "checkmark.circle" : "lock.doc")
                    .font(.system(size: 11)).foregroundStyle(Brand.secondary(scheme)).accessibilityIdentifier("compose-status")
                if editor.isDemo { Text("Demoabsender: Entwürfe testen, ohne Nachrichten zu versenden.").font(.system(size: 11)).foregroundStyle(.secondary) }
                if let message = editor.message {
                    Text(message).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("compose-error")
                }
                if editor.keychainNeeded { Button("Schlüsselbund freigeben") { Task { await editor.allowKeychain() } } }
                if editor.hasConflict { Button("Änderungen als getrennten Entwurf sichern") { Task { await editor.saveConflictAsCopy() } }.disabled(editor.busy) }
            }.padding(20)
        }.background(Brand.canvas(scheme)).foregroundStyle(Brand.text(scheme)).tint(Brand.accent(scheme))
            .task { await editor.loadSignatures(); await editor.loadRecipientHistory() }
            .onReceive(NotificationCenter.default.publisher(for: .mailSubmissionDidComplete)) { _ in Task { await editor.loadRecipientHistory() } }
            .onReceive(NotificationCenter.default.publisher(for: .signaturesDidChange)) { notification in
                if notification.userInfo?["account"] as? String == editor.draft.accountID.description { Task { await editor.loadSignatures() } }
            }
            .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
            .alert("Diesen lokalen Entwurf verwerfen?", isPresented: $confirmingDiscard) {
                Button("Abbrechen", role: .cancel) { }
                Button("Verwerfen", role: .destructive) { Task { if await editor.discard() { closeAfterDiscard() } } }
            } message: { Text("Nur dieser eigene Entwurf wird entfernt. Dateien und Nachrichten auf dem Mailserver bleiben erhalten.") }
    }
    private var bodyEditor: some View {
        TextEditor(text: field(\.body))
            .font(.system(size: 14)).scrollContentBackground(.hidden)
            .padding(20).background(Brand.surface(scheme))
            .disabled(!editor.draft.status.editable || editor.busy)
            .accessibilityLabel("Nachrichtentext").accessibilityIdentifier("compose-body")
    }
    private var composerTitle: String {
        if let origin = editor.draft.assistantOrigin { return origin.messageID == nil ? "Nachricht prüfen" : "Antwort prüfen" }
        if let quotation = editor.draft.quotation { return quotation.heading.hasPrefix("Weitergeleitete") ? "Weiterleiten" : "Antwort schreiben" }
        return editor.draft.inReplyTo == nil ? "Neue Nachricht" : "Antwort schreiben"
    }
    private var signatureSection: some View {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Signatur", selection: Binding(get: { editor.signatureSelection }, set: editor.selectSignature)) {
                        Text("Keine Signatur").tag(ComposerSignatureSelection.none)
                        if editor.signatureSelection == .snapshot {
                            Text((editor.draft.signatureName ?? "Gespeicherte Signatur") + " · im Entwurf")
                                .tag(ComposerSignatureSelection.snapshot)
                        }
                        ForEach(editor.signatureLibrary.entries) { signature in
                            Text(signature.name + (signature.id == editor.signatureLibrary.defaultID && signature.name != "Standard" ? " · Standard" : ""))
                                .tag(ComposerSignatureSelection.saved(signature.id))
                        }
                    }.font(.system(size: 12)).disabled(editor.busy || editor.signaturesLoading || !editor.draft.status.editable)
                        .accessibilityIdentifier("compose-signature-picker")
                    if let error = editor.signatureError {
                        HStack { Text(error).foregroundStyle(.red); Button("Erneut laden") { Task { await editor.loadSignatures() } } }
                            .font(.system(size: 11))
                    }
                    if let signature = editor.draft.signature, signature.enabled, let preview = try? MailHTMLSanitizer.signature(signature.html) {
                        SignaturePreview(html: preview).frame(height: 95)
                    }
                }.padding(.horizontal, 24).padding(.vertical, 8)
    }
    private func quotationSection(_ quotation: DraftQuotation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { quotationExpanded.toggle() } label: {
                    Label("Ursprüngliche Nachricht", systemImage: quotationExpanded ? "chevron.down" : "chevron.right")
                }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .accessibilityIdentifier("compose-quotation-toggle")
                Spacer()
                Button { editor.change { $0.quotation = nil } } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).help("Ursprüngliche Nachricht aus dieser Antwort entfernen")
                    .accessibilityLabel("Ursprüngliche Nachricht entfernen").accessibilityIdentifier("compose-quotation-remove")
                    .disabled(editor.busy || !editor.draft.status.editable)
            }.foregroundStyle(Brand.secondary(scheme))
            if quotationExpanded {
                Text(quotation.heading).font(.system(size: 11)).foregroundStyle(Brand.secondary(scheme))
                if quotationFailed {
                    Text(quotation.plainText).font(.system(size: 13)).textSelection(.enabled)
                    Text("Die Vorschau ist momentan nicht verfügbar. Die Formatierung bleibt für den Versand erhalten.")
                        .font(.system(size: 11)).foregroundStyle(Brand.secondary(scheme))
                } else {
                    SafeMailWebView(html: quotation.html.preview, dark: false, allowRemoteImages: !editor.isDemo,
                        openLink: { NSWorkspace.shared.open($0) }, failed: { quotationFailed = true },
                        heightChanged: { quotationHeight = $0 })
                        .frame(height: quotationHeight).background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("compose-quotation-html")
                }
            }
        }.padding(24)
    }
    private func row(_ label: String, field path: WritableKeyPath<LocalDraft, String>, id: String) -> some View {
        HStack {
            Text(label).frame(width: 55, alignment: .leading).foregroundStyle(Brand.secondary(scheme))
            TextField("", text: field(path), prompt: Text(verbatim: label == "Betreff" ? "Betreff" : "E-Mail-Adressen, mit Komma trennen"))
                .textFieldStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
                .disabled(editor.busy || !editor.draft.status.editable)
        }.padding(.vertical, 4)
    }
    private func recipientRow(_ label: String, field path: WritableKeyPath<LocalDraft, String>, id: String) -> some View {
        RecipientEntryView(value: field(path), label: label, identifier: id, history: editor.recipientHistory,
            otherAddresses: editor.otherRecipientAddresses(excluding: path), enabled: !editor.busy && editor.draft.status.editable)
    }
}

struct LocalDraftList: View {
    @Bindable var model: InboxModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "Auf diesem Mac").foregroundStyle(Brand.accent(scheme))
                Text("Entwürfe").font(Brand.headline(27)).accessibilityIdentifier("local-drafts-title")
                Text("Deine Arbeitskopien, automatisch gesichert.")
                    .font(.system(size: 12)).foregroundStyle(Brand.secondary(scheme))
                Picker("Ansicht", selection: $model.showingSubmissionHistory) {
                    Text("Entwürfe").tag(false)
                    Text("Versandstatus").tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("local-draft-section")
            }.padding(24)
            Divider()
            if let error = model.draftListError {
                ContentUnavailableView {
                    Label("Entwürfe nicht verfügbar", systemImage: "exclamationmark.circle")
                } description: { Text(error) } actions: {
                    Button("Erneut versuchen") { model.refreshLocalDrafts() }
                }
            } else if model.visibleDrafts.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: model.showingSubmissionHistory ? "paperplane" : "square.and.pencil")
                        .font(.system(size: 28, weight: .light)).foregroundStyle(Brand.accent(scheme))
                    Text(model.draftSearchText.isEmpty ? (model.showingSubmissionHistory ? "Noch kein Versand" : "Alles geschrieben.") : "Keine Treffer")
                        .font(Brand.headline(23))
                    Text(model.showingSubmissionHistory ? "Hier findest du Versandbelege und offene Versandprüfungen." : "Neue Mails und Antworten werden hier automatisch gesichert, bis du sie sendest.")
                        .font(.system(size: 12)).foregroundStyle(Brand.secondary(scheme)).multilineTextAlignment(.center)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedDraftID) {
                    ForEach(model.visibleDrafts) { draft in
                        Button { model.selectedDraftID = draft.id } label: { draftRow(draft) }
                            .buttonStyle(.plain).tag(draft.id)
                            .accessibilityIdentifier("local-draft-\(draft.id)")
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { model.selectedDraftID = draft.id; model.openDraft(draft) })
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden).accessibilityIdentifier("local-draft-list")
            }
            Divider()
            HStack(spacing: 7) {
                Image(systemName: "lock.doc")
                Text("Lokal verschlüsselt · \(model.visibleDrafts.count) \(model.visibleDrafts.count == 1 ? "Eintrag" : "Einträge")")
                Spacer(minLength: 0)
                Button { model.refreshLocalDrafts() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Entwürfe aktualisieren").accessibilityLabel("Entwürfe aktualisieren")
            }.font(.system(size: 10)).foregroundStyle(Brand.secondary(scheme)).padding(14)
        }.foregroundStyle(Brand.text(scheme)).background(Brand.canvas(scheme))
    }
    private func draftRow(_ draft: LocalDraft) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                if let account = model.accounts.first(where: { $0.id == draft.accountID }) {
                    AccountSymbol(account: account, onDarkBackground: scheme == .dark)
                    Text(account.name).font(.system(size: 11, weight: .medium))
                }
                Spacer(minLength: 4)
                Text(draft.modifiedAt, format: .dateTime.day().month(.twoDigits).hour().minute())
                    .font(.system(size: 10)).foregroundStyle(Brand.secondary(scheme))
            }
            Text(draft.subject.isEmpty ? "Ohne Betreff" : draft.subject)
                .font(.system(size: 14, weight: .semibold)).lineLimit(2)
            Text(draft.status == .sent ? "Versandbeleg" : draft.to.isEmpty ? "Noch kein Empfänger" : "An: " + draft.to)
                .font(.system(size: 11)).foregroundStyle(Brand.secondary(scheme)).lineLimit(1)
            Text(Self.status(draft.status)).font(.system(size: 10, weight: .medium))
                .foregroundStyle(Brand.accent(scheme))
            Divider().padding(.top, 7)
        }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(model.selectedDraftID == draft.id ? Brand.selection(scheme) : .clear)
            .contentShape(Rectangle())
    }
    static func status(_ state: DraftStatus) -> String {
        switch state {
        case .editing: "Entwurf"
        case .failed: "Nicht gesendet · bearbeiten"
        case .sending: "Versand läuft"
        case .uncertain: "Versand unklar · prüfen"
        case .accepted: "Gesendet · Kopie noch offen"
        case .sent: "Gesendet · Kopie bestätigt"
        }
    }
}

struct LocalDraftDetail: View {
    @Bindable var model: InboxModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.doc")
                Text("Entwürfe auf diesem Mac").fontWeight(.medium)
                Spacer()
            }.font(.system(size: 11)).foregroundStyle(Brand.secondary(scheme))
                .padding(.horizontal, 24).frame(height: 40).background(Brand.canvas(scheme))
            Divider()
            if let draft = model.selectedDraft {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Eyebrow(text: LocalDraftList.status(draft.status)).foregroundStyle(Brand.accent(scheme))
                            Spacer()
                            Button(draft.status.editable ? "Weiter schreiben" : "Versand prüfen") { model.openDraft(draft) }
                                .buttonStyle(.bordered).tint(Brand.accent(scheme))
                                .disabled(model.compositionBusy).accessibilityIdentifier("local-draft-open")
                        }
                        Text(draft.subject.isEmpty ? "Ohne Betreff" : draft.subject).font(Brand.headline(28))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Von: " + draft.sender)
                            if draft.status != .sent { Text("An: " + (draft.to.isEmpty ? "Noch kein Empfänger" : draft.to)) }
                            if !draft.cc.isEmpty { Text("Cc: " + draft.cc) }
                            if !draft.bcc.isEmpty { Text("Bcc: " + draft.bcc) }
                        }.font(.system(size: 12)).foregroundStyle(Brand.secondary(scheme)).textSelection(.enabled)
                        if draft.status == .uncertain || draft.status == .sending {
                            Label("Der Versand ist noch nicht geklärt. Bitte prüfe den Status, bevor du weitere Schritte ausführst.", systemImage: "exclamationmark.circle")
                                .font(.system(size: 12)).foregroundStyle(Brand.accent(scheme))
                        } else if draft.status == .accepted {
                            Text("Der Mailserver hat die Nachricht angenommen. Nur die Gesendet-Kopie ist noch nicht bestätigt.")
                                .font(.system(size: 12)).foregroundStyle(Brand.secondary(scheme))
                        }
                        Divider()
                        Text(draft.status == .sent
                             ? "Die Nachricht wurde gesendet und die Gesendet-Kopie bestätigt. Die vollständige Mail findest du im Gesendet-Ordner dieses Kontos. Hier bleibt nur der Versandbeleg gespeichert."
                             : draft.body.isEmpty ? "Noch kein Nachrichtentext." : draft.body)
                            .font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                        if let signature = draft.signature, signature.enabled {
                            Divider()
                            Text(signature.plainText).font(.system(size: 12)).foregroundStyle(Brand.secondary(scheme)).textSelection(.enabled)
                        }
                        if !draft.attachments.isEmpty {
                            Label("\(draft.attachments.count) Anhänge · im Nachrichtenfenster öffnen", systemImage: "paperclip").font(.system(size: 12))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(30)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "square.and.pencil").font(.system(size: 34, weight: .light)).foregroundStyle(Brand.accent(scheme))
                    Text("Deine nächsten Zeilen.").font(Brand.headline(27))
                    Text("Wähle links einen Entwurf aus. Er bleibt auf diesem Mac, bis du ihn sendest oder ausdrücklich bei Gmail sicherst.")
                        .font(.system(size: 13)).foregroundStyle(Brand.secondary(scheme)).multilineTextAlignment(.center).frame(maxWidth: 340)
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.foregroundStyle(Brand.text(scheme)).background(Brand.surface(scheme))
    }
}

struct SMTPSettingsView: View {
    @Bindable var model: InboxModel
    let account: MailAccount
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @ViewState private var host = ""
    @ViewState private var port = "465"
    @ViewState private var tls = IMAPSecurity.implicitTLS
    @ViewState private var username = ""
    @ViewState private var password = ""
    @ViewState private var reuseIncoming = false
    @ViewState private var policy = SentCopyPolicy.appendToFolder
    @ViewState private var sentFolder = ""
    @ViewState private var busy = false
    @ViewState private var result: String?
    @ViewState private var configured = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Versand einrichten").font(Brand.headline(26))
            Text(account.address.value).font(.system(size: 13, weight: .semibold))
            Form {
                TextField("SMTP-Server", text: $host).accessibilityIdentifier("smtp-host")
                HStack {
                    TextField("Port", text: $port).frame(width: 130).accessibilityIdentifier("smtp-port")
                    Picker("Verschlüsselung", selection: $tls) { Text("TLS ab Verbindung").tag(IMAPSecurity.implicitTLS); Text("STARTTLS erforderlich").tag(IMAPSecurity.startTLS) }
                }
                TextField("Benutzername", text: $username).accessibilityIdentifier("smtp-username")
                Toggle("Vorhandenes Kontopasswort für diesen SMTP-Server verwenden", isOn: $reuseIncoming).accessibilityIdentifier("smtp-reuse-password")
                if !reuseIncoming { SecureField(configured ? "Passwort (leer = gespeichertes SMTP-Passwort)" : "SMTP-Passwort", text: $password).accessibilityIdentifier("smtp-password") }
                Picker("Gesendet-Kopie", selection: $policy) {
                    Text("Diese App legt eine Kopie im Ordner ab").tag(SentCopyPolicy.appendToFolder)
                    Text("Anbieter speichert selbst; nur prüfen").tag(SentCopyPolicy.providerManaged)
                }.accessibilityIdentifier("smtp-copy-policy")
                Picker("Gesendet-Ordner", selection: $sentFolder) {
                    ForEach(model.folders.filter { $0.accountID == account.id }) { folder in Text(folder.name).tag(folder.providerID) }
                }.accessibilityIdentifier("smtp-sent-folder")
            }.disabled(busy)
            Text("Das Passwort wird ausschliesslich verschlüsselt an den oben genannten Server übertragen und im macOS-Schlüsselbund gespeichert. «Prüfen & sichern» sendet keine Nachricht.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let result { Text(result).font(.system(size: 12)).accessibilityIdentifier("smtp-result") }
            HStack {
                Button("Schliessen") { password = ""; dismiss() }.disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Prüfen & sichern") { Task { await configure() } }.buttonStyle(.borderedProminent)
                    .disabled(busy || host.isEmpty || username.isEmpty || sentFolder.isEmpty)
                    .accessibilityIdentifier("smtp-save")
            }
        }.padding(28).frame(width: 600).background(Brand.canvas(scheme)).tint(Brand.accent(scheme))
            .task {
                username = account.address.value
                sentFolder = model.folders.first { $0.accountID == account.id && $0.role == .sent }?.providerID ?? ""
                if let existing = await model.smtpProfile(account.id) {
                    host = existing.host; port = String(existing.port); tls = IMAPSecurity(rawValue: existing.security) ?? .implicitTLS
                    username = existing.username; policy = existing.sentPolicy; sentFolder = existing.sentFolder; configured = true
                } else { host = await model.suggestedSMTPHost(account.id) }
            }
    }
    private func configure() async {
        busy = true; result = nil; defer { busy = false; password = "" }
        do {
            guard let portNumber = Int(port) else { throw ComposeFailure.missingConfiguration }
            let profile = try SMTPProfile(accountID: account.id, host: host, port: portNumber, security: tls, username: username, sentPolicy: policy, sentFolder: sentFolder)
            try await model.configureSMTP(profile, password: password.isEmpty ? nil : password, reuseIncoming: reuseIncoming)
            configured = true; result = "Versandkonto geprüft und gespeichert. Keine Nachricht versendet."
        } catch { result = ComposerEditor.safeError(error) }
    }
}
