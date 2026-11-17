import SwiftUI
import AppKit
import MailDemo
import MailDomain
import UserNotifications

@main
struct MikeMailHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var model: InboxModel
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @Environment(\.openWindow) private var openWindow
    init() {
        AppResources.registerFonts()
        do {
            var dataset = try DemoDataset.empty()
            #if DEBUG
            if let raw = ProcessInfo.processInfo.environment["MIKE_MAIL_UI_TEST_ID"], UUID(uuidString: raw) != nil {
                dataset = try SyntheticFixtures.make()
            }
            #endif
            _model = State(initialValue: InboxModel(dataset: dataset, persistent: true, initialDestination: dataset.snapshot.accounts.isEmpty ? .dashboard : .inbox))
        } catch { fatalError("Invalid workspace: \(error)") }
    }
    var body: some Scene {
        Window("CuMail", id: "inbox") {
            InboxView(model: model)
                .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
                .onAppear {
                    delegate.prepareToQuit = { await model.prepareToQuit() }
                    delegate.showInbox = { openWindow(id: "inbox"); NSApp.activate(ignoringOtherApps: true) }
                }
                .task {
                    await model.start()
                    delegate.installURLHandler { url, account in
                        openWindow(id: "inbox"); NSApp.activate(ignoringOtherApps: true)
                        Task { await model.handleAppURL(url, expectedAccount: account) }
                    }
                }
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("CuMail beenden") { delegate.requestTermination() }.keyboardShortcut("q")
            }
            CommandGroup(replacing: .newItem) {
                Button("Neue Nachricht") { model.compose() }.keyboardShortcut("n").disabled(!model.canCompose)
                Menu("Neue Nachricht von") {
                    ForEach(model.accounts) { account in Button(account.address.value) { model.compose(account: account.id) }.disabled(!model.canCompose) }
                }
                Button("Entwürfe auf diesem Mac") { model.destination = .localDrafts }.keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandMenu("Postfach") {
                Button("Dashboard") { model.destination = .dashboard }.keyboardShortcut("0", modifiers: .command)
                Button("Alle Posteingänge") { model.destination = .inbox }.keyboardShortcut("1", modifiers: .command)
                Button("Ungelesen") { model.destination = .unread }.keyboardShortcut("2", modifiers: .command)
                Button("Favoriten") { model.destination = .flagged }.keyboardShortcut("3", modifiers: .command)
                Divider()
                Button("Suchen") { NotificationCenter.default.post(name: .focusMailSearch, object: nil) }.keyboardShortcut("f")
                Divider()
                Button("Synchronisieren") { model.synchronize() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.networkBusy || model.realAccountIDs.isEmpty)
                Button("Lesestatus umschalten") { if model.selection.count > 1 { model.mutateSelection(model.selectedMessages.contains(where: \.isUnread) ? .read : .unread) } else if let message = model.selectedMessage { model.mutate(.read(message.isUnread)) } }
                    .keyboardShortcut("u", modifiers: [.command, .shift]).disabled(model.selection.count > 1 ? !model.canMutateSelection : !model.canMutate)
                Button("Favorit umschalten") { if model.selection.count > 1 { model.mutateSelection(model.selectedMessages.allSatisfy(\.isFlagged) ? .unflag : .flag) } else if let message = model.selectedMessage { model.mutate(.flagged(!message.isFlagged)) } }
                    .keyboardShortcut("l", modifiers: [.command, .shift]).disabled(model.selection.count > 1 ? !model.canMutateSelection : !model.canMutate)
                Button("Letzte Mailaktion rückgängig") { model.undoLastMailAction() }
                    .keyboardShortcut("z", modifiers: [.command, .option]).disabled(model.lastMailAction?.canUndo != true || model.networkBusy || model.storageBusy)
                Button("Gespräche gruppieren") { model.groupConversations.toggle() }.keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Ansicht zurücksetzen") { model.searchText = ""; model.scenario = .standard; model.destination = .inbox }
            }
        }
        Settings { SettingsView(model: model) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var showInbox: (() -> Void)?
    private var urlHandler: ((URL, AccountID?) -> Void)?
    private var pendingURLs: [(URL, AccountID?)] = []
    func installURLHandler(_ handler: @escaping (URL, AccountID?) -> Void) {
        urlHandler = handler
        let queued = pendingURLs; pendingURLs = []
        for (url, account) in queued { handler(url, account) }
    }
    private func receiveURL(_ url: URL, account: AccountID? = nil) {
        guard url.absoluteString.utf8.count <= 8192 else { return }
        if let urlHandler { urlHandler(url, account) }
        else if pendingURLs.count < 8 { pendingURLs.append((url, account)) }
    }
    var prepareToQuit: (() async -> Bool)?
    private var preparingTermination = false
    private var terminationReady = false
    // AppKit can ignore terminate: while a SwiftUI sheet is presented. The menu
    // command closes our preview and flushes drafts before asking AppKit to quit.
    func requestTermination() {
        guard !preparingTermination else { return }
        preparingTermination = true
        Task {
            let ready = await prepareToQuit?() ?? true
            preparingTermination = false
            guard ready else { return }
            terminationReady = true
            NSApp.terminate(nil)
            terminationReady = false
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls.prefix(8) { receiveURL(url) }
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier == "ch.kupferfunke.MikeMailHub" { UNUserNotificationCenter.current().delegate = self }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let raw = response.notification.request.content.userInfo["route"] as? String,
              let accountString = response.notification.request.content.userInfo["account"] as? String,
              let account = try? AccountID(string: accountString), let url = URL(string: raw), url.scheme == "mikemail" else { return }
        await MainActor.run { self.receiveURL(url, account: account) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list] }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationReady { return .terminateNow }
        guard !preparingTermination else { return .terminateCancel }
        guard let prepareToQuit else { return .terminateNow }
        preparingTermination = true
        Task {
            let saved = await prepareToQuit()
            preparingTermination = false
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let url = AppResources.url("AppIcon", extension: "png", folder: "Brand"), let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showInbox?() }
        return true
    }
}
