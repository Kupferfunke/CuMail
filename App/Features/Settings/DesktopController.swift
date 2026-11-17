import AppKit
import Foundation
import Observation
import Network
import UserNotifications
import ServiceManagement
import MailDomain
import MailApplication

struct DesktopPreferences: Codable, Equatable {
    var automaticSync = false
    var notifications = false
    var notificationPreview = false
    var dockBadge = false
    var excludedSyncAccounts: Set<AccountID> = []
    var excludedNotificationAccounts: Set<AccountID> = []
}
enum DesktopPermission: String { case notRequested, denied, allowed, unavailable }
enum LoginItemState: String { case disabled, enabled, approvalRequired, notFound, unavailable }
struct DesktopNotification: Sendable {
    let identifier: String
    let account: AccountID
    let route: String
    let title: String
    let body: String
}
@MainActor protocol DesktopNotifications {
    func permission() async -> DesktopPermission
    func requestPermission() async throws -> Bool
    func post(_ notification: DesktopNotification) async throws
    func clear()
}
@MainActor protocol DesktopLoginItem {
    var state: LoginItemState { get }
    func setEnabled(_ enabled: Bool) async throws
}
@MainActor final class SystemDesktopNotifications: DesktopNotifications {
    func permission() async -> DesktopPermission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        case .notDetermined: .notRequested
        @unknown default: .unavailable
        }
    }
    func requestPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
    }
    func post(_ notification: DesktopNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title; content.body = notification.body
        content.userInfo = ["route": notification.route, "account": notification.account.description]
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil))
    }
    func clear() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
@MainActor final class SystemDesktopLoginItem: DesktopLoginItem {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .approvalRequired
        case .notRegistered: .disabled
        case .notFound: .notFound
        @unknown default: .unavailable
        }
    }
    func setEnabled(_ enabled: Bool) async throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try await SMAppService.mainApp.unregister() }
    }
}

@MainActor @Observable final class DesktopController {
    private(set) var preferences: DesktopPreferences
    private(set) var permission = DesktopPermission.notRequested
    private(set) var loginState = LoginItemState.disabled
    private(set) var changingPermission = false
    private(set) var changingLogin = false
    private(set) var isRunning = false
    private(set) var networkAvailable = false
    private(set) var sleeping = false
    private(set) var lastSuccess: Date?
    var message: String?
    var userWorkBecameAvailable: () -> Void = {}
    private(set) var authenticationPaused: Set<AccountID> = []
    private(set) var retryingAccounts: Set<AccountID> = []
    private(set) var lastSuccessByAccount: [AccountID: Date] = [:]
    private(set) var badgeCount = 0
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let notifications: (any DesktopNotifications)?
    @ObservationIgnored private let login: (any DesktopLoginItem)?
    @ObservationIgnored private let systemIntegration: Bool
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var schedules: [AccountID: BackgroundSyncSchedule] = [:]
    @ObservationIgnored private var accounts: Set<AccountID> = []
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored var maySync: () -> Bool = { false }
    @ObservationIgnored var synchronize: ((AccountID) async -> BackgroundSyncOutcome)?
    @ObservationIgnored var suspendNetwork: () -> Void = {}

    init(defaults: UserDefaults? = nil, systemIntegration: Bool = false,
         notifications: (any DesktopNotifications)? = nil, login: (any DesktopLoginItem)? = nil,
         clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.systemIntegration = systemIntegration; self.clock = clock
        self.notifications = notifications ?? (systemIntegration ? SystemDesktopNotifications() : nil)
        self.login = login ?? (systemIntegration ? SystemDesktopLoginItem() : nil)
        preferences = defaults?.data(forKey: "desktopPreferences.v1").flatMap { try? JSONDecoder().decode(DesktopPreferences.self, from: $0) } ?? DesktopPreferences()
        if systemIntegration {
            let center = NSWorkspace.shared.notificationCenter
            observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSleeping(true) }
            })
            observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSleeping(false) }
            })
        }
    }
    var status: String {
        if !preferences.automaticSync { return "Automatischer Abgleich ist aus." }
        if stopped { return "Abgleich wird beendet." }
        if !ready { return "Wartet auf den lokalen Index." }
        if sleeping { return "Pausiert, während der Mac schläft." }
        if accounts.subtracting(preferences.excludedSyncAccounts).isEmpty { return "Kein Konto für den automatischen Abgleich gewählt." }
        if !networkAvailable { return "Offline – wartet auf eine Verbindung." }
        if isRunning { return "Posteingänge werden abgeglichen …" }
        if !authenticationPaused.isEmpty { return "Einzelne Konten benötigen eine erneute Anmeldung. Andere Konten bleiben aktiv." }
        if !retryingAccounts.isEmpty { return "Einzelne Konten warten nach einem Fehler auf den nächsten Versuch. Andere Konten bleiben aktiv." }
        return "Aktiv · ungefähr alle zwei Minuten, solange die App läuft."
    }
    func update(accounts: Set<AccountID>, unread: Int, ready: Bool) {
        self.accounts = accounts; self.ready = ready; badgeCount = max(0, unread)
        schedules = schedules.filter { accounts.contains($0.key) }
        authenticationPaused.formIntersection(accounts)
        retryingAccounts.formIntersection(accounts)
        lastSuccessByAccount = lastSuccessByAccount.filter { accounts.contains($0.key) }
        for account in accounts where schedules[account] == nil { schedules[account] = BackgroundSyncSchedule(now: clock().addingTimeInterval(5)) }
        updateBadge(); configureMonitor(); schedule()
    }
    func setAutomaticSync(_ value: Bool) {
        preferences.automaticSync = value; persist()
        if !value { task?.cancel() }
        configureMonitor(); schedule()
    }
    func setAccountSync(_ account: AccountID, enabled: Bool) {
        if enabled { preferences.excludedSyncAccounts.remove(account) } else { preferences.excludedSyncAccounts.insert(account); task?.cancel() }
        persist(); schedule()
    }
    func setAccountNotifications(_ account: AccountID, enabled: Bool) {
        if enabled { preferences.excludedNotificationAccounts.remove(account) } else { preferences.excludedNotificationAccounts.insert(account); notifications?.clear() }
        persist()
    }
    func setBadge(_ value: Bool) { preferences.dockBadge = value; persist(); updateBadge() }
    func setPreview(_ value: Bool) { preferences.notificationPreview = value; persist(); if !value { notifications?.clear() } }
    func setNotifications(_ value: Bool) async {
        guard !changingPermission else { return }
        if !value { preferences.notifications = false; persist(); notifications?.clear(); return }
        guard let notifications else { message = "Systemmitteilungen sind in diesem Testlauf nicht verfügbar."; return }
        changingPermission = true; defer { changingPermission = false }
        do {
            let granted = try await notifications.requestPermission()
            permission = await notifications.permission()
            preferences.notifications = granted; persist()
            message = granted ? "Mitteilungen aktiviert. Bereits bekannte Nachrichten werden nicht erneut gemeldet." : "Mitteilungen sind in macOS nicht freigegeben. Du kannst sie in den Systemeinstellungen erlauben."
        } catch { message = "macOS-Mitteilungen konnten nicht aktiviert werden." }
    }
    func refreshSystemStatus() async {
        permission = await notifications?.permission() ?? .unavailable
        loginState = login?.state ?? .unavailable
    }
    func setLogin(_ value: Bool) async {
        guard !changingLogin, let login else { return }
        changingLogin = true; defer { changingLogin = false }
        do { try await login.setEnabled(value); message = nil }
        catch { message = "Der Start bei Anmeldung konnte nicht geändert werden. Bitte unter macOS → Allgemein → Anmeldeobjekte prüfen." }
        loginState = login.state
    }
    func deliver(_ delta: InboxNotificationDelta) async {
        guard preferences.notifications, !preferences.excludedNotificationAccounts.contains(delta.newest.accountID),
              accounts.contains(delta.newest.accountID), let notifications else { return }
        permission = await notifications.permission()
        guard permission == .allowed, !Task.isCancelled, preferences.notifications,
              !preferences.excludedNotificationAccounts.contains(delta.newest.accountID), accounts.contains(delta.newest.accountID) else { return }
        let item = delta.newest
        let title = preferences.notificationPreview ? Self.safePreview(item.sender.displayName) : "CuMail"
        let body = preferences.notificationPreview ? Self.safePreview(item.subject) : (delta.count == 1 ? "Eine neue Nachricht im Posteingang." : "\(delta.count) neue Nachrichten. Öffnet die neueste.")
        let event = DesktopNotification(identifier: "mail.\(item.accountID).\(item.id)", account: item.accountID,
            route: MailRoute.message(item.id).url.absoluteString, title: title, body: body)
        do { try await notifications.post(event) }
        catch { message = "Eine Mitteilung konnte nicht angezeigt werden. Die Nachricht bleibt im Posteingang." }
    }
    static func safePreview(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value) }.prefix(160))
    }
    func setNetworkAvailable(_ value: Bool) {
        networkAvailable = value
        if !value { task?.cancel() }
        else { userWorkBecameAvailable() }
        schedule()
    }
    func setSleeping(_ value: Bool) {
        sleeping = value
        if value { task?.cancel(); suspendNetwork() }
        else { userWorkBecameAvailable() }
        schedule()
    }
    func record(_ outcome: BackgroundSyncOutcome, account: AccountID, now: Date? = nil) {
        var state = schedules[account] ?? BackgroundSyncSchedule(now: now ?? clock())
        state.finish(outcome, now: now ?? clock(), jitter: systemIntegration ? Double.random(in: 0...30) : 0)
        schedules[account] = state
        if state.authenticationRequired { authenticationPaused.insert(account) } else { authenticationPaused.remove(account) }
        switch outcome {
        case .success:
            lastSuccess = now ?? clock(); lastSuccessByAccount[account] = lastSuccess
            retryingAccounts.remove(account)
        case .retry: retryingAccounts.insert(account)
        case .authenticationRequired: retryingAccounts.remove(account)
        case .cancelled: break
        }
        schedule()
    }
    func runDue(now: Date? = nil) async {
        guard preferences.automaticSync, ready, networkAvailable, !sleeping, !stopped, !isRunning, maySync(), let synchronize else { return }
        isRunning = true; defer { isRunning = false; schedule() }
        for account in accounts.sorted(by: { $0.description < $1.description }) {
            guard !Task.isCancelled, preferences.automaticSync, !sleeping, networkAvailable, !stopped, maySync() else { break }
            guard !preferences.excludedSyncAccounts.contains(account), var state = schedules[account], state.begin(now: now ?? clock()) else { continue }
            schedules[account] = state
            let outcome = await synchronize(account)
            record(outcome, account: account, now: now)
        }
    }
    func stop() async {
        stopped = true; timer?.invalidate(); timer = nil; monitor?.cancel(); monitor = nil
        let active = task; active?.cancel(); await active?.value; task = nil
    }
    func cancelCurrent() { task?.cancel() }
    func resume() { stopped = false; configureMonitor(); schedule() }
    private func persist() { if let data = try? JSONEncoder().encode(preferences) { defaults?.set(data, forKey: "desktopPreferences.v1") } }
    private func updateBadge() {
        guard systemIntegration else { return }
        NSApp.dockTile.badgeLabel = preferences.dockBadge && badgeCount > 0 ? (badgeCount > 999 ? "999+" : String(badgeCount)) : nil
    }
    private func configureMonitor() {
        guard systemIntegration else { return }
        guard preferences.automaticSync, !stopped else { monitor?.cancel(); monitor = nil; return }
        guard monitor == nil else { return }
        let path = NWPathMonitor(); monitor = path
        path.pathUpdateHandler = { [weak self] value in
            let available = value.status == .satisfied
            Task { @MainActor in self?.setNetworkAvailable(available) }
        }
        path.start(queue: DispatchQueue(label: "ch.kupferfunke.MikeMailHub.reachability", qos: .utility))
    }
    var permitsUserReads: Bool { !sleeping && !stopped }
    func requestCycle() {
        guard task == nil else { return }
        task = Task { await runDue(); task = nil; schedule() }
    }
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard systemIntegration, preferences.automaticSync, ready, networkAvailable, !sleeping, !stopped, !isRunning else { return }
        let due = schedules.filter { accounts.contains($0.key) && !preferences.excludedSyncAccounts.contains($0.key) && !$0.value.authenticationRequired }.values.map(\.nextAttempt).min()
        guard let due else { return }
        let delay = max(maySync() ? 5 : 30, due.timeIntervalSince(clock()))
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.requestCycle()
            }
        }
        timer?.tolerance = min(15, delay / 4)
    }
}
