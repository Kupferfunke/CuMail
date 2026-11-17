import SwiftUI
import AppKit
import MailDomain

struct AssistantSettingsView: View {
    @Bindable var controller: AssistantController
    @ViewState private var confirmEnable = false
    @ViewState private var confirmText = false
    @ViewState private var confirmCloud = false
    @ViewState private var actionAccount: MailAccount?
    @ViewState private var replyAccount: MailAccount?
    @ViewState private var composeAccount: MailAccount?
    @ViewState private var directSendAccount: MailAccount?
    @ViewState private var tunnelID = ""
    @ViewState private var runtimeKey = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Deine Post. Deine Freigabe.").font(Brand.headline(25))
                Text("Verbundene Assistenten können nur die ausgewählten Ordner lesen. Abgerufene Betreffzeilen, Adressen und freigegebene Mailtexte werden an den verwendeten KI-Anbieter übermittelt.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Toggle("KI-Lesezugang einschalten", isOn: Binding(get: { controller.grant.enabled }, set: { value in
                    if value { confirmEnable = true } else { Task { await controller.setEnabled(false) } }
                })).disabled(controller.changing).accessibilityIdentifier("assistant-enabled")
                Text(controller.status).font(.system(size: 12)).foregroundStyle(.secondary).accessibilityIdentifier("assistant-status")
                Toggle("Mailtexte auf Anfrage freigeben", isOn: Binding(get: { controller.grant.allowText }, set: { value in
                    if value { confirmText = true } else { Task { await controller.setText(false) } }
                })).disabled(controller.changing).accessibilityIdentifier("assistant-text")
                Text("Ohne Textfreigabe bleiben Suche und Auskünfte auf Metadaten begrenzt. Anhänge werden nicht heruntergeladen. Mailaktionen brauchen eine zusätzliche Freigabe pro Konto und Schreibrechte beim Mailanbieter.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Divider()
                Text("Freigegebene Ordner").font(.system(size: 13, weight: .semibold))
                Text("Ordner und Gmail-Labels werden beim Abgleich aktualisiert. Gelöschte Labels verschwinden hier; neue erscheinen zunächst ausgeschaltet. Bestehende Freigaben bleiben erhalten.").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(controller.accounts) { account in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Alle vorhandenen Ordner dieses Postfachs", isOn: Binding(get: {
                                let folders = controller.folders.filter { $0.accountID == account.id }
                                return !folders.isEmpty && folders.allSatisfy { controller.grant.folderIDs.contains($0.id) }
                            }, set: { value in Task { await controller.setAccountFolders(account.id, allowed: value) } }))
                                .disabled(controller.changing).accessibilityIdentifier("assistant-all-folders-\(account.id)")
                            Divider()
                            ForEach(controller.folders.filter { $0.accountID == account.id }) { folder in
                                Toggle(folder.name, isOn: Binding(get: { controller.grant.folderIDs.contains(folder.id) }, set: { value in Task { await controller.setFolder(folder, allowed: value) } }))
                                    .disabled(controller.changing).accessibilityIdentifier("assistant-folder-\(folder.id)")
                            }
                            Toggle("Lesestatus, Favoriten und Verschieben erlauben", isOn: Binding(get: { controller.grant.actionAccountIDs.contains(account.id) }, set: { value in
                                if value { actionAccount = account } else { Task { await controller.setActions(account.id, allowed: false) } }
                            })).disabled(controller.changing || !controller.grant.accountIDs.contains(account.id))
                                .accessibilityIdentifier("assistant-actions-\(account.id)")
                            Toggle("Antworten vorbereiten und Versand anfragen", isOn: Binding(get: { controller.grant.replyAccountIDs.contains(account.id) }, set: { value in
                                if value { replyAccount = account } else { Task { await controller.setReplies(account.id, allowed: false) } }
                            })).disabled(controller.changing || !controller.grant.accountIDs.contains(account.id))
                                .accessibilityIdentifier("assistant-replies-\(account.id)")
                            Toggle("Neue Mails vorbereiten und Versand anfragen", isOn: Binding(get: { controller.grant.composeAccountIDs.contains(account.id) }, set: { value in
                                if value { composeAccount = account } else { Task { await controller.setCompose(account.id, allowed: false) } }
                            })).disabled(controller.changing || !controller.grant.accountIDs.contains(account.id))
                                .accessibilityIdentifier("assistant-compose-\(account.id)")
                            Toggle("Sofort senden – nur auf ausdrücklichen Auftrag", isOn: Binding(get: { controller.grant.directSendAccountIDs.contains(account.id) }, set: { value in
                                if value { directSendAccount = account } else { Task { await controller.setDirectSend(account.id, allowed: false) } }
                            })).disabled(controller.changing || account.status == .demo || !(controller.grant.replyAccountIDs.contains(account.id) || controller.grant.composeAccountIDs.contains(account.id)))
                                .accessibilityIdentifier("assistant-direct-send-\(account.id)")
                            Text("Antworten und Mailaktionen gelten für freigegebene Ordner. Neue Mails verwenden dieses Absenderkonto und die von dir gewünschten Empfänger. Eigene KI-Entwürfe sind lokal verschlüsselt gespeichert. Standard ist die Versandbestätigung auf dem Mac. Mit «Sofort senden» kann ein konkreter ausdrücklicher Sendeauftrag direkt ausgeführt werden; «vorbereiten» allein verschickt nie eine Mail.\(account.status == .demo ? " Demokonten können nichts versenden." : "")")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    } label: {
                        Text("\(account.name)\(account.status == .demo ? " · Demo" : "")").font(.system(size: 12, weight: .semibold))
                    }
                }
                Divider()
                HStack {
                    Button("Alle Freigaben widerrufen") { Task { await controller.revoke() } }.accessibilityIdentifier("assistant-revoke")
                    Button("Zugriffsstatus aktualisieren") { Task { await controller.refreshAudit() } }.accessibilityIdentifier("assistant-audit")
                }
                if !controller.audit.isEmpty {
                    Text("Letzte Aufrufe · nur Werkzeug und Ergebnis, keine Suchtexte oder Mailinhalte").font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(Array(controller.audit.suffix(5).enumerated()), id: \.offset) { _, entry in
                        Text("\(entry.time.formatted(date: .omitted, time: .standard)) · \(entry.tool) · \(entry.succeeded ? "erfolgreich" : "abgewiesen / nicht verfügbar")").font(Brand.mono(10))
                    }
                }
                Divider()
                Text("ChatGPT · Chat und Work").font(.system(size: 13, weight: .semibold))
                Toggle("Mit ChatGPT verbinden", isOn: Binding(get: { controller.tunnel.settings.enabled }, set: { value in
                    if value { confirmCloud = true } else { Task { await controller.tunnel.setEnabled(false, localReady: controller.running) } }
                })).disabled(controller.changing || controller.tunnel.busy || controller.tunnel.settings.tunnelID.isEmpty).accessibilityIdentifier("assistant-cloud")
                Text(controller.tunnel.status).font(.system(size: 12)).foregroundStyle(.secondary).accessibilityIdentifier("assistant-cloud-status")
                Text("Die Verbindung läuft vom Mac zu OpenAI. Nach dem Beenden der App oder im Ruhezustand ist dein Postfach dort nicht erreichbar. Bereits in einen Chat übernommene Inhalte werden durch einen Widerruf nicht aus diesem Chat gelöscht.").font(.system(size: 11)).foregroundStyle(.secondary)
                DisclosureGroup("ChatGPT-Verbindung einrichten") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ein persönliches OpenAI-Tunnel-Plugin verbindet ChatGPT mit den oben gewählten Ordnern. Der Schlüssel benötigt nur Tunnels: Read und Use.").font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField("Tunnel-ID", text: $tunnelID).textFieldStyle(.roundedBorder).accessibilityIdentifier("assistant-tunnel-id")
                        SecureField("Eingeschränkter OpenAI-Runtime-Schlüssel", text: $runtimeKey).textFieldStyle(.roundedBorder).accessibilityIdentifier("assistant-runtime-key")
                        Button("Einrichtung im Schlüsselbund speichern") { Task {
                            if await controller.tunnel.saveConfiguration(tunnelID: tunnelID.trimmingCharacters(in: .whitespacesAndNewlines), key: runtimeKey.trimmingCharacters(in: .whitespacesAndNewlines)) { runtimeKey = "" }
                        } }.disabled(controller.tunnel.busy || runtimeKey.isEmpty).accessibilityIdentifier("assistant-save-cloud")
                        HStack {
                            Link("OpenAI-Tunnel", destination: URL(string: "https://platform.openai.com/settings/organization/tunnels")!)
                            Link("ChatGPT-Plugins", destination: URL(string: "https://chatgpt.com/plugins")!)
                        }
                        Button("Verbindung und Schlüssel entfernen") { Task { await controller.tunnel.forget(); tunnelID = controller.tunnel.settings.tunnelID; runtimeKey = "" } }.disabled(controller.tunnel.busy)
                    }.padding(.top, 8)
                }
                Divider()
                Text("Verbindung zum Assistenten").font(.system(size: 13, weight: .semibold))
                Text("Lokale Clients nutzen das mitgelieferte Programm. Für normalen Chat und Work braucht es zusätzlich ein ChatGPT-Plugin und eine authentifizierte Verbindung zum Mac. Der Mac und CuMail müssen dafür erreichbar sein.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(controller.bridgeCommand).font(Brand.mono(10)).textSelection(.enabled).accessibilityIdentifier("assistant-command")
                Button("Lokalen Programmpfad kopieren") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(controller.bridgeCommand, forType: .string) }
            }.padding(24)
        }
        .onAppear { tunnelID = controller.tunnel.settings.tunnelID }
        .alert("KI-Mailaktionen für dieses Konto erlauben?", isPresented: Binding(get: { actionAccount != nil }, set: { if !$0 { actionAccount = nil } })) {
            Button("Mailaktionen erlauben") {
                if let account = actionAccount { Task { await controller.setActions(account.id, allowed: true) } }
                actionAccount = nil
            }
            Button("Abbrechen", role: .cancel) { actionAccount = nil }
        } message: {
            Text("\(actionAccount?.address.value ?? ""): Auf deine Anweisung darf die KI in freigegebenen Ordnern Lesestatus und Favoriten ändern und Nachrichten verschieben, auch in den Papierkorb. Endgültiges Löschen ist ausgeschlossen. Serveraktionen müssen zusätzlich im Konto erlaubt sein.")
        }
        .alert("Ausdrücklichen Sofortversand erlauben?", isPresented: Binding(get: { directSendAccount != nil }, set: { if !$0 { directSendAccount = nil } })) {
            Button("Sofortversand erlauben") {
                if let account = directSendAccount { Task { await controller.setDirectSend(account.id, allowed: true) } }
                directSendAccount = nil
            }.accessibilityIdentifier("confirm-assistant-direct-send")
            Button("Abbrechen", role: .cancel) { directSendAccount = nil }
        } message: {
            Text("\(directSendAccount?.address.value ?? ""): Wenn du ausdrücklich verlangst, eine bestimmte Mail jetzt zu senden, darf der Assistent sie ohne zusätzlichen Klick auf dem Mac abschicken. Ein Auftrag wie «Entwurf vorbereiten» reicht nicht. Diese Kontofreigabe allein ist kein Sendeauftrag. Absender, Empfänger, Inhalt und Signatur sind an die genaue Entwurfsversion gebunden. Anhänge werden weiterhin auf dem Mac geprüft.")
        }
        .alert("Neue KI-Mails für dieses Konto erlauben?", isPresented: Binding(get: { composeAccount != nil }, set: { if !$0 { composeAccount = nil } })) {
            Button("Neue Mails erlauben") {
                if let account = composeAccount { Task { await controller.setCompose(account.id, allowed: true) } }
                composeAccount = nil
            }.accessibilityIdentifier("confirm-assistant-compose")
            Button("Abbrechen", role: .cancel) { composeAccount = nil }
        } message: {
            Text("\(composeAccount?.address.value ?? ""): Auf deine Anweisung darf der Assistent neue Mails an die von dir gewünschten Empfänger vorbereiten, seine Entwürfe lesen und die Versandprüfung öffnen. Die Standardsignatur wird ergänzt. Persönliche Entwürfe bleiben ausgeschlossen. Standard ist deine Versandbestätigung in CuMail; Sofortversand braucht eine zusätzliche Kontofreigabe und einen ausdrücklichen Sendeauftrag.")
        }
        .alert("KI-Antworten für dieses Konto erlauben?", isPresented: Binding(get: { replyAccount != nil }, set: { if !$0 { replyAccount = nil } })) {
            Button("Antworten erlauben") {
                if let account = replyAccount { Task { await controller.setReplies(account.id, allowed: true) } }
                replyAccount = nil
            }.accessibilityIdentifier("confirm-assistant-replies")
            Button("Abbrechen", role: .cancel) { replyAccount = nil }
        } message: {
            Text("\(replyAccount?.address.value ?? ""): Der Assistent darf eigene Antwortentwürfe zu freigegebenen Mails erstellen, deren Stand abrufen und das Prüffenster öffnen. Er kann keine persönlichen Entwürfe durchsuchen. Standard ist deine Versandbestätigung in CuMail; Sofortversand braucht eine zusätzliche Kontofreigabe und einen ausdrücklichen Sendeauftrag.")
        }
        .alert("ChatGPT mit den freigegebenen Ordnern verbinden?", isPresented: $confirmCloud) {
            Button("Mit ChatGPT verbinden") { Task { await controller.tunnel.setEnabled(true, localReady: controller.running) } }.accessibilityIdentifier("confirm-assistant-cloud")
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("OpenAI kann die oben freigegebenen Metadaten und optional Mailtexte für deine Anfragen in ChatGPT abrufen. Die Verbindung bleibt bei laufender App aktiv, bis du sie ausschaltest. Dein Mailpasswort wird nicht weitergegeben.") }
        .alert("KI-Lesezugang freigeben?", isPresented: $confirmEnable) {
            Button("Lesezugang einschalten") { Task { await controller.setEnabled(true) } }.accessibilityIdentifier("confirm-assistant-enable")
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Lokale Programme unter deinem macOS-Benutzer können über die Schnittstelle auf die ausgewählten Ordner zugreifen. Ein verbundener Cloud-Assistent erhält die abgerufenen Daten. Du kannst den Zugriff jederzeit widerrufen.") }
        .alert("Mailtexte an Assistenten freigeben?", isPresented: $confirmText) {
            Button("Texte freigeben") { Task { await controller.setText(true) } }.accessibilityIdentifier("confirm-assistant-text")
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Zusätzlich zu Betreff, Absender und Anhangnamen dürfen verbundene Assistenten begrenzten Klartext aus den ausgewählten Ordnern abrufen. Der Abruf markiert Nachrichten nicht als gelesen.") }
    }
}
