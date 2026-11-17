import SwiftUI
import MailDomain
import MailApplication
import MailGoogle

struct GoogleAccountEditor: View {
    @Bindable var model: InboxModel
    let existing: MailAccount?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @ViewState private var email = ""
    @ViewState private var clientID = GoogleAuthentication.defaultClientID
    @ViewState private var permission = GmailPermission.readOnly
    @ViewState private var task: Task<Void, Never>?
    @ViewState private var confirmRevoke = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow(text: "DEINE POST. DIREKT VON GOOGLE.").foregroundStyle(Brand.accent(scheme))
            Text(existing == nil ? "Gmail verbinden" : "Google-Anmeldung").font(Brand.headline(28))
            Text("Die Anmeldung öffnet sich bei Google im Browser. Dein Google-Passwort bleibt dort.")
                .font(.system(size: 13)).foregroundStyle(Brand.secondary(scheme))
                .fixedSize(horizontal: false, vertical: true)
            TextField("Gmail- oder Workspace-Adresse", text: $email).textFieldStyle(.roundedBorder)
                .disabled(existing != nil || model.networkBusy).accessibilityIdentifier("google-email")
            Picker("Zugriff", selection: $permission) {
                Text("Nur lesen").tag(GmailPermission.readOnly)
                Text("Lesen, ordnen und senden").tag(GmailPermission.manageMail)
            }.pickerStyle(.segmented).disabled(model.networkBusy).accessibilityIdentifier("google-permission")
            Text(permission == .readOnly ? "Metadaten und Labels abgleichen; Texte erst beim Öffnen laden. Der Gelesen-Status bleibt unverändert." : "Erlaubt zusätzlich eigene Gmail-Entwürfe, Versand und Label-Änderungen. Jede Aktion startest du bewusst. Ordnen muss zusätzlich in den Kontoeinstellungen aktiviert sein.")
                .font(.system(size: 12)).foregroundStyle(Brand.secondary(scheme))
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Eigene Google-Registrierung") {
                TextField("Öffentliche Apple-Client-ID", text: $clientID).textFieldStyle(.roundedBorder).disabled(model.networkBusy)
                Text("Für Gmail ist eine eigene Google-Registrierung nötig. Siehe die Einrichtungsanleitung im Projekt.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let message = model.networkMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(model.networkFailed ? Color.red : Brand.secondary(scheme)).accessibilityIdentifier("google-status")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.networkBusy { ProgressView().controlSize(.small) }
            if let existing {
                HStack {
                    Menu("Abmelden") {
                        Button("Nur auf diesem Mac abmelden") { Task { await model.disconnectGoogle(existing, revoke: false); dismiss() } }
                        Button("Google-Zugriff widerrufen …", role: .destructive) { confirmRevoke = true }
                    }.disabled(model.networkBusy)
                    Button("Abgleich zurücksetzen") { Task { await model.resetGoogleCoverage(existing) } }
                        .disabled(model.networkBusy).help("Startet den vollständigen Abgleich neu. Nachrichten bei Google und eigene Entwürfe bleiben erhalten.")
                    Spacer()
                }
            }
            HStack {
                Spacer()
                Button("Abbrechen") {
                    model.cancelGoogleLogin(); task?.cancel(); dismiss()
                }.keyboardShortcut(.cancelAction)
                Button("Bei Google anmelden") {
                    signIn(useDefaultBrowser: true)
                }.buttonStyle(.borderedProminent).tint(Brand.accent(scheme))
                    .disabled(model.networkBusy || (try? EmailAddress(email)) == nil)
                    .accessibilityIdentifier("google-sign-in")
            }
        }.padding(28).frame(width: 560).background(Brand.canvas(scheme)).foregroundStyle(Brand.text(scheme))
            .onAppear {
                email = existing?.address.value ?? ""
                if let id = existing?.id, let config = model.gmailConfigurations[id] { clientID = config.clientID; permission = config.permission }
            }
            .alert("Google-Zugriff widerrufen?", isPresented: $confirmRevoke) {
                Button("Widerrufen", role: .destructive) { if let existing { Task { await model.disconnectGoogle(existing, revoke: true); dismiss() } } }
                Button("Abbrechen", role: .cancel) { }
            } message: {
                Text("Meldet diese App ab und widerruft ihre Berechtigung bei Google. Das kann weitere Anmeldungen derselben Google-App betreffen. Lokale Metadaten bleiben bis zum Entfernen des Kontos verfügbar.")
            }
    }
    private func signIn(useDefaultBrowser: Bool) {
        task = Task {
            if await model.connectGoogle(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines), email: email,
                                         permission: permission, existing: existing, useDefaultBrowser: useDefaultBrowser) { dismiss() }
        }
    }
}
