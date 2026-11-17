import SwiftUI
import AppKit
import MailDomain

struct DesktopSettingsView: View {
    @Bindable var controller: DesktopController
    let accounts: [MailAccount]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Post, wenn du sie brauchst.").font(Brand.headline(25))
                Toggle("Posteingänge automatisch abgleichen", isOn: Binding(get: { controller.preferences.automaticSync }, set: controller.setAutomaticSync))
                    .accessibilityIdentifier("background-sync")
                Text(controller.status).font(.system(size: 12)).foregroundStyle(.secondary).accessibilityIdentifier("background-status")
                Text("Ein geschlossenes Fenster lässt die App weiterlaufen. Nach «Beenden», im Ruhezustand oder ohne Verbindung findet kein automatischer Abgleich statt. Gmail berücksichtigt auch bereits erfasste Labels. Wartezeiten können bei Fehlern länger werden.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let date = controller.lastSuccess { Text("Letzter erfolgreicher Abgleich: \(date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 11)) }
                Divider()
                Toggle("Neue Nachrichten als macOS-Mitteilung anzeigen", isOn: Binding(get: { controller.preferences.notifications }, set: { value in Task { await controller.setNotifications(value) } }))
                    .disabled(controller.changingPermission).accessibilityIdentifier("desktop-notifications")
                Text(permissionText).font(.system(size: 11)).foregroundStyle(.secondary).accessibilityIdentifier("notification-permission")
                Toggle("Absender und Betreff in Mitteilungen anzeigen", isOn: Binding(get: { controller.preferences.notificationPreview }, set: controller.setPreview))
                    .disabled(!controller.preferences.notifications).accessibilityIdentifier("notification-preview")
                Text("Standardmässig bleiben Absender und Betreff verborgen. Pro Konto erscheint höchstens eine zusammengefasste Mitteilung je Abgleich; sie öffnet die neueste zugehörige Nachricht. Bereits bekannte und erstmals importierte Nachrichten bleiben still.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("Ungelesene Posteingänge im Dock zählen", isOn: Binding(get: { controller.preferences.dockBadge }, set: controller.setBadge))
                    .accessibilityIdentifier("dock-badge")
                Text("\(controller.badgeCount) ungelesen in deinen abgeglichenen Posteingängen. Andere Ordner zählen nicht mit.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).accessibilityIdentifier("badge-count")
                if !accounts.isEmpty {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                        GridRow { Text("Konto"); Text("Abgleich"); Text("Mitteilung") }.font(.system(size: 11, weight: .semibold))
                        ForEach(accounts) { account in
                            GridRow {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(account.name).lineLimit(2)
                                    if controller.authenticationPaused.contains(account.id) { Text("Anmeldung nötig").font(.system(size: 10)).foregroundStyle(.secondary) }
                                    else if controller.retryingAccounts.contains(account.id) { Text("Wartet nach Verbindungsfehler").font(.system(size: 10)).foregroundStyle(.secondary) }
                                    else if let date = controller.lastSuccessByAccount[account.id] {
                                        Text("Abgleich \(date.formatted(date: .omitted, time: .shortened))").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }
                                Toggle("\(account.name) automatisch abgleichen", isOn: Binding(get: { !controller.preferences.excludedSyncAccounts.contains(account.id) }, set: { controller.setAccountSync(account.id, enabled: $0) }))
                                    .labelsHidden().accessibilityIdentifier("background-account-\(account.id)")
                                Toggle("\(account.name) melden", isOn: Binding(get: { !controller.preferences.excludedNotificationAccounts.contains(account.id) }, set: { controller.setAccountNotifications(account.id, enabled: $0) }))
                                    .labelsHidden().accessibilityIdentifier("notification-account-\(account.id)")
                            }
                        }
                    }.font(.system(size: 12))
                }
                Divider()
                Toggle("CuMail bei der Anmeldung öffnen", isOn: Binding(get: { controller.loginState == .enabled || controller.loginState == .approvalRequired }, set: { value in Task { await controller.setLogin(value) } }))
                    .disabled(controller.changingLogin || controller.loginState == .unavailable).accessibilityIdentifier("login-item")
                Text(loginText).font(.system(size: 11)).foregroundStyle(.secondary).accessibilityIdentifier("login-status")
                if let message = controller.message { Text(message).font(.system(size: 11)).accessibilityIdentifier("desktop-message") }
            }.padding(24)
        }
        .task { await controller.refreshSystemStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await controller.refreshSystemStatus() } }
    }
    private var permissionText: String {
        switch controller.permission {
        case .notRequested: "macOS wird erst beim Einschalten um Erlaubnis gefragt."
        case .allowed: "macOS erlaubt Mitteilungen. Fokus und Systemeinstellungen können ihre Anzeige begrenzen."
        case .denied: "In macOS nicht freigegeben. Unter Systemeinstellungen → Mitteilungen → CuMail ändern."
        case .unavailable: "Mitteilungen sind in diesem Lauf nicht verfügbar."
        }
    }
    private var loginText: String {
        switch controller.loginState {
        case .disabled: "Aus. CuMail startet erst, wenn du die App öffnest."
        case .enabled: "Aktiv. macOS öffnet diese App bei deiner nächsten Anmeldung."
        case .approvalRequired: "macOS benötigt noch deine Freigabe unter Allgemein → Anmeldeobjekte."
        case .notFound: "macOS meldet noch keinen registrierten App-Start. Einschalten versucht die Registrierung."
        case .unavailable: "Für diesen App-Build ist der Start bei Anmeldung nicht verfügbar."
        }
    }
}
