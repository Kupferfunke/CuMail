import SwiftUI
import AppKit
import MailDomain
import MailApplication

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Hell", dark = "Dunkel"
    var id: String { rawValue }
    var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
}

struct SettingsView: View {
    @Bindable var model: InboxModel
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage(ComposerSpellingLanguage.preferenceKey) private var spellingLanguage = ComposerSpellingLanguage.automatic.rawValue
    @AppStorage(ComposerSpellingLanguage.correctionKey) private var automaticCorrection = true
    @Environment(\.colorScheme) private var scheme
    @ViewState private var editingAccount: MailAccount?
    @ViewState private var confirmation: StorageConfirmation?
    @ViewState private var addingIMAP = false
    @ViewState private var addingGoogle = false
    @ViewState private var googleAccount: MailAccount?
    @ViewState private var passwordAccount: MailAccount?
    @ViewState private var smtpAccount: MailAccount?
    var body: some View {
        TabView {
            general.tabItem { Label("Allgemein", systemImage: "slider.horizontal.3") }
            SignatureSettingsView(model: model).tabItem { Label("Signaturen", systemImage: "signature") }
            contentSearch.tabItem { Label("Inhaltssuche", systemImage: "text.magnifyingglass") }
            accounts.tabItem { Label("Konten", systemImage: "person.crop.circle") }
            DesktopSettingsView(controller: model.desktop, accounts: model.accounts.filter { model.realAccountIDs.contains($0.id) })
                .tabItem { Label("Hintergrund", systemImage: "arrow.triangle.2.circlepath") }
            AssistantSettingsView(controller: model.assistant).tabItem { Label("KI-Zugang", systemImage: "sparkles") }
            storage.task { try? await model.refreshStorage() }
                .tabItem { Label("Speicher", systemImage: "externaldrive") }
            about.tabItem { Label("Über", systemImage: "info.circle") }
        }.padding(24).frame(width: 650, height: 520)
            .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
            .tint(Brand.accent(scheme))
            .sheet(item: $editingAccount) { account in
                if let initial = model.accountSettings[account.id] {
                    AccountSettingsEditor(initial: initial) { settings in
                        await model.maintain(.save(settings))
                    }
                }
            }
            .sheet(isPresented: $addingGoogle) { GoogleAccountEditor(model: model, existing: nil) }
            .sheet(item: $googleAccount) { GoogleAccountEditor(model: model, existing: $0) }
            .sheet(isPresented: $addingIMAP) { IMAPAccountEditor(model: model) }
            .sheet(item: $passwordAccount) { PasswordEditor(model: model, account: $0) }
            .sheet(item: $smtpAccount) { SMTPSettingsView(model: model, account: $0) }
            .alert(confirmation?.title ?? "", isPresented: Binding(
                get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
            ), presenting: confirmation) { item in
                Button(item.button, role: .destructive) { Task { await model.maintain(item.action) }; confirmation = nil }
                    .accessibilityIdentifier("confirm-local-action")
                Button("Abbrechen", role: .cancel) { confirmation = nil }
            } message: { item in Text(item.message) }
    }
    private var contentSearch: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Deine Mails wiederfinden.").font(Brand.headline(25))
                Text("CuMail und ChatGPT durchsuchen denselben verschlüsselten Textindex. Der Abruf verändert den Lesestatus nicht. Für ChatGPT gelten weiterhin deine Ordner- und Textfreigaben.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(model.accounts) { account in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(account.name).font(.system(size: 14, weight: .semibold))
                        if let progress = model.contentIndexer.progress[account.id] {
                            Text("\(progress.indexed.formatted()) von \(progress.total.formatted()) Nachrichtentexten durchsuchbar")
                                .font(.system(size: 12)).accessibilityIdentifier("content-index-progress-\(account.id)")
                            ProgressView(value: Double(progress.indexed + progress.skipped), total: Double(max(1, progress.total)))
                            Text("\(progress.pending.formatted()) offen · \(progress.skipped.formatted()) ohne abrufbaren Text · \(progress.truncated.formatted()) gekürzt")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            if let note = model.contentIndexer.notes[account.id] { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
                            HStack {
                                Button(progress.enabled ? "Pausieren" : progress.indexed > 0 ? "Fortsetzen" : "Alle Texte erfassen") { Task {
                                    if var settings = model.accountSettings[account.id] {
                                        settings.fullTextIndexEnabled = !progress.enabled
                                        if settings.fullTextIndexEnabled { settings.textIndexEnabled = true }
                                        await model.maintain(.save(settings))
                                    }
                                } }.accessibilityIdentifier("content-index-toggle-\(account.id)")
                                if progress.skipped + progress.retrying > 0 {
                                    Button("Fehlende erneut versuchen") { Task { await model.contentIndexer.retry(account: account.id) } }
                                }
                                if model.contentIndexer.activeAccount == account.id { ProgressView().controlSize(.small); Text("Texte werden geladen …").font(.system(size: 11)) }
                            }.disabled(model.networkBusy || model.storageBusy)
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
                }
                Text("Neue Mails werden nach dem Metadatenabgleich ergänzt. Nach einem Neustart setzt der Lauf fort. Anhänge werden hier nur nach Dateinamen durchsucht. Text- und Kontobudget lassen sich unter «Konten» ändern.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(24)
        }.task { await model.contentIndexer.refresh() }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Ein ruhiger Arbeitsplatz.").font(Brand.headline(27))
            Text("Aussehen und Schreiben, wie es zu dir passt.").font(.system(size: 13)).foregroundStyle(.secondary)
            Picker("Erscheinungsbild", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }.pickerStyle(.segmented).accessibilityIdentifier("appearance-picker")
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Rechtschreibung").font(.system(size: 15, weight: .semibold))
                Picker("Sprache", selection: $spellingLanguage) {
                    ForEach(ComposerSpellingLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                }.accessibilityIdentifier("compose-spelling-language")
                Toggle("Tippfehler automatisch korrigieren", isOn: $automaticCorrection)
                    .accessibilityIdentifier("compose-spelling-correction")
                Text("Gilt für Betreff und Nachrichtentext. Auffällige Wörter werden unterstrichen; per Rechtsklick wählst du einen Vorschlag. «Automatisch» nutzt die Spracherkennung von macOS.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Label("Die Systemeinstellungen für Kontrast und Bedienung bleiben wirksam.", systemImage: "accessibility")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }.padding(24)
    }
    private var accounts: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Deine Konten. Deine Grenzen.").font(Brand.headline(25))
            Text("Gmail und IMAP · Dein gesamter Mailbestand an einem Ort.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
            ForEach(model.accounts) { account in
                HStack {
                    AccountSymbol(account: account, onDarkBackground: scheme == .dark)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.name).font(.system(size: 13, weight: .medium))
                        Text(account.address.value).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(account.status == .demo ? "Synthetische Demo" : "\(account.provider == .gmail ? "Gmail" : account.provider == .microsoft ? "Microsoft" : "IMAP") · \(InboxModel.accountStatusName(account.status))").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(model.accountSettings[account.id]?.fullTextIndexEnabled == true ? "Inhaltssuche im Hintergrund" : model.accountSettings[account.id]?.textIndexEnabled == true ? "Textindex beim Öffnen" : "Nur Metadaten")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        HStack {
                            if model.imapAccountIDs.contains(account.id) {
                                Button("Versand") { smtpAccount = account }.accessibilityIdentifier("smtp-settings-\(account.id)")
                                Button("Anmeldung") { passwordAccount = account }
                                    .accessibilityIdentifier("reauthenticate-\(account.id)")
                            }
                            if model.gmailConfigurations[account.id] != nil {
                                Button("Google-Anmeldung") { googleAccount = account }.accessibilityIdentifier("google-settings-\(account.id)")
                            }
                            Button("Bearbeiten") { editingAccount = account }
                                .accessibilityIdentifier("edit-account-\(account.id)")
                            Menu {
                                Button("Textextrakte löschen …") { confirmation = .clearTexts(account) }
                                    .accessibilityIdentifier("clear-texts-\(account.id)")
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).fixedSize()
                                .help("Lokale Textextrakte verwalten").accessibilityIdentifier("account-index-actions-\(account.id)")
                            Button { confirmation = .remove(account) } label: { Image(systemName: "minus.circle") }
                                .help("Konto aus dieser App entfernen").accessibilityLabel("\(account.name) entfernen")
                                .accessibilityIdentifier("remove-account-\(account.id)")
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            }
            if model.accounts.isEmpty { Text("Verbinde ein Gmail- oder IMAP-Konto, um deine Nachrichten zu laden.").foregroundStyle(.secondary) }
            Divider()
            HStack {
                Button("Gmail hinzufügen …") { addingGoogle = true }.accessibilityIdentifier("add-google-account")
                Button("IMAP hinzufügen …") { addingIMAP = true }.accessibilityIdentifier("add-imap-account")
            }
            if let message = model.networkMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(model.networkFailed ? Color.red : Color.secondary)
            }
            operationStatus
            Spacer()
        }.padding(24).disabled(!model.persistentStoreReady || model.storageBusy || model.networkBusy)
    }
    private var storage: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("Deine Daten. Gut aufgehoben.").font(Brand.headline(25))
            Label(model.persistentStoreReady ? "Lokaler Index verschlüsselt · Schlüssel im macOS-Schlüsselbund" : "Lokaler Speicher noch nicht verfügbar",
                  systemImage: "lock.shield").font(.system(size: 12))
            if let summary = model.storageSummary {
                Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 9) {
                    GridRow { Text("Konten / Nachrichten"); Text("\(summary.accountCount) / \(summary.messageCount)").accessibilityIdentifier("storage-counts") }
                    GridRow { Text("Textabdeckung"); Text("\(summary.indexedTextCount) von \(summary.messageCount) Nachrichten").accessibilityIdentifier("text-coverage") }
                    GridRow { Text("Gespeicherter Extrakttext"); Text(Self.bytes(Int64(summary.extractBytes))) }
                    GridRow { Text("Index mit Journal"); Text(Self.bytes(summary.databaseBytes)) }
                    GridRow { Text("Temporäre Dateien"); Text("\(Self.bytes(summary.temporaryBytes)) von 250 MiB").accessibilityIdentifier("storage-temporary-bytes") }
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text("Die Inhaltssuche kann alle Nachrichtentexte pro Konto im Hintergrund erfassen. Fortschritt und Grenzen stehen unter «Inhaltssuche». Temporäre Dateien werden nach 24 Stunden ohne aktive Verwendung bereinigt. Grössen enthalten keine Benutzerexporte.")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Text("Sicherungen").font(.system(size: 14, weight: .semibold))
                if let copy = model.backupInfo {
                    Text("Letzte geprüfte Sicherung: \(copy.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 12)).accessibilityIdentifier("backup-last-verified")
                    Text("\(copy.accountCount) Konten · \(copy.messageCount.formatted()) Nachrichten · \(copy.signatureCount) Signaturen · \(copy.draftCount) Entwürfe und Versandbelege")
                        .font(.system(size: 11)).foregroundStyle(.secondary).accessibilityIdentifier("backup-inventory")
                } else { Text("Noch keine geprüfte Sicherung vorhanden.").font(.system(size: 12)) }
                Text("Automatisch stündlich bei ruhender Mailarbeit und beim Beenden. Die letzten zwei Sicherungen und Tagesstände der letzten sieben Sicherungstage bleiben erhalten. Enthalten sind auch Kontoeinstellungen, Signaturen und KI-Freigaben.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label(model.dataIncludedInBackups ? "Daten und Sicherungen sind für Time Machine zugelassen." : "Backup-Einstellung noch nicht geprüft.",
                      systemImage: model.dataIncludedInBackups ? "checkmark.shield" : "clock")
                    .font(.system(size: 11)).accessibilityIdentifier("backup-system-inclusion")
                Text("Für die Wiederherstellung wird der zugehörige macOS-Schlüsselbund benötigt. Für Schutz bei Geräteausfall muss auch deine externe Time-Machine-Sicherung aktuell sein.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Jetzt sichern") { Task { await model.makeRecoveryBackup(force: true) } }.accessibilityIdentifier("backup-create")
                    Button("Sicherung prüfen") { Task { await model.verifyLatestBackup() } }.disabled(model.backupInfo == nil).accessibilityIdentifier("backup-verify")
                    Button("Ordner öffnen") { if let url = model.backupLocation { NSWorkspace.shared.open(url) } }.disabled(model.backupLocation == nil)
                }.disabled(model.backupBusy || model.storageBusy || model.networkBusy || !model.persistentStoreReady)
                if model.backupBusy { ProgressView().controlSize(.small) }
                if let message = model.backupMessage {
                    Text(message).font(.system(size: 11)).foregroundStyle(model.backupFailed ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("backup-status")
                }
                if let location = model.dataLocation {
                    Text(location.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("data-location")
                }
            }
            Divider()
            HStack {
                Button("Index neu aufbauen …") { confirmation = .rebuild }.accessibilityIdentifier("rebuild-index")
                Button("Lokale Daten löschen …") { confirmation = .clear }.accessibilityIdentifier("clear-local-data")
            }.disabled(!model.persistentStoreReady || model.storageBusy || model.networkBusy || model.backupBusy)
            if model.isDemoMode { Button("Demodaten wiederherstellen") { Task { await model.maintain(.restore) } }
                .accessibilityIdentifier("restore-demo-data").disabled(!model.persistentStoreReady || model.storageBusy || model.networkBusy) }
            operationStatus
            Spacer(minLength: 0)
        }.padding(24)
        }
    }
    private var about: some View {
        VStack(spacing: 16) {
            CuMailBrandArtwork().frame(width: 330, height: 220)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.14.0")")
                .font(Brand.mono(11)).foregroundStyle(.secondary)
            Text("Ideen mit Hand und Fuss.").font(.system(size: 14)).padding(.top, 8)
            Text("E-Mail für deinen Mac. Von KupferFunke.\nSchriften: Josefin Sans, Barlow und IBM Plex Mono · SIL OFL 1.1.")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder private var operationStatus: some View {
        if model.keychainAccessNeeded {
            Button("Schlüsselbundzugriff freigeben …") { Task { await model.allowKeychainAccess() } }
        }
        if model.storageBusy { ProgressView("Lokaler Speicher wird aktualisiert …").controlSize(.small) }
        if let message = model.storageMessage {
            Label(message, systemImage: model.storageError ? "exclamationmark.circle" : "checkmark.circle")
                .font(.system(size: 11)).foregroundStyle(model.storageError ? Color.red : Color.secondary)
                .accessibilityIdentifier("storage-operation-status")
        }
    }
    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }
}

struct IMAPAccountEditor: View {
    @Bindable var model: InboxModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = "Mein Postfach"
    @ViewState private var address = ""
    @ViewState private var host = ""
    @ViewState private var port = "993"
    @ViewState private var security: IMAPSecurity = .implicitTLS
    @ViewState private var username = ""
    @ViewState private var password = ""
    @ViewState private var approved = false
    @ViewState private var connecting = false
    @ViewState private var connectionTask: Task<Void, Never>?

    private var valid: Bool {
        guard approved, !password.isEmpty, let number = Int(port),
              let id = try? AccountID(), (try? EmailAddress(address)) != nil,
              (try? AccountSettings(accountID: id, displayName: name)) != nil else { return false }
        return (try? IMAPConfiguration(accountID: id, host: host, port: number, security: security, username: username)) != nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Dein Postfach verbinden.").font(Brand.headline(27))
            Text("Alle Ordner und Nachrichten werden erfasst. Inhalte und Anhänge lädt CuMail beim Öffnen.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Anzeigename", text: $name).accessibilityIdentifier("imap-name")
                TextField("E-Mail-Adresse", text: $address).accessibilityIdentifier("imap-address")
                TextField("IMAP-Server", text: $host).accessibilityIdentifier("imap-host")
                HStack {
                    TextField("Port", text: $port).frame(width: 130).accessibilityIdentifier("imap-port")
                    Picker("Sicherheit", selection: $security) {
                        Text("TLS").tag(IMAPSecurity.implicitTLS)
                        Text("STARTTLS erforderlich").tag(IMAPSecurity.startTLS)
                    }.accessibilityIdentifier("imap-security")
                }
                TextField("Benutzername", text: $username).accessibilityIdentifier("imap-username")
                SecureField("Passwort / App-Passwort", text: $password).accessibilityIdentifier("imap-password")
            }.disabled(connecting)
            Label("Passwort im macOS-Schlüsselbund · reguläre Zertifikatsprüfung", systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Toggle("Dieses Konto für den Mailabruf verbinden", isOn: $approved)
                .accessibilityIdentifier("imap-consent").disabled(connecting)
            if connecting { ProgressView("Verbindung und Ordner werden geprüft …").controlSize(.small) }
            if let message = model.networkMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(model.networkFailed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("imap-result")
            }
            HStack {
                Button("Abbrechen") {
                    if connecting { connectionTask?.cancel() } else { password = ""; dismiss() }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("imap-cancel")
                Spacer()
                Button("Prüfen & hinzufügen") {
                    let secret = password; password = ""; connecting = true
                    connectionTask = Task {
                        let connected = await model.connectIMAP(name: name, address: address, host: host,
                            port: Int(port) ?? 0, security: security, username: username, password: secret)
                        connecting = false
                        if connected { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).disabled(!valid || connecting)
                    .accessibilityIdentifier("imap-connect")
            }
        }.padding(30).frame(width: 570).interactiveDismissDisabled(connecting)
            .onAppear { model.networkMessage = nil }
            .onChange(of: address) { old, value in if username.isEmpty || username == old { username = value } }
            .onChange(of: security) { _, value in if port == "993" || port == "143" { port = value == .implicitTLS ? "993" : "143" } }
            .onDisappear { password = ""; connectionTask?.cancel() }
    }
}

private struct PasswordEditor: View {
    @Bindable var model: InboxModel
    let account: MailAccount
    @Environment(\.dismiss) private var dismiss
    @ViewState private var password = ""
    @ViewState private var task: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Anmeldung erneuern.").font(Brand.headline(26))
            Text(account.name + " · " + account.address.value).font(.system(size: 12)).foregroundStyle(.secondary)
            SecureField("Neues Passwort / App-Passwort", text: $password).disabled(model.networkBusy)
            if let message = model.networkMessage { Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Abbrechen") { if model.networkBusy { task?.cancel() } else { password = ""; dismiss() } }
                Spacer()
                Button("Prüfen & speichern") {
                    let secret = password; password = ""
                    task = Task { if await model.updatePassword(account: account.id, password: secret) { dismiss() } }
                }.disabled(password.isEmpty || model.networkBusy).buttonStyle(.borderedProminent)
            }
        }.padding(30).frame(width: 480).interactiveDismissDisabled(model.networkBusy)
            .onAppear { model.networkMessage = nil }
            .onDisappear { password = ""; task?.cancel() }
    }
}

private enum StorageConfirmation {
    case remove(MailAccount), clearTexts(MailAccount), rebuild, clear
    var title: String {
        switch self { case .remove: "Konto entfernen?"; case .clearTexts: "Textextrakte löschen?"; case .rebuild: "Index neu aufbauen?"; case .clear: "Lokale Konten und Daten löschen?" }
    }
    var message: String {
        switch self {
        case .remove(let account): "«\(account.name)» wird mit seinen lokalen Entwürfen und Versandbelegen, Metadaten, Textindex, temporären Dateien und eigenen Zugangsdaten aus dieser App entfernt. Nachrichten auf dem Mailserver bleiben erhalten. Frühere Sicherungen bleiben bis zum Ende ihrer Aufbewahrung erhalten."
        case .clearTexts(let account): "Gespeicherte Textextrakte und ihre Suchbegriffe für «\(account.name)» werden entfernt. Metadaten bleiben erhalten. Der Hintergrundlauf wird pausiert. Wenn die Textindexierung aktiviert bleibt, können beim nächsten Öffnen wieder Extrakte entstehen. Frühere Sicherungen bleiben erhalten."
        case .rebuild: "Lokale Metadaten und Texte werden entfernt. Eigene Entwürfe, Versandbelege, Gmail-/IMAP-Konten, ihre Ordner und Zugangsdaten bleiben erhalten. Der nächste Abgleich lädt den Bestand erneut."
        case .clear: "Alle lokalen Konten, eigenen Entwürfe und Versandbelege, Einstellungen, Metadaten, Textextrakte, temporären Dateien, eigenen Zugangsdaten und die CuMail-Sicherungen auf diesem Mac werden entfernt. Der leere Index bleibt verschlüsselt. Nachrichten auf dem Mailserver und externe Backups bleiben erhalten."
        }
    }
    var button: String { switch self { case .remove: "Konto entfernen"; case .clearTexts: "Textextrakte löschen"; case .rebuild: "Neu aufbauen"; case .clear: "Lokale Daten löschen" } }
    var action: LocalDataAction { switch self { case .remove(let account): .remove(account.id); case .clearTexts(let account): .clearTexts(account.id); case .rebuild: .rebuild; case .clear: .clear } }
}

private struct AccountSettingsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var settings: AccountSettings
    @ViewState private var saving = false
    let save: (AccountSettings) async -> Void
    init(initial: AccountSettings, save: @escaping (AccountSettings) async -> Void) {
        _settings = ViewState(initialValue: initial); self.save = save
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Kontoeinstellungen").font(Brand.headline(26))
            TextField("Anzeigename", text: $settings.displayName).accessibilityIdentifier("account-display-name")
            Toggle("Aktionen auf dem Mailserver erlauben", isOn: $settings.serverActionsEnabled)
                .accessibilityIdentifier("server-actions-enabled")
            Text("Erlaubt bewusstes Ändern von Lesestatus und Favoriten sowie Verschieben, Archivieren und Papierkorb. Das automatische Markieren beim Lesen wird separat eingestellt.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("Beim Lesen als gelesen markieren", selection: $settings.markReadAfterSeconds) {
                Text("Manuell").tag(0)
                Text("Nach 2 Sekunden").tag(2)
                Text("Nach 5 Sekunden").tag(5)
            }.disabled(!settings.serverActionsEnabled).accessibilityIdentifier("mark-read-delay")
            Toggle("Nachrichtentexte lokal indexieren", isOn: $settings.textIndexEnabled)
                .accessibilityIdentifier("text-index-enabled")
                .onChange(of: settings.textIndexEnabled) { _, enabled in if !enabled { settings.fullTextIndexEnabled = false } }
            Text("Die lokale Suche umfasst dann zusätzlich die bereits geöffneten Texte. Beim Ausschalten werden vorhandene Textextrakte und ihre Suchbegriffe entfernt.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Toggle("Auch ungeöffnete Mails im Hintergrund erfassen", isOn: $settings.fullTextIndexEnabled)
                .disabled(!settings.textIndexEnabled).accessibilityIdentifier("full-text-index-enabled")
            Picker("Text je Nachricht", selection: $settings.messageTextLimit) {
                ForEach([16, 64, 128, 256], id: \.self) { Text("\($0) KiB").tag($0 * 1024) }
            }.accessibilityIdentifier("message-text-budget")
            Picker("Textbudget für dieses Konto", selection: $settings.accountTextBudget) {
                ForEach([10, 50, 100, 250], id: \.self) { Text("\($0) MiB").tag($0 * 1024 * 1024) }
            }.accessibilityIdentifier("account-text-budget")
            Text("Lange Texte werden gekürzt. Ein kleineres Budget entfernt ältere Extrakte; Metadaten bleiben durchsuchbar.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Speichern") {
                    saving = true
                    Task { await save(settings); saving = false; dismiss() }
                }.keyboardShortcut(.defaultAction).disabled((try? settings.validate()) == nil || saving)
                    .accessibilityIdentifier("save-account-settings")
            }
        }.padding(30).frame(width: 500).disabled(saving)
    }
}
