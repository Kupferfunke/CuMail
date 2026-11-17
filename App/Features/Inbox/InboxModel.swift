import SwiftUI
import Observation
import MailDomain
import MailApplication
import MailDemo
import MailPersistence
import MailSecurity
import MailIMAP
import MailGoogle
import MailRendering
import MailMCP

enum SidebarDestination: Hashable {
    case dashboard, inbox, unread, flagged, localDrafts, role(FolderRole), account(AccountID), folder(FolderID)

    /// Navigation and sidebar totals must describe the same message set.
    var messageFilter: MessageFilter {
        var filter = MessageFilter()
        switch self {
        case .inbox: filter.role = .inbox
        case .unread: filter.unreadOnly = true; filter.role = .inbox
        case .flagged: filter.flaggedOnly = true
        case .dashboard, .localDrafts: break // Separate overview / own working copies.
        case .role(let role): filter.role = role
        case .account(let id): filter.accountID = id
        case .folder(let id): filter.folderID = id
        }
        return filter
    }
}

/// Remembers list order before a move. Surviving rows below the selection win;
/// at a page boundary an older newly loaded row wins, then the nearest row above.
struct MailMoveContinuation {
    let anchor: MailMessage
    let following: [MessageID]
    let preceding: [MessageID]
    let loadedCount: Int
    init?(rows: [MailMessage], selection: Set<MessageID>, loadedCount: Int) {
        guard let index = rows.lastIndex(where: { selection.contains($0.id) }) else { return nil }
        anchor = rows[index]
        following = rows.dropFirst(index + 1).filter { !selection.contains($0.id) }.map(\.id)
        preceding = rows.prefix(index).reversed().filter { !selection.contains($0.id) }.map(\.id)
        self.loadedCount = max(20, loadedCount)
    }
    func next(in rows: [MailMessage]) -> MessageID? {
        let available = Set(rows.map(\.id))
        if let next = following.first(where: available.contains) { return next }
        if let next = rows.first(where: { $0.receivedAt < anchor.receivedAt ||
            ($0.receivedAt == anchor.receivedAt && $0.id.description > anchor.id.description) }) { return next.id }
        return preceding.first(where: available.contains) ?? rows.first?.id
    }
}

struct MailSynchronizationProgress {
    enum State { case running, completed, paused, failed }
    let accountID: AccountID
    let accountName: String
    let startedAt: Date
    var lastProgressAt: Date
    var state: State = .running
    var phase = "Verbindung prüfen"
    var detail = ""
    var processed = 0
    var total: Int?
    var estimatedTotal = false
    var waitingUntil: Date?
    var explanation: String?
    init(account: MailAccount, now: Date = Date()) {
        accountID = account.id; accountName = account.name; startedAt = now; lastProgressAt = now
    }
    var isRunning: Bool { state == .running }
    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(processed) / Double(total)))
    }
    mutating func receive(_ event: GmailSyncProgress, now: Date = Date()) {
        lastProgressAt = now; waitingUntil = nil; state = .running
        switch event {
        case .checking: phase = "Verbindung mit Google prüfen"; detail = ""; total = nil
        case .folders(let count): phase = "Labels und Ordner aktualisieren"; detail = "\(count) Ordner übernommen"; total = nil
        case .discovering(let pages, let count):
            phase = "Änderungen seit dem letzten Abgleich prüfen"; total = nil
            detail = pages == 0 ? "Änderungsverlauf von Google abrufen" : "\(pages) Abschnitte geprüft · \(count.formatted()) Nachrichten zu aktualisieren"
        case .updating(let count, let maximum):
            phase = "Nachrichten und Label-Zuordnungen aktualisieren"
            processed = count; total = maximum; estimatedTotal = false
            detail = "\(count.formatted()) von \(maximum.formatted()) Nachrichten geprüft"
        case .scanning(let count, let maximum):
            phase = "Gesamten Mailbestand abgleichen"
            processed = count; total = maximum; estimatedTotal = true
            detail = maximum.map { "\(count.formatted()) von ca. \($0.formatted()) Nachrichten geprüft" } ?? "\(count.formatted()) Nachrichten geprüft · Gesamtzahl noch unbekannt"
        case .fullScanRequired:
            explanation = "Der Änderungsverlauf reicht nicht aus. CuMail prüft deshalb den gesamten Bestand."
        case .finishing: phase = "Abgleich abschliessen"; detail = "Zähler und gespeicherten Stand aktualisieren"; total = nil
        case .waiting(let seconds):
            waitingUntil = now.addingTimeInterval(TimeInterval(seconds))
        }
    }
    mutating func finish(error: String? = nil, cancelled: Bool = false, now: Date = Date()) {
        state = cancelled ? .paused : error == nil ? .completed : .failed
        phase = cancelled ? "Abgleich pausiert" : error == nil ? "Abgleich abgeschlossen" : "Abgleich unterbrochen"
        detail = error ?? (cancelled ? "Der gespeicherte Stand bleibt erhalten." : "Ordner, Labels und Nachrichten sind aktualisiert.")
        waitingUntil = nil; lastProgressAt = now
    }
    func timing(at now: Date) -> String {
        let seconds = max(0, Int((isRunning ? now : lastProgressAt).timeIntervalSince(startedAt)))
        let elapsed = seconds < 60 ? "\(seconds) Sek." : "\(seconds / 60) Min. \(seconds % 60) Sek."
        if let waitingUntil {
            let remaining = max(0, Int(ceil(waitingUntil.timeIntervalSince(now))))
            return remaining > 0 ? "Google begrenzt den Abruf · weiter in \(remaining) Sek." : "Warte auf die Antwort von Google …"
        }
        guard isRunning else { return "\(lastProgressAt.formatted(date: .omitted, time: .shortened)) · Dauer \(elapsed)" }
        let silence = max(0, Int(now.timeIntervalSince(lastProgressAt)))
        return silence >= 15 ? "Seit \(elapsed) · letzte Rückmeldung vor \(silence) Sek." : "Läuft seit \(elapsed)"
    }
}

@MainActor @Observable
final class ContentIndexController {
    var progress: [AccountID: ContentIndexProgress] = [:]
    var activeAccount: AccountID?
    var notes: [AccountID: String] = [:]
    private var blockedBudget: [AccountID: String] = [:]
    private var retryAfter: [AccountID: Date] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var repository: EncryptedMailRepository?
    @ObservationIgnored private var mayRun: (() -> Bool)?
    @ObservationIgnored private var reader: ((MailMessage) async throws -> MailBody)?
    func configure(repository: EncryptedMailRepository, mayRun: @escaping () -> Bool, read: @escaping (MailMessage) async throws -> MailBody) {
        self.repository = repository; self.mayRun = mayRun; reader = read
    }
    func refresh() async {
        guard let repository else { return }
        var values: [AccountID: ContentIndexProgress] = [:]
        for account in (try? await repository.activeAccountIDs()) ?? [] { values[account] = try? await repository.contentIndexProgress(account: account) }
        progress = values
    }
    func start() {
        guard task == nil, let repository, let reader else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                var didWork = false
                for account in progress.keys.sorted(by: { $0.description < $1.description }) {
                    guard !Task.isCancelled, mayRun?() == true else { break }
                    if let retry = retryAfter[account], retry > Date() { continue }
                    var attempted: MailMessage?
                    do {
                        guard let status = progress[account], blockedBudget[account] != "\(status.bytes):\(status.budget)" else { continue }
                        guard let message = try await repository.nextContentIndexMessage(account: account) else { continue }
                        guard let status = progress[account], status.bytes < status.budget else { notes[account] = "Textbudget erreicht. In den Kontoeinstellungen anpassen."; continue }
                        attempted = message; activeAccount = account; didWork = true
                        let body = try await reader(message)
                        try Task.checkCancellation()
                        let text = body.format == .html ? try await Task.detached { try MailHTMLSanitizer.sanitize(body.text).plainText }.value : body.text
                        try Task.checkCancellation()
                        try await repository.storeExtract(text, for: message.id, account: account, source: body.format == .html ? .sanitizedHTML : .plainText)
                        notes[account] = nil
                    } catch is CancellationError { break }
                    catch LocalStoreFailure.budgetExceeded { if let status = progress[account] { blockedBudget[account] = "\(status.bytes):\(status.budget)" }; notes[account] = "Textbudget erreicht. In den Kontoeinstellungen anpassen." }
                    catch {
                        if let message = attempted {
                            let issue: ContentIndexIssue = (error as? IMAPFailure) == .noPlainText ? .noText : (error as? IMAPFailure) == .contentTooLarge || error is HTMLRenderingFailure ? .tooLarge : .unavailable
                            try? await repository.recordContentIndexIssue(issue, message: message.id, account: account)
                            if issue == .unavailable { retryAfter[account] = Date().addingTimeInterval(60) }
                        }
                        notes[account] = error is KeychainFailure ? "Anmeldung prüfen. Es wird kein Passwortdialog im Hintergrund geöffnet." : "Einzelne Texte werden später erneut versucht."
                    }
                    activeAccount = nil
                }
                activeAccount = nil
                do { try await Task.sleep(for: didWork ? .milliseconds(300) : .seconds(5)) } catch { break }
            }
            self?.activeAccount = nil
        }
    }
    func stop() async { task?.cancel(); await task?.value; task = nil; activeAccount = nil }
    func retry(account: AccountID) async {
        try? await repository?.retryContentIndex(account: account)
        notes[account] = nil; blockedBudget[account] = nil; retryAfter[account] = nil; await refresh()
    }
}
enum DemoScenario: String, CaseIterable, Identifiable {
    case standard = "Normalbetrieb", noAccounts = "Keine Konten", empty = "Leerer Posteingang"
    case offline = "Offline", expired = "Anmeldung abgelaufen", error = "Ladefehler"
    var id: String { rawValue }
}
enum LocalDataAction {
    case save(AccountSettings), remove(AccountID), clearTexts(AccountID), rebuild, clear, restore
}

@MainActor @Observable
final class InboxModel {
    let desktop: DesktopController
    let assistant: AssistantController
    let contentIndexer = ContentIndexController()
    @ObservationIgnored private var mailActions: MailActions?
    @ObservationIgnored private var markReadTask: Task<Void, Never>?
    @ObservationIgnored private var markReadSuppressedMessage: MessageID?
    var lastMailAction: MailActionReceipt?
    private var assistantReading = false
    var routeError: String?
    @ObservationIgnored private var navigatingRoute = false
    @ObservationIgnored private var routeGeneration = 0
    @ObservationIgnored private var notificationBaselinePrimed = false
    @ObservationIgnored private var requestedContentAfterSync: MessageID?
    var accounts: [MailAccount] = []
    var folders: [MailFolder] = []
    var messages: [MailMessage] = []
    var selection: Set<MessageID> = [] {
        didSet {
            // SwiftUI can write back the same list selection when detail focus changes.
            guard selection != oldValue else { return }
            selectionRevision += 1
            markReadSuppressedMessage = nil
            conversationSelection = nil; loadContent(); loadConversation()
        }
    }
    var conversationSelection: MessageID? { didSet { if oldValue != conversationSelection { selectionRevision += 1 } } }
    @ObservationIgnored private var selectionRevision = 0
    var destination: SidebarDestination = .inbox { didSet { reload() } }
    var dashboard: MailDashboard?
    var searchText = "" { didSet { if searchText != oldValue { reload() } } }
    var isOnlineSearch = false
    var searchInvalid = false
    var onlineCheckedAt: Date?
    var onlineFolderTotal: Int?
    var scenario: DemoScenario = .standard { didSet { reload() } }
    var content = ""
    var safeHTML: SafeMailHTML?
    var showHTML = true { didSet { if oldValue != showHTML && !settingBodyFormat { loadContent() } } }
    var htmlAvailable: Bool?
    @ObservationIgnored private var settingBodyFormat = false
    @ObservationIgnored private var contentMessageID: MessageID?
    var groupConversations = true
    var conversation: [MailMessage] = []
    var conversationCursor: String?
    var conversationLoading = false
    var pendingAccounts: Set<AccountID> = []
    @ObservationIgnored private var conversationTask: Task<Void, Never>?

    var contentLoading = false
    var contentError: String?
    var contentNote: String?
    var error: String?
    var isLoading = false
    var coverage: SearchCoverage?
    var nextCursor: String?
    var inboxCount = 0
    var unreadCount = 0
    var accountUnread: [AccountID: Int] = [:]
    var folderOrders: [AccountID: [FolderID]] = [:]
    var accountSettings: [AccountID: AccountSettings] = [:]
    var storageSummary: LocalIndexSummary?
    var storageBusy = false
    var storageMessage: String?
    var storageError = false
    var backupInfo: LocalBackupInfo?
    var backupBusy = false
    var backupMessage: String?
    var backupFailed = false
    var dataLocation: URL?
    var backupLocation: URL?
    var dataIncludedInBackups = false
    @ObservationIgnored private var backupTask: Task<Void, Never>?
    @ObservationIgnored private var lastBackupAttempt: Date?
    var persistentStoreReady = false
    @ObservationIgnored private var preparingToQuit = false
    var isDemoMode: Bool { !dataset.snapshot.accounts.isEmpty }
    var networkBusy = false
    var synchronizationActive = false
    @ObservationIgnored private var manualSyncDestination: SidebarDestination?
    @ObservationIgnored private var resumeSyncAfterActions: SidebarDestination?
    var mailActionProcessing = false
    var processingMailActionID: UUID?
    var queuedMailActions: [MailActionReceipt] = []
    var mailActionSubjects: [UUID: [String]] = [:]
    var mailActionQueueError: String?
    var checkingMailActionID: UUID?
    @ObservationIgnored private var attemptedMailActionChecks = Set<UUID>()
    @ObservationIgnored private var mailActionQueueTask: Task<Void, Never>?
    @ObservationIgnored private var enqueueTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var assistantEnqueueTasks: [UUID: Task<MailActionReceipt, Error>] = [:]
    private var assistantEnqueuingMessages: [UUID: Set<MessageID>] = [:]
    private var enqueuingMessageIDs: Set<MessageID> = []
    @ObservationIgnored private var actionSelections: [UUID: (destination: SidebarDestination, search: String, selection: Int, continuation: MailMoveContinuation?)] = [:]
    var syncingAccountID: AccountID?
    var synchronizationProgress: MailSynchronizationProgress?
    var networkMessage: String?
    var networkFailed = false
    var gmailConfigurations: [AccountID: GmailConfiguration] = [:]
    var realAccountIDs: Set<AccountID> { imapAccountIDs.union(gmailConfigurations.keys) }
    @ObservationIgnored private var googleAuthentication: GoogleAuthentication?
    @ObservationIgnored private var gmail: GmailService?
    @ObservationIgnored private var gmailSubmission: GmailSubmission?
    var imapAccountIDs: Set<AccountID> = []
    var syncSummaries: [FolderID: IMAPSyncSummary] = [:]
    var keychainAccessNeeded = false
    var savedDrafts: [LocalDraft] = []
    var selectedDraftID: UUID?
    var draftSearchText = ""
    var showingSubmissionHistory = false { didSet { selectedDraftID = nil } }
    var draftListError: String?
    @ObservationIgnored private var draftListTask: Task<Void, Never>?
    var visibleDrafts: [LocalDraft] {
        savedDrafts.filter { draft in
            draft.status.editable != showingSubmissionHistory && (draftSearchText.isEmpty ||
                [draft.subject, draft.to, draft.sender, draft.body].contains { $0.localizedStandardContains(draftSearchText) })
        }
    }
    var selectedDraft: LocalDraft? { visibleDrafts.first { $0.id == selectedDraftID } }
    var attachmentController: AttachmentController?
    var compositionBusy = false
    private var assistantSending = false
    @ObservationIgnored private var submission: SubmissionService?
    @ObservationIgnored private var service: InboxService?
    @ObservationIgnored private let contentSource: any PlainTextContentSource
    @ObservationIgnored private var scope: AccessScope
    @ObservationIgnored private let dataset: DemoDataset
    @ObservationIgnored private let persistent: Bool
    @ObservationIgnored private var workspace: LocalMailWorkspace?
    @ObservationIgnored private var keychain: KeychainStore?
    @ObservationIgnored private var imap: IMAPService?
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var contentTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(dataset: DemoDataset, persistent: Bool = false, initialDestination: SidebarDestination = .inbox, workspace: LocalMailWorkspace? = nil, assistant: AssistantController? = nil, gmail: GmailService? = nil) {
        let repository = dataset.repository()
        service = workspace.map { InboxService(repository: $0.repository) } ?? (persistent ? nil : InboxService(repository: repository))
        self.workspace = workspace; persistentStoreReady = workspace != nil
        self.gmail = gmail
        contentSource = repository; scope = dataset.scope
        self.dataset = dataset; self.persistent = persistent
        destination = initialDestination
        var desktopDefaults: UserDefaults? = persistent ? .standard : nil
        #if DEBUG
        if persistent, let raw = ProcessInfo.processInfo.environment["MIKE_MAIL_UI_TEST_ID"], let token = UUID(uuidString: raw) {
            desktopDefaults = UserDefaults(suiteName: "ch.kupferfunke.MikeMailHub.uitests.\(token)")
        }
        #endif
        desktop = DesktopController(defaults: desktopDefaults, systemIntegration: persistent && Bundle.main.bundleIdentifier == "ch.kupferfunke.MikeMailHub")
        self.assistant = assistant ?? AssistantController(defaults: desktopDefaults)
        desktop.maySync = { [weak self] in self?.canBackgroundSync == true }
        desktop.synchronize = { [weak self] account in await self?.backgroundSynchronize(account) ?? .cancelled }
        desktop.suspendNetwork = { [weak self] in
            if self?.networkBusy == true { self?.cancelSynchronization() }
            Task { [weak self] in await self?.contentIndexer.stop(); self?.contentIndexer.start() }
        }
        desktop.userWorkBecameAvailable = { [weak self] in self?.resumeQueuedMailActions() }
    }
    var selectedMessage: MailMessage? {
        guard selection.count == 1, let base = messages.first(where: { selection.contains($0.id) }) else { return nil }
        if let id = conversationSelection, let member = conversation.first(where: { $0.id == id && $0.accountID == base.accountID && $0.threadID == base.threadID }) { return member }
        return base
    }
    func openAttachment(_ attachment: AttachmentMetadata) {
        guard let message = selectedMessage, !storageBusy, !networkBusy, !contentLoading,
              let account = account(for: message) else { return }
        attachmentController?.open(message: message, attachment: attachment, scope: scope, isDemo: account.status == .demo)
    }
    func prepareToQuit() async -> Bool {
        guard !assistantSending else {
            networkMessage = "Eine ausdrücklich angeforderte Nachricht wird gerade versendet. Bitte warte auf das Ergebnis."
            return false
        }
        preparingToQuit = true
        markReadTask?.cancel()
        let backupLoop = backupTask
        backupLoop?.cancel()
        await backupLoop?.value
        backupTask = nil
        while backupBusy { try? await Task.sleep(for: .milliseconds(100)) }
        // Finish admissions before suspending their live MCP authorization.
        // Once accepted, jobs carry their durable, independently revocable grant.
        for task in Array(enqueueTasks.values) { await task.value }
        for task in Array(assistantEnqueueTasks.values) { _ = try? await task.value }
        await assistant.suspend()
        await contentIndexer.stop()
        await desktop.stop()
        mailActionQueueTask?.cancel(); await mailActionQueueTask?.value
        networkTask?.cancel(); contentTask?.cancel()
        await networkTask?.value; await contentTask?.value
        await attachmentController?.stopAndWait()
        let saved = await ComposerWindows.shared.flushAll()
        if saved { await makeRecoveryBackup(force: true) }
        if !saved { preparingToQuit = false; desktop.resume(); resumeQueuedMailActions(); contentIndexer.start(); await assistant.resume(); await scheduleBackups() }
        return saved
    }
    func openConversationMessage(_ id: MessageID) {
        if selectedMessage?.id != id { markReadSuppressedMessage = nil }
        conversationSelection = id
        loadContent()
    }
    var title: String {
        switch destination {
        case .dashboard: "Dashboard"
        case .inbox: "Alle Posteingänge"
        case .unread: "Ungelesen"
        case .flagged: "Favoriten"
        case .localDrafts: "Entwürfe"
        case .role(let role): Self.roleName(role)
        case .account(let id): accounts.first { $0.id == id }?.name ?? "Konto"
        case .folder(let id): folders.first { $0.id == id }?.name ?? "Ordner"
        }
    }
    var subtitle: String {
        let count = coverage?.messageCount ?? messages.count
        if isOnlineSearch { return "\(messages.count) Treffer geladen · Mailserver" }
        guard searchText.isEmpty else { return "\(count) Treffer · lokal" }
        // Empty results have no message provenance. Use the selected accounts as well.
        let selectedAccounts: [MailAccount]
        switch destination {
        case .account(let id): selectedAccounts = accounts.filter { $0.id == id }
        case .folder(let id): selectedAccounts = accounts.filter { $0.id == folders.first { $0.id == id }?.accountID }
        default: selectedAccounts = accounts
        }
        let isDemo = coverage?.isSynthetic != false && selectedAccounts.allSatisfy { $0.status == .demo }
        if let syncingAccountID, selectedAccounts.contains(where: { $0.id == syncingAccountID }) {
            return "\(count.formatted()) Nachrichten · Aktualisierung läuft"
        }
        let complete = coverage?.folders.isEmpty == false && coverage?.folders.allSatisfy(\.isComplete) == true
        return "\(count.formatted()) Nachrichten · \(isDemo ? "Demo" : complete ? "vollständig abgeglichen" : "Abgleich ausstehend")"
    }
    var searchCoverageLabel: String {
        if isOnlineSearch { return "Serverquelle · nur für diese Ansicht geladen" }
        guard let coverage, coverage.indexedTextCount > 0 else { return "Lokale Suche · Metadaten aller erfassten Nachrichten" }
        return "Lokale Suche · \(coverage.indexedTextCount) von \(coverage.eligibleMessageCount) Texten"
    }
    var filter: MessageFilter {
        var filter = destination.messageFilter
        filter.text = searchText
        return filter
    }
    func start(autoSelectDemo: Bool = true, refreshView: Bool = true) async {
        guard !starting else { return }
        starting = true; defer { starting = false; resumePausedSynchronizationIfReady() }
        do {
            if service == nil, persistent {
                isLoading = true; error = nil
                var paths = try WorkspacePaths.current()
                var namespace = KeychainStore.syntheticNamespace
                #if DEBUG
                // Test isolation accepts an opaque UUID, never an arbitrary filesystem path.
                if let raw = ProcessInfo.processInfo.environment["MIKE_MAIL_UI_TEST_ID"], let token = UUID(uuidString: raw) {
                    paths = WorkspacePaths(root: paths.root.appendingPathComponent("UITests/\(token)"),
                                           cache: paths.cache.appendingPathComponent("UITests/\(token)"))
                    namespace = "ch.kupferfunke.MikeMailHub.uitests.\(token)"
                }
                #endif
                let store = try keychain ?? KeychainStore(namespace: namespace)
                keychain = store
                assistant.tunnel.configure(credentials: try KeychainStore(namespace: namespace + ".assistant-tunnel"))
                let opened = try await LocalMailWorkspace.open(paths: paths, credentials: store, syntheticSnapshot: dataset.snapshot,
                                                             preferences: backupPreferences())
                if !isDemoMode { try await opened.repository.removeDevelopmentFixtures() }
                workspace = opened; service = InboxService(repository: opened.repository)
                imap = IMAPService(index: opened.repository, credentials: store) {
                    SwiftMailTransport(configuration: $0, password: $1)
                }
                submission = SubmissionService(repository: opened.repository, credentials: store,
                    smtp: { SwiftMailSubmission(profile: $0, password: $1) },
                    sent: { SwiftMailSentCopy(configuration: $0, password: $1) })
                GoogleAuthentication.configureNetworkSession()
                let google = GoogleAuthentication(credentials: store)
                googleAuthentication = google
                gmail = GmailService(index: opened.repository) { GmailClient(configuration: $0, tokens: google) }
                gmailSubmission = GmailSubmission(repository: opened.repository, index: opened.repository) { GmailClient(configuration: $0, tokens: google) }
                if let imap, let gmail {
                    attachmentController = AttachmentController(store: opened.temporaryFiles, storageChanged: { [weak self] in try? await self?.refreshStorage() }) { request, sink, progress in
                        switch request.locator {
                        case .imap: try await imap.download(request, sink: sink, progress: progress)
                        case .gmail: try await gmail.download(request, sink: sink, progress: progress)
                        default: throw MailFailure.unsupported
                        }
                    }
                }
                let indexReader = IMAPService(index: opened.repository, credentials: store) { SwiftMailTransport(configuration: $0, password: $1) }
                contentIndexer.configure(repository: opened.repository, mayRun: { [weak self] in
                    guard let self else { return false }
                    return self.persistentStoreReady && self.desktop.permitsUserReads && !self.storageBusy && !self.networkBusy && !self.contentLoading && !self.compositionBusy && !self.assistantReading && self.attachmentController?.busy != true
                }, read: { [weak self] message in
                    guard let self else { throw MailFailure.offline }
                    await self.keychain?.disallowUserInteraction()
                    let scope = AccessScope(accountIDs: [message.accountID])
                    if message.locator.kind == .gmail, let gmail = self.gmail { return try await gmail.body(for: message, scope: scope, preferHTML: false) }
                    return try await indexReader.body(for: message, scope: scope, preferHTML: false)
                })
                persistentStoreReady = true
            }
            guard let service else { throw LocalStoreFailure.unavailable }
            if let workspace {
                scope = AccessScope(accountIDs: try await workspace.repository.activeAccountIDs())
                imapAccountIDs = Set(try await workspace.repository.imapConfigurations().map(\.accountID))
                gmailConfigurations = Dictionary(uniqueKeysWithValues: try await workspace.repository.gmailConfigurations().map { ($0.accountID, $0) })
            }
            accounts = try await service.accounts(scope: scope)
            folders = try await service.folders(scope: scope)
            if let workspace {
                var orders: [AccountID: [FolderID]] = [:]
                for account in accounts { orders[account.id] = try await workspace.repository.folderOrder(account: account.id) }
                folderOrders = orders
            }
            if mailActions == nil, let workspace {
                mailActions = MailActions(service: service, store: workspace.repository) { [weak self] mutation, message, account, scope in
                    guard let self else { throw MailFailure.offline }
                    try await self.writeMailAction(mutation, message: message, account: account, scope: scope)
                }
            }
            let replies = workspace.map { workspace in
                AssistantReplies(service: service, repository: workspace.repository,
                    ownAddresses: { [weak self] in await self?.assistantOwnAddresses() ?? [] },
                    review: { [weak self] draft, authorize in
                        guard let self else { throw MailFailure.offline }
                        return try await self.reviewAssistantReply(draft, authorize: authorize)
                    }, directSend: { [weak self] draft, authorize in
                        guard let self else { throw MailFailure.offline }
                        return try await self.sendAssistantMessage(draft, authorize: authorize)
                    })
            }
            let assistantActions = mailActions.map { actions in
                AssistantMailActions(submit: { [weak self] request, scope, authorize in
                    guard let self else { throw MailFailure.offline }
                    return try await self.submitAssistantAction(request, scope: scope, authorize: authorize)
                }, read: { id, account, scope in try await actions.get(id: id, account: account, scope: scope) },
                undo: { [weak self] id, account, request, scope, authorize in
                    guard let self else { throw MailFailure.offline }
                    return try await self.undoAssistantAction(id: id, account: account, requestID: request, scope: scope, authorize: authorize)
                }, supportsDurableQueue: true)
            }
            await assistant.configure(service: service, accounts: accounts, folders: folders, replies: replies, actions: assistantActions) { [weak self] id, scope in
                guard let self else { throw MailFailure.offline }
                return try await self.assistantText(id, scope: scope)
            }
            let inbox = SidebarDestination.inbox.messageFilter
            let unread = SidebarDestination.unread.messageFilter
            let inboxTotal = try await service.search(inbox, page: PageRequest(limit: 1), scope: scope).coverage.messageCount
            let unreadTotal = try await service.search(unread, page: PageRequest(limit: 1), scope: scope).coverage.messageCount
            var counts: [AccountID: Int] = [:]
            for account in accounts {
                var query = unread; query.accountID = account.id
                counts[account.id] = try await service.search(query, page: PageRequest(limit: 1), scope: scope).coverage.messageCount
            }
            inboxCount = inboxTotal
            unreadCount = unreadTotal
            accountUnread = counts
            try await refreshStorage()
            try await refreshMailActionQueue()
            resumeQueuedMailActions()
            await scheduleBackups()
            contentIndexer.start()
            if let workspace, !notificationBaselinePrimed {
                for id in realAccountIDs { _ = try await workspace.repository.consumeInboxNotifications(account: id) }
                notificationBaselinePrimed = true
            }
            desktop.update(accounts: realAccountIDs, unread: realAccountIDs.reduce(0) { $0 + (counts[$1] ?? 0) }, ready: persistentStoreReady)
            if refreshView { reload(autoSelectDemo: autoSelectDemo) }
        } catch {
            if error is KeychainFailure { keychainAccessNeeded = true }
            isLoading = false; self.error = Self.safeError(error)
            RedactedLog.record(.operationFailed, outcome: .unavailable)
        }
    }
    func reload(autoSelectDemo: Bool = true, preserveDisplayedContent: Bool = false, afterMove: MailMoveContinuation? = nil) {
        guard let service, !storageBusy, !navigatingRoute else { return }
        if isOnlineSearch { networkTask?.cancel(); networkMessage = nil; networkFailed = false }
        isOnlineSearch = false; onlineCheckedAt = nil; onlineFolderTotal = nil; searchInvalid = false
        generation += 1
        let requestedGeneration = generation
        searchTask?.cancel()
        if !preserveDisplayedContent {
            contentTask?.cancel()
            content = ""; safeHTML = nil; contentError = nil; contentLoading = false
        }
        error = nil; isLoading = true; nextCursor = nil; coverage = nil
        if destination == .dashboard {
            if Set(dashboard?.accounts.map(\.id) ?? []) != Set(accounts.map(\.id)) { dashboard = nil }
            selection = []; messages = []; conversation = []
            refreshLocalDrafts()
            searchTask = Task {
                do {
                    if scenario == .error { throw MailFailure.providerFailure }
                    let data = try await MailDashboard.load(service: service, scope: scope)
                    guard !Task.isCancelled, requestedGeneration == generation else { return }
                    dashboard = data
                    inboxCount = data.inbox; unreadCount = data.unread
                    accountUnread = Dictionary(uniqueKeysWithValues: data.accounts.map { ($0.id, $0.unread) })
                    isLoading = false
                } catch is CancellationError { return }
                catch {
                    guard requestedGeneration == generation else { return }
                    isLoading = false
                    self.error = "Die Übersicht konnte nicht aktualisiert werden. Bitte versuche es erneut."
                }
            }
            return
        }
        if destination == .localDrafts {
            selection = []; messages = []; conversation = []; isLoading = false
            refreshLocalDrafts()
            return
        }
        let query = filter
        searchTask = Task {
            do {
                if !query.text.isEmpty { try await Task.sleep(for: .milliseconds(180)) }
                if scenario == .error { throw MailFailure.providerFailure }
                if scenario == .empty || scenario == .noAccounts {
                    messages = []; selection = []; coverage = nil; isLoading = false; return
                }
                let wantedCount = afterMove?.loadedCount ?? 20
                var result = try await service.search(query, page: PageRequest(limit: min(100, wantedCount)), scope: scope)
                var items = result.items
                // Keep pages already opened by the user, so moving the last row
                // of a later page does not reset selection to the first page.
                while items.count < wantedCount, let cursor = result.nextCursor {
                    try Task.checkCancellation()
                    guard requestedGeneration == generation else { return }
                    result = try await service.search(query, page: PageRequest(limit: min(100, wantedCount - items.count), cursor: cursor), scope: scope)
                    items += result.items
                }
                guard !Task.isCancelled, requestedGeneration == generation else { return }
                messages = items; coverage = result.coverage; nextCursor = result.nextCursor
                let retainedSelection = selection.intersection(Set(messages.map(\.id)))
                if let afterMove, retainedSelection.isEmpty, let next = afterMove.next(in: displayedMessages) {
                    selection = [next]
                } else if retainedSelection == selection {
                    if !preserveDisplayedContent || afterMove != nil { conversationSelection = nil; loadContent(); loadConversation() }
                } else { selection = retainedSelection }
                // Only synthetic fixtures open automatically. Real bodies require a deliberate selection.
                if autoSelectDemo, selection.isEmpty, let first = messages.first, account(for: first)?.status == .demo { selection = [first.id] }
                isLoading = false
            } catch is CancellationError { return }
            catch {
                guard requestedGeneration == generation else { return }
                messages = []; selection = []; isLoading = false
                searchInvalid = error is SearchFailure
                self.error = (error as? SearchFailure)?.errorDescription ?? (scenario == .error ? "Dieser Ladefehler ist Teil der Demo." : "Die lokalen Nachrichten konnten nicht geladen werden. Bitte versuche es erneut.")
            }
        }
    }
    func showDashboardDestination(_ target: SidebarDestination) {
        searchText = ""
        if target == .localDrafts { draftSearchText = ""; showingSubmissionHistory = false }
        destination = target
    }
    func showDashboardDay(_ day: MailDashboard.Day) {
        searchText = day.query
        destination = .inbox
    }
    func openDashboardMessage(_ message: MailMessage) {
        guard dashboard?.recentUnread.contains(where: { $0.id == message.id && $0.accountID == message.accountID }) == true else { return }
        showDashboardDestination(.unread)
        messages = [message]
        selection = [message.id]
    }
    func loadMore() async {
        if isOnlineSearch { searchOnline(loadMore: true); return }
        guard let service, let cursor = nextCursor, !isLoading, !storageBusy else { return }
        let current = generation; let query = filter; isLoading = true
        do {
            let result = try await service.search(query, page: PageRequest(limit: 20, cursor: cursor), scope: scope)
            guard generation == current else { return }
            messages += result.items.filter { item in !messages.contains { $0.id == item.id } }
            nextCursor = result.nextCursor; isLoading = false
        } catch { if generation == current { isLoading = false; self.error = "Weitere Nachrichten konnten nicht geladen werden." } }
    }
    func account(for message: MailMessage) -> MailAccount? { accounts.first { $0.id == message.accountID } }
    func loadContent() {
        markReadTask?.cancel()
        requestedContentAfterSync = nil
        let preceding = contentTask
        preceding?.cancel(); content = ""; safeHTML = nil; contentError = nil; contentNote = nil; contentLoading = false
        if contentMessageID != selectedMessage?.id {
            contentMessageID = selectedMessage?.id
            htmlAvailable = nil
            setBodyFormat(html: true)
        }
        guard let message = selectedMessage, !storageBusy else { return }
        let preferHTML = showHTML
        let canReadDuringSync = syncingAccountID.flatMap { id in accounts.first { $0.id == id } }.map { $0.provider == .gmail || message.locator.kind == .gmail } ?? false
        if networkBusy && !canReadDuringSync && account(for: message)?.status != .demo {
            if desktop.isRunning {
                requestedContentAfterSync = message.id; contentLoading = true
                desktop.cancelCurrent()
                return
            }
            contentError = "Der Abgleich läuft. Mit «Pausieren» kannst du ihn unterbrechen und diese Nachricht öffnen."
            return
        }
        if scenario == .offline { contentError = "Du bist offline. Der Nachrichteninhalt ist in dieser Vorschau nicht verfügbar."; return }
        if scenario == .expired { contentError = "Die Anmeldung ist abgelaufen. Eine erneute Anmeldung ist erst mit echten Konten möglich."; return }
        contentLoading = true
        contentTask = Task {
            await preceding?.value
            do {
                try Task.checkCancellation()
                let text: String
                let note: String?
                var shouldStore = !isOnlineSearch
                var extractionSource = TextExtractionSource.plainText
                if account(for: message)?.status == .demo {
                    let plain = try await contentSource.text(for: message.id, scope: scope)
                    guard !Task.isCancelled, selectedMessage?.id == message.id else { return }
                    htmlAvailable = true
                    if preferHTML {
                        let escaped = plain.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                        let raw = "<h2>Synthetische HTML-Vorschau</h2><p>" + escaped.replacingOccurrences(of: "\n", with: "<br>") + "</p><p><a href=\"https://example.com/demo\">Beispiellink</a></p><img src=\"https://example.com/demo.png\" alt=\"Synthetisches externes Bild\"><script>window.mailUnsafe=true</script>"
                        let safe = try await Task.detached { try MailHTMLSanitizer.sanitize(raw) }.value
                        guard !Task.isCancelled, selectedMessage?.id == message.id else { return }
                        safeHTML = safe
                    }
                    text = plain; note = nil
                } else if !preferHTML, let workspace, let cached = try await workspace.repository.storedExtract(for: message.id, account: message.accountID) {
                    text = cached.text; shouldStore = false
                    note = "Gespeicherter Textextrakt · \(cached.byteCount.formatted()) Bytes\(cached.truncated ? " · gekürzt" : "") · auch offline verfügbar"
                } else if let imap {
                    let body: MailBody
                    if message.locator.kind == .gmail, let gmail { body = try await gmail.body(for: message, scope: scope, preferHTML: preferHTML) }
                    else { body = try await imap.body(for: message, scope: scope, preferHTML: preferHTML) }
                    guard !Task.isCancelled, selectedMessage?.id == message.id else { return }
                    if body.format == .html {
                        let safe = try await Task.detached { try MailHTMLSanitizer.sanitize(body.text, inlineImages: body.inlineImages) }.value
                        guard !Task.isCancelled, selectedMessage?.id == message.id else { return }
                        safeHTML = safe; htmlAvailable = true; text = safe.plainText; extractionSource = .sanitizedHTML
                        note = nil
                    } else {
                        text = body.text
                        if preferHTML { htmlAvailable = false; setBodyFormat(html: false) }
                        note = nil
                    }
                } else { throw MailFailure.notFound }
                guard !Task.isCancelled, selectedMessage?.id == message.id else { return }
                content = text; contentNote = note; contentLoading = false
                scheduleMarkRead(message)
                if shouldStore, let workspace, accountSettings[message.accountID]?.textIndexEnabled == true {
                    do {
                        try await workspace.storeExtract(text, for: message.id, account: message.accountID, source: extractionSource)
                        if let stored = try await workspace.repository.storedExtract(for: message.id, account: message.accountID), stored.truncated {
                            contentNote = (contentNote ?? "") + " · Suchtext gekürzt auf \(stored.byteCount.formatted()) Bytes"
                        }
                        guard !Task.isCancelled else { return }
                        try await refreshStorage()
                        if let service {
                            let current = generation
                            let result = try await service.search(filter, page: PageRequest(limit: 1), scope: scope)
                            if !Task.isCancelled, current == generation { coverage = result.coverage }
                        }
                    } catch {
                        guard !Task.isCancelled else { return }
                        storageError = true; storageMessage = Self.safeError(error)
                        contentNote = (contentNote ?? "") + " · Nicht indexiert: " + Self.safeError(error)
                    }
                }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                // HTML stays transient. Offline, a previously indexed text remains useful.
                if preferHTML, let workspace,
                   let cached = try? await workspace.repository.storedExtract(for: message.id, account: message.accountID) {
                    guard !Task.isCancelled, selectedMessage?.id == message.id else { return }
                    content = cached.text; setBodyFormat(html: false)
                    contentNote = "HTML momentan nicht verfügbar · gespeicherte Textansicht"
                } else { contentError = Self.networkError(error) }
                contentLoading = false
                if error is KeychainFailure { keychainAccessNeeded = true }
            }
        }
    }
    private func setBodyFormat(html: Bool) {
        settingBodyFormat = true; showHTML = html; settingBodyFormat = false
    }
    func refreshStorage() async throws {
        guard let workspace else { return }
        var settings: [AccountID: AccountSettings] = [:]
        for account in accounts { settings[account.id] = try await workspace.settings(for: account.id) }
        accountSettings = settings
        storageSummary = try await workspace.summary()
        dataLocation = workspace.dataDirectory; backupLocation = workspace.backupDirectory
        dataIncludedInBackups = try workspace.dataDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == false
        await contentIndexer.refresh()
        var pending: Set<AccountID> = []
        for id in imapAccountIDs where !(try await workspace.repository.pendingMailActions(account: id)).isEmpty { pending.insert(id) }
        for id in gmailConfigurations.keys where try await workspace.repository.gmailPendingAction(account: id) { pending.insert(id) }
        pendingAccounts = pending
        syncSummaries = Dictionary(uniqueKeysWithValues: try await workspace.repository.imapSummaries().map { ($0.folderID, $0) })
    }
    private func backupPreferences() throws -> Data {
        let domain = Bundle.main.bundleIdentifier ?? "ch.kupferfunke.MikeMailHub"
        return try PropertyListSerialization.data(fromPropertyList: UserDefaults.standard.persistentDomain(forName: domain) ?? [:], format: .binary, options: 0)
    }
    private func scheduleBackups() async {
        guard let workspace, persistent, !isDemoMode, backupTask == nil else { return }
        do { backupInfo = try await workspace.recoveryBackups().first }
        catch { backupFailed = true; backupMessage = "Die vorhandenen Sicherungen konnten nicht gelesen werden." }
        await makeRecoveryBackup()
        backupTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                await self.makeRecoveryBackup()
            }
        }
    }
    func makeRecoveryBackup(force: Bool = false) async {
        guard let workspace, persistentStoreReady, !backupBusy, !storageBusy, !networkBusy,
              !assistantReading, !compositionBusy, !isDemoMode else { return }
        if !force {
            if let last = backupInfo?.createdAt, Date().timeIntervalSince(last) < 3600 { return }
            if let lastBackupAttempt, Date().timeIntervalSince(lastBackupAttempt) < 300 { return }
        }
        backupBusy = true; backupFailed = false; backupMessage = "Verschlüsselte Sicherung wird erstellt und geprüft …"
        lastBackupAttempt = Date()
        defer { backupBusy = false }
        do {
            guard await ComposerWindows.shared.flushAll() else { throw LocalStoreFailure.unavailable }
            backupInfo = try await workspace.createRecoveryBackup(preferences: backupPreferences())
            backupMessage = "Sicherung erstellt und auf Lesbarkeit geprüft."
        } catch {
            backupFailed = true
            backupMessage = "Sicherung fehlgeschlagen. Deine Arbeitsdaten bleiben erhalten. " + Self.safeError(error)
        }
    }
    func verifyLatestBackup() async {
        guard let workspace, let backupInfo, !backupBusy else { return }
        backupBusy = true; backupFailed = false; backupMessage = "Sicherung wird vollständig geprüft …"
        defer { backupBusy = false }
        do {
            self.backupInfo = try await workspace.verifyRecoveryBackup(backupInfo)
            backupMessage = "Sicherung ist lesbar: Datenbank und Einstellungen sind vollständig geprüft."
        } catch { backupFailed = true; backupMessage = "Diese Sicherung konnte nicht bestätigt werden. Bitte erstelle eine neue Sicherung." }
    }
    func maintain(_ action: LocalDataAction) async {
        guard let workspace, !storageBusy, !networkBusy, !assistantReading else { return }
        if ComposerWindows.shared.hasOpenWindows || compositionBusy {
            storageError = true; storageMessage = "Bitte schliesse zuerst die Nachrichtenfenster. Ihre Entwürfe werden dabei gesichert."; return
        }
        storageBusy = true; storageMessage = nil; storageError = false
        await attachmentController?.stopAndWait()
        await contentIndexer.stop()
        await assistant.suspend()
        generation += 1; searchTask?.cancel(); contentTask?.cancel()
        selection = []; content = ""; contentError = nil
        await contentTask?.value
        do {
            switch action {
            case .save(let settings): try await workspace.saveSettings(settings); storageMessage = "Kontoeinstellungen gespeichert."
            case .clearTexts(let account):
                try await workspace.clearExtracts(account: account); storageMessage = "Textextrakte und ihre Suchbegriffe gelöscht. Metadaten und Kontoeinstellungen bleiben erhalten."
            case .remove(let account):
                if let config = gmailConfigurations[account] { _ = try await googleAuthentication?.disconnect(config, revoke: false) }
                try await workspace.removeAccount(account)
                destination = .inbox
                storageMessage = "Konto und seine lokalen Daten entfernt."
            case .rebuild: try await workspace.rebuildIndex(); storageMessage = "Metadatenindex neu aufgebaut. Vorhandene Textextrakte wurden entfernt."
            case .clear:
                for config in gmailConfigurations.values { _ = try await googleAuthentication?.disconnect(config, revoke: false) }
                try await workspace.clearLocalData()
                backupInfo = nil; backupMessage = nil
                destination = .inbox; searchText = ""
                storageMessage = "Lokale Konten und ihre Daten gelöscht."
            case .restore:
                try await workspace.restoreSyntheticData()
                destination = .inbox; searchText = ""
                storageMessage = "Synthetische Demokonten wiederhergestellt."
            }
        } catch {
            storageError = true; storageMessage = Self.safeError(error)
            if error is KeychainFailure { keychainAccessNeeded = true }
            RedactedLog.record(.operationFailed, outcome: .failed)
        }
        storageBusy = false
        // Clearing text must not immediately recreate a demo extract by auto-opening it.
        let autoSelectDemo: Bool
        if case .clearTexts = action { autoSelectDemo = false } else { autoSelectDemo = true }
        await start(autoSelectDemo: autoSelectDemo)
        await assistant.resume()
    }
    func assistantText(_ id: MessageID, scope: AccessScope) async throws -> String {
        guard !storageBusy, !contentLoading, !compositionBusy, !assistantReading,
              desktop.permitsUserReads, let service else { throw MailFailure.offline }
        assistantReading = true; defer { assistantReading = false }
        await keychain?.disallowUserInteraction()
        let message = try await service.getEmail(id, scope: scope)
        guard scope.permits(message), let account = accounts.first(where: { $0.id == message.accountID }) else { throw MailFailure.notFound }
        // Gmail's read requests share the account pacer and may run alongside
        // metadata scans. IMAP remains exclusive while any IMAP scan is active.
        if networkBusy {
            guard let syncingAccountID, let syncing = accounts.first(where: { $0.id == syncingAccountID }),
                  syncing.provider == .gmail || message.locator.kind == .gmail else { throw MailFailure.offline }
        }
        if account.status == .demo { return try await contentSource.text(for: id, scope: scope) }
        let body: MailBody
        if message.locator.kind == .gmail, let gmail { body = try await gmail.body(for: message, scope: scope, preferHTML: false) }
        else if message.locator.kind == .imap, let imap { body = try await imap.body(for: message, scope: scope, preferHTML: false) }
        else { throw MailFailure.unsupported }
        if body.format == .html { return try await Task.detached { try MailHTMLSanitizer.sanitize(body.text).plainText }.value }
        return body.text
    }
    var canCompose: Bool { persistentStoreReady && !storageBusy && !compositionBusy && !accounts.isEmpty }
    private func assistantOwnAddresses() -> Set<String> { Set(accounts.map(\.address.value)) }
    private func reviewAssistantReply(_ draft: LocalDraft, authorize: @escaping AssistantReplies.Authorization) async throws -> AssistantReplyReadiness {
        guard canCompose, desktop.permitsUserReads, let workspace, let submission, let keychain,
              let account = accounts.first(where: { $0.id == draft.accountID }) else { throw MailFailure.offline }
        let fresh = try await workspace.repository.draft(id: draft.id, account: draft.accountID)
        guard fresh == draft else { throw ComposeFailure.conflict }
        let config = try await workspace.repository.imapConfigurations().first { $0.accountID == account.id }
        let smtpConfigured = try await workspace.repository.smtpProfile(account: account.id) != nil
        try await authorize()
        guard canCompose else { throw ComposeFailure.locked }
        let editor = ComposerEditor(draft: fresh, accountName: account.name, isDemo: account.status == .demo,
            repository: workspace.repository, submission: submission, imap: config,
            google: gmailConfigurations[account.id] == nil ? nil : gmailSubmission,
            grantAccess: { await keychain.allowUserRequestedInteraction() })
        try ComposerWindows.shared.openAssistantReview(editor)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if account.status == .demo { return .demo }
        if let gmail = gmailConfigurations[account.id] { return gmail.permission == .manageMail ? .awaitingUserConfirmation : .gmailReadOnly }
        return config != nil && smtpConfigured ? .awaitingUserConfirmation : .smtpMissing
    }
    var canRespond: Bool {
        canCompose && selectedMessage != nil && !contentLoading && contentError == nil &&
            (selectedIsDemo || selectedMessage?.threadingHeadersLoaded == true)
    }
    private func sendAssistantMessage(_ draft: LocalDraft, authorize: @escaping AssistantReplies.Authorization) async throws -> LocalDraft {
        guard canCompose, desktop.permitsUserReads, !networkBusy, let workspace, let submission, let keychain,
              let account = accounts.first(where: { $0.id == draft.accountID }), account.status != .demo else { throw MailFailure.offline }
        // Take the UI lock before awaiting. An already open, clean editor may
        // participate, but unsaved edits or an open confirmation sheet win.
        let editor = try ComposerWindows.shared.beginAssistantDirectSend(draft)
        compositionBusy = true; assistantSending = true
        defer { compositionBusy = false; assistantSending = false; editor?.finishSubmission() }
        do {
            await keychain.disallowUserInteraction()
            let fresh = try await workspace.repository.draft(id: draft.id, account: draft.accountID)
            guard fresh == draft, draft.attachments.isEmpty else { throw ComposeFailure.conflict }
            try await authorize()
            let beforeSend: AssistantReplies.Authorization = { [weak self] in
                guard await self?.desktop.permitsUserReads == true else { throw MailFailure.offline }
                try await authorize()
            }
            let result: LocalDraft
            if let config = gmailConfigurations[account.id], let gmailSubmission {
                guard config.permission == .manageMail else { throw GmailFailure.insufficientScope }
                result = try await gmailSubmission.send(id: draft.id, account: account.id, expectedRevision: draft.revision, attachments: [], authorize: beforeSend)
            } else if let config = try await workspace.repository.imapConfigurations().first(where: { $0.accountID == account.id }) {
                result = try await submission.send(id: draft.id, account: account.id, expectedRevision: draft.revision, attachments: [], imap: config, authorize: beforeSend)
            } else { throw ComposeFailure.missingConfiguration }
            editor?.draft = result
            if editor == nil {
                NotificationCenter.default.post(name: .localDraftsDidChange, object: nil)
                if result.status == .accepted || result.status == .sent {
                    NotificationCenter.default.post(name: .mailSubmissionDidComplete, object: nil,
                                                    userInfo: ["status": result.status.rawValue])
                }
            }
            return result
        } catch {
            if let saved = try? await workspace.repository.draft(id: draft.id, account: draft.accountID) { editor?.draft = saved }
            editor?.message = ComposerEditor.safeError(error)
            throw error
        }
    }
    func compose(account requested: AccountID? = nil, kind: ComposeKind? = nil) {
        guard canCompose, let workspace, let submission, let keychain else { return }
        let source = kind == nil ? nil : selectedMessage
        if kind != nil && !canRespond { return }
        let preferred = source?.accountID ?? requested ?? filter.accountID ?? selectedMessage?.accountID
        guard let account = accounts.first(where: { $0.id == preferred }) ?? accounts.first(where: { $0.status != .demo }) ?? accounts.first else { return }
        let quote = content, htmlQuote = safeHTML, own = Set(accounts.map(\.address.value))
        let fetchHTML = htmlQuote == nil && htmlAvailable != false && account.status != .demo && !networkBusy && desktop.permitsUserReads
        compositionBusy = true
        Task {
            defer { compositionBusy = false }
            do {
                var draft: LocalDraft
                var originalHTML = htmlQuote, originalText = quote, quoteNotice: String?
                if let source, kind != nil, fetchHTML {
                    networkBusy = true
                    do {
                        let body: MailBody
                        if source.locator.kind == .gmail, let gmail { body = try await gmail.body(for: source, scope: scope, preferHTML: true) }
                        else if let imap { body = try await imap.body(for: source, scope: scope, preferHTML: true) }
                        else { throw MailFailure.offline }
                        if body.format == .html {
                            let safe = try await Task.detached { try MailHTMLSanitizer.sanitize(body.text, inlineImages: body.inlineImages) }.value
                            originalHTML = safe; originalText = safe.plainText
                        }
                    } catch { quoteNotice = "Die Originalformatierung konnte gerade nicht geladen werden. Dieser Entwurf enthält die verfügbare Textfassung." }
                    networkBusy = false
                }
                if let source, let kind { draft = try DraftBuilder.response(to: source, kind: kind, sender: account.address.value, ownAddresses: own, quote: originalText, htmlQuote: originalHTML) }
                else { draft = LocalDraft(accountID: account.id, sender: account.address.value) }
                draft.useSignature(try await workspace.repository.signatureLibrary(account: account.id).defaultSignature)
                let saved = try await workspace.repository.saveDraft(draft, expectedRevision: 0)
                let config = try await workspace.repository.imapConfigurations().first { $0.accountID == account.id }
                let editor = ComposerEditor(draft: saved, accountName: account.name, isDemo: account.status == .demo,
                    repository: workspace.repository, submission: submission, imap: config, google: gmailConfigurations[account.id] == nil ? nil : gmailSubmission, grantAccess: { await keychain.allowUserRequestedInteraction() })
                bindSendContinuation(to: editor)
                editor.message = quoteNotice
                if source?.attachments.isEmpty == false {
                    let attachmentNote = "Dateianhänge der ursprünglichen Nachricht wurden nicht übernommen. Wähle bei Bedarf lokale Dateien aus."
                    editor.message = [quoteNotice, attachmentNote].compactMap { $0 }.joined(separator: "\n")
                }
                ComposerWindows.shared.open(editor)
            } catch { networkMessage = ComposerEditor.safeError(error); networkFailed = true }
        }
    }
    func bindSendContinuation(to editor: ComposerEditor) {
        guard let selected = selectedMessage, selected.accountID == editor.draft.accountID else { return }
        let draft = editor.draft
        // Older replies have no persisted local source ID. Use their explicit
        // reply reference only when it matches the currently selected account/mail.
        let legacySource = draft.inReplyTo != nil && draft.inReplyTo == selected.internetMessageID ? selected.id : nil
        guard let source = draft.sourceMessageID ?? draft.assistantOrigin?.messageID ?? legacySource else { return }
        editor.afterSuccessfulSend = sendContinuation(source: source)
    }
    func sendContinuation(source: MessageID) -> (() -> Void)? {
        guard selectedMessage?.id == source else { return nil }
        let expectedSelection = selectionRevision, expectedDestination = destination, expectedSearch = searchText
        return { [weak self] in
            guard let self else { return }
            Task { await self.advanceAfterSend(source: source, selectionVersion: expectedSelection,
                                                  destination: expectedDestination, search: expectedSearch) }
        }
    }
    private func advanceAfterSend(source: MessageID, selectionVersion: Int, destination expectedDestination: SidebarDestination, search: String) async {
        func unchanged() -> Bool {
            selectedMessage?.id == source && selectionRevision == selectionVersion && destination == expectedDestination && searchText == search
        }
        func nextRow() -> MessageID? {
            let rows = displayedMessages
            guard let row = rows.firstIndex(where: { selection.contains($0.id) }), row + 1 < rows.count else { return nil }
            return rows[row + 1].id
        }
        guard unchanged() else { return }
        // Fetch the next page if the source row is at the current boundary.
        while nextRow() == nil, let cursor = nextCursor, !isOnlineSearch {
            await loadMore()
            guard unchanged() else { return }
            if nextCursor == cursor { break }
        }
        guard unchanged(), let next = nextRow() else { return }
        selection = [next]
    }
    func openDraft(_ draft: LocalDraft) {
        guard !compositionBusy, let workspace, let submission, let keychain, let account = accounts.first(where: { $0.id == draft.accountID }) else { return }
        Task {
            do {
                let fresh = try await workspace.repository.draft(id: draft.id, account: account.id)
                let config = try await workspace.repository.imapConfigurations().first { $0.accountID == account.id }
                guard !compositionBusy else { return }
                let editor = ComposerEditor(draft: fresh, accountName: account.name, isDemo: account.status == .demo,
                    repository: workspace.repository, submission: submission, imap: config, google: gmailConfigurations[account.id] == nil ? nil : gmailSubmission, grantAccess: { await keychain.allowUserRequestedInteraction() })
                bindSendContinuation(to: editor)
                ComposerWindows.shared.open(editor)
            } catch { networkMessage = ComposerEditor.safeError(error); networkFailed = true }
        }
    }
    func refreshLocalDrafts() {
        guard destination == .localDrafts || destination == .dashboard else { return }
        draftListTask?.cancel()
        draftListTask = Task {
            do {
                let drafts = try await localDrafts()
                guard !Task.isCancelled, destination == .localDrafts || destination == .dashboard else { return }
                savedDrafts = drafts; draftListError = nil
            } catch {
                guard !Task.isCancelled else { return }
                draftListError = "Die Entwürfe konnten nicht geladen werden. Bitte versuche es erneut."
            }
        }
    }
    func localDrafts() async throws -> [LocalDraft] {
        guard let workspace else { return [] }
        var result: [LocalDraft] = []
        for account in accounts { result += try await workspace.repository.drafts(account: account.id) }
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }
    func smtpProfile(_ account: AccountID) async -> SMTPProfile? { try? await workspace?.repository.smtpProfile(account: account) }
    func suggestedSMTPHost(_ account: AccountID) async -> String {
        let configuration = try? await workspace?.repository.imapConfigurations().first { $0.accountID == account }
        // Official Hostpoint settings; never infer another provider's SMTP host.
        return configuration?.host == "imap.mail.hostpoint.ch" ? "asmtp.mail.hostpoint.ch" : ""
    }
    func configureSMTP(_ profile: SMTPProfile, password: String?, reuseIncoming: Bool) async throws {
        guard !compositionBusy, let submission, let keychain else { throw ComposeFailure.unavailable }
        compositionBusy = true; defer { compositionBusy = false }
        await keychain.allowUserRequestedInteraction()
        try await submission.configure(profile, password: password, reuseIncoming: reuseIncoming)
    }
    func retry() async { scenario = .standard; await start() }
    func allowKeychainAccess() async {
        await keychain?.allowUserRequestedInteraction()
        keychainAccessNeeded = false
        await start()
    }
    var selectedIsDemo: Bool { selectedMessage.map { account(for: $0)?.status == .demo } ?? realAccountIDs.isEmpty }
    var syncCoverageLabel: String? {
        if case .folder(let id) = destination, let summary = syncSummaries[id] {
            return "\(summary.indexedCount) von \(summary.totalOnServer) auf dem Server · \(summary.lastSuccess.formatted(date: .abbreviated, time: .shortened))"
        }
        return realAccountIDs.isEmpty ? nil : "Alle Ordner werden erfasst · Inhalte und Anhänge beim Öffnen"
    }
    func connectGoogle(clientID: String, email: String, permission: GmailPermission, existing: MailAccount?, useDefaultBrowser: Bool = true) async -> Bool {
        guard let googleAuthentication, let workspace, let gmail, !networkBusy, !storageBusy else { return false }
        if ComposerWindows.shared.hasOpenWindows { networkMessage = "Bitte zuerst die Nachrichtenfenster schliessen."; return false }
        networkBusy = true; networkFailed = false; networkMessage = "Bitte die Google-Anmeldung im Browser abschliessen …"
        defer { networkBusy = false }
        var allocated: GmailConfiguration?
        var savedAccount = false
        do {
            let expected = email.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try EmailAddress(expected)
            let id = try existing?.id ?? AccountID()
            if existing == nil, accounts.contains(where: { gmailConfigurations[$0.id] != nil && $0.address.value.caseInsensitiveCompare(expected) == .orderedSame }) { throw MailFailure.invalidInput }
            let config = try GmailConfiguration(accountID: id, clientID: clientID, permission: permission)
            allocated = config
            await keychain?.allowUserRequestedInteraction()
            let profile = try await googleAuthentication.authorize(configuration: config, expectedEmail: expected, useDefaultBrowser: useDefaultBrowser)
            let api = GmailClient(configuration: config, tokens: googleAuthentication)
            let labels = try await api.folders()
            let account = MailAccount(id: id, name: existing?.name ?? "Gmail", address: try EmailAddress(profile.email), provider: .gmail, status: .connected)
            try await workspace.repository.saveGmailAccount(account, configuration: config, folders: labels)
            savedAccount = true
            networkMessage = "Gmail verbunden. Die neuesten Metadaten werden geladen …"
            beginSynchronization(account)
            try await gmail.synchronize(account: account) { [weak self] event in
                await self?.reportGmailProgress(account: account, event: event)
            }
            allowMailActionChecks(afterSync: account.id)
            synchronizationProgress?.finish()
            syncingAccountID = nil
            desktop.record(.success, account: account.id)
            networkMessage = "Gmail verbunden · Inhalt wird erst beim Öffnen geladen."
            await start(autoSelectDemo: false); destination = .account(id)
            return true
        } catch {
            if existing == nil, !savedAccount, let allocated { _ = try? await googleAuthentication.disconnect(allocated, revoke: false) }
            synchronizationProgress?.finish(error: Self.networkError(error), cancelled: error is CancellationError)
            syncingAccountID = nil
            networkFailed = true; networkMessage = Self.networkError(error)
            await start(autoSelectDemo: false)
            return savedAccount
        }
    }
    func cancelGoogleLogin() { googleAuthentication?.cancel() }
    func resumeOAuthLogin(_ url: URL) {
        _ = googleAuthentication?.resumeBrowserAuthorization(url)
    }
    func resetGoogleCoverage(_ account: MailAccount) async {
        guard let workspace, let gmail, !networkBusy, !storageBusy else { return }
        networkBusy = true; synchronizationActive = true; networkFailed = false; syncingAccountID = account.id
        manualSyncDestination = .account(account.id)
        beginSynchronization(account)
        networkMessage = "Der vollständige Gmail-Abgleich wird neu gestartet …"
        networkTask = Task {
            do {
                try await workspace.repository.resetGmailCoverage(account: account.id)
                try await gmail.synchronize(account: account) { [weak self] event in
                    await self?.reportGmailProgress(account: account, event: event)
                }
                allowMailActionChecks(afterSync: account.id)
                networkMessage = "Gmail vollständig neu abgeglichen. Eigene Entwürfe bleiben erhalten."
                synchronizationProgress?.finish()
            } catch {
                networkFailed = !(error is CancellationError)
                networkMessage = error is CancellationError ? "Abgleich pausiert. Der nächste Abgleich setzt am gespeicherten Stand fort." : Self.networkError(error)
                synchronizationProgress?.finish(error: error is CancellationError ? nil : Self.networkError(error), cancelled: error is CancellationError)
            }
            networkMessage = nil
            networkBusy = false; synchronizationActive = false; syncingAccountID = nil
            manualSyncDestination = nil
            await start(autoSelectDemo: false, refreshView: !hasQueuedMailActions)
        }
        await networkTask?.value
    }
    func disconnectGoogle(_ account: MailAccount, revoke: Bool) async {
        guard let config = gmailConfigurations[account.id], let googleAuthentication, let workspace, !networkBusy, !storageBusy else { return }
        if ComposerWindows.shared.hasOpenWindows { networkMessage = "Bitte zuerst die Nachrichtenfenster schliessen."; return }
        networkBusy = true
        contentTask?.cancel(); await contentTask?.value
        content = ""; safeHTML = nil; selection = []
        do {
            let remote = try await googleAuthentication.disconnect(config, revoke: revoke)
            try await workspace.repository.setGmailStatus(.requiresAuthentication, account: account.id)
            networkFailed = revoke && !remote
            networkMessage = revoke ? (remote ? "Google-Zugriff widerrufen. Lokale Metadaten bleiben verfügbar." : "Lokal abgemeldet. Google war nicht erreichbar; den Zugriff gegebenenfalls im Google-Konto widerrufen.") : "Google-Konto lokal abgemeldet."
        } catch { networkMessage = Self.networkError(error); networkFailed = true }
        networkBusy = false; await start(autoSelectDemo: false)
    }
    func connectIMAP(name: String, address: String, host: String, port: Int, security: IMAPSecurity, username: String, password: String) async -> Bool {
        guard let imap, !storageBusy, !networkBusy else { return false }
        networkBusy = true; networkMessage = "Verbindung wird geprüft …"; networkFailed = false
        contentTask?.cancel(); await contentTask?.value
        defer { networkBusy = false }
        do {
            let account = MailAccount(id: try AccountID(), name: name, address: try EmailAddress(address), provider: .imap, status: .connected)
            _ = try AccountSettings(accountID: account.id, displayName: name)
            let config = try IMAPConfiguration(accountID: account.id, host: host, port: port, security: security, username: username)
            try await imap.connectAccount(account, configuration: config, password: password)
            await start()
            networkMessage = "Konto verbunden. Wähle einen Ordner und klicke auf «Synchronisieren»."
            destination = .account(account.id)
            return true
        } catch {
            networkFailed = !(error is CancellationError)
            networkMessage = error is CancellationError ? "Verbindungsprüfung abgebrochen." : Self.networkError(error)
            if error is KeychainFailure { keychainAccessNeeded = true }
            return false
        }
    }
    private var canBackgroundSync: Bool {
        persistentStoreReady && !starting && !networkBusy && !queueWantsTurn && !storageBusy && !contentLoading && !isOnlineSearch && !assistantReading &&
        !compositionBusy && !ComposerWindows.shared.hasOpenWindows && attachmentController?.busy != true &&
        attachmentController?.prepared == nil && attachmentController?.exporting != true
    }
    private func backgroundSynchronize(_ id: AccountID) async -> BackgroundSyncOutcome {
        guard canBackgroundSync, let account = accounts.first(where: { $0.id == id }), realAccountIDs.contains(id),
              let imap, let service else { return .cancelled }
        if account.status == .requiresAuthentication { return .authenticationRequired }
        networkBusy = true; synchronizationActive = true
        networkFailed = false
        beginSynchronization(account)
        defer {
            networkBusy = false
            synchronizationActive = false
            syncingAccountID = nil
            if let requested = requestedContentAfterSync {
                requestedContentAfterSync = nil; contentLoading = false
                if selectedMessage?.id == requested, desktop.permitsUserReads { loadContent() }
                else { contentError = "Der Inhaltsabruf wurde pausiert. Bitte die Nachricht erneut öffnen." }
            }
        }
        await keychain?.disallowUserInteraction()
        var outcome: BackgroundSyncOutcome = .success
        do {
            try Task.checkCancellation()
            if account.provider == .gmail, let gmail {
                try await gmail.synchronize(account: account) { [weak self] event in
                    await self?.reportGmailProgress(account: account, event: event)
                }
                allowMailActionChecks(afterSync: account.id)
            }
            else {
                try await imap.refreshFolders(account: id)
                let currentFolders = try await service.folders(scope: scope)
                for folder in currentFolders where folder.accountID == id {
                    try Task.checkCancellation()
                    _ = try await imap.sync(account: account, folder: folder) { [weak self] count in
                        await self?.reportSyncProgress(account: account.name, folder: folder.name, count: count)
                    }
                }
            }
            try Task.checkCancellation()
            await announceNewInboxMessages(account: id)
            synchronizationProgress?.finish()
            networkMessage = nil
        } catch {
            outcome = Self.backgroundOutcome(error)
            synchronizationProgress?.finish(error: error is CancellationError ? nil : Self.networkError(error), cancelled: error is CancellationError)
            networkFailed = !(error is CancellationError)
            networkMessage = nil
            if error is KeychainFailure { keychainAccessNeeded = true }
        }
        if !Task.isCancelled {
            await start(autoSelectDemo: false, refreshView: false)
            // Refresh metadata only; a background tick never re-fetches a selected body.
            if !isOnlineSearch { reload(autoSelectDemo: false, preserveDisplayedContent: true) }
        }
        return Task.isCancelled ? .cancelled : outcome
    }
    private func announceNewInboxMessages(account: AccountID) async {
        guard let workspace else { return }
        do {
            if let delta = try await workspace.repository.consumeInboxNotifications(account: account), !Task.isCancelled {
                await desktop.deliver(delta)
            }
        } catch { desktop.message = "Mitteilungen pausieren, weil ihre lokalen Merkdaten nicht aktualisiert werden konnten." }
    }
    private static func backgroundOutcome(_ error: any Error) -> BackgroundSyncOutcome {
        if error is CancellationError { return .cancelled }
        if error is KeychainFailure || (error as? IMAPFailure) == .authentication || (error as? IMAPFailure) == .missingCredential ||
            (error as? MailFailure) == .authenticationExpired || (error as? GmailFailure) == .authenticationFailed { return .authenticationRequired }
        if case .rateLimited(let interval) = error as? MailFailure { return .retry(after: interval) }
        return .retry(after: nil)
    }
    @discardableResult func openRoute(_ raw: String, expectedAccount: AccountID? = nil) async -> Bool {
        routeGeneration += 1; let request = routeGeneration
        do {
            let route = try DeepLinkParser.parse(raw)
            guard let service, !storageBusy else { throw LocalStoreFailure.unavailable }
            let targets: [MailMessage]
            switch route {
            case .message(let id): targets = [try await service.getEmail(id, scope: scope)]
            case .thread(let id): targets = try await service.getThread(id, page: PageRequest(limit: 20), scope: scope).items
            }
            guard request == routeGeneration else { return false }
            guard let first = targets.first, targets.allSatisfy({ scope.permits($0) && $0.accountID == first.accountID }),
                  accounts.contains(where: { $0.id == first.accountID }), expectedAccount.map({ $0 == first.accountID }) ?? true
            else { throw DeepLinkError.notFound }
            await attachmentController?.stopAndWait()
            guard request == routeGeneration else { return false }
            generation += 1; searchTask?.cancel(); contentTask?.cancel(); conversationTask?.cancel()
            navigatingRoute = true
            destination = .account(first.accountID); searchText = ""; scenario = .standard
            isOnlineSearch = false; nextCursor = nil; coverage = nil; routeError = nil; error = nil; isLoading = false
            selection = []; messages = targets; selection = [first.id]
            navigatingRoute = false
            return true
        } catch {
            if request == routeGeneration {
                routeError = (error as? DeepLinkError) == .invalid ? "Dieser App-Link ist ungültig. Er darf nur eine lokale Nachrichten- oder Gesprächs-ID enthalten." : "Diese Nachricht ist im zugänglichen lokalen Bestand nicht verfügbar. Sie wurde möglicherweise entfernt oder liegt ausserhalb des erfassten Teilbestands."
            }
            return false
        }
    }
    func handleAppURL(_ url: URL, expectedAccount: AccountID? = nil) async {
        if ["cumail", "mikemail"].contains(url.scheme ?? "") { _ = await openRoute(url.absoluteString, expectedAccount: expectedAccount) }
        else if expectedAccount == nil { resumeOAuthLogin(url) }
    }
    private func beginSynchronization(_ account: MailAccount) {
        syncingAccountID = account.id
        synchronizationProgress = MailSynchronizationProgress(account: account)
    }
    private func reportGmailProgress(account: MailAccount, event: GmailSyncProgress) async {
        if synchronizationProgress?.accountID != account.id || synchronizationProgress?.isRunning != true { beginSynchronization(account) }
        synchronizationProgress?.receive(event)
        networkMessage = "\(account.name) · \(synchronizationProgress?.phase ?? "Abgleich läuft")"
        if case .folders = event { await refreshSynchronizedFolders() }
        let count: Int?
        switch event {
        case .updating(let value, _), .scanning(let value, _): count = value
        default: count = nil
        }
        if let count, count > 0, count % 500 == 0, !isOnlineSearch { reload(autoSelectDemo: false, preserveDisplayedContent: true) }
    }
    private func refreshSynchronizedFolders() async {
        guard let service else { return }
        do {
            let current = try await service.folders(scope: scope)
            let previous = folders
            folders = current
            if let workspace {
                for account in accounts { folderOrders[account.id] = try await workspace.repository.folderOrder(account: account.id) }
            }
            await assistant.refreshFolders(current)
            if case .folder(let id) = destination, !current.contains(where: { $0.id == id }) {
                destination = previous.first(where: { $0.id == id }).map { .account($0.accountID) } ?? .inbox
            }
        } catch {
            networkMessage = Self.networkError(error); networkFailed = true
        }
    }
    private func reportSyncProgress(account: String, folder: String, count: Int) {
        networkMessage = "\(account) · \(folder): \(count.formatted()) Nachrichten abgeglichen …"
        synchronizationProgress?.phase = "Ordner «\(folder)» abgleichen"
        synchronizationProgress?.detail = "\(count.formatted()) Nachrichten geprüft"
        synchronizationProgress?.processed = count
        synchronizationProgress?.total = nil
        synchronizationProgress?.lastProgressAt = Date()
        // Refresh a bounded first page while indexing, without opening message bodies.
        if count % 500 == 0 && !isOnlineSearch { reload(autoSelectDemo: false, preserveDisplayedContent: true) }
    }
    func signature(account: AccountID) async throws -> MailSignature? {
        guard let workspace else { throw LocalStoreFailure.unavailable }
        return try await workspace.repository.signature(account: account)
    }
    func saveSignature(_ signature: MailSignature?, account: AccountID) async throws {
        guard let workspace else { throw LocalStoreFailure.unavailable }
        try await workspace.repository.saveSignature(signature, account: account)
    }
    func signatureLibrary(account: AccountID) async throws -> SignatureLibrary {
        guard let workspace else { throw LocalStoreFailure.unavailable }
        return try await workspace.repository.signatureLibrary(account: account)
    }
    func saveSignatureLibrary(_ library: SignatureLibrary, account: AccountID) async throws {
        guard let workspace else { throw LocalStoreFailure.unavailable }
        try await workspace.repository.saveSignatureLibrary(library, account: account)
        NotificationCenter.default.post(name: .signaturesDidChange, object: nil, userInfo: ["account": account.description])
    }
    func orderedFolders(for account: AccountID) -> [MailFolder] {
        let order = folderOrders[account] ?? []
        let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return folders.filter { $0.accountID == account }.enumerated().sorted {
            let left = ranks[$0.element.id] ?? order.count, right = ranks[$1.element.id] ?? order.count
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
    func saveFolderOrder(_ order: [FolderID], account: AccountID) async throws {
        guard let workspace else { throw LocalStoreFailure.unavailable }
        try await workspace.repository.saveFolderOrder(order, account: account)
        folderOrders[account] = order
    }
    func synchronize() {
        synchronize(destination)
    }
    private func synchronize(_ requestedDestination: SidebarDestination) {
        guard !networkBusy, !storageBusy, let imap else { return }
        networkBusy = true; synchronizationActive = true; networkMessage = "Metadaten werden abgeglichen …"; networkFailed = false
        manualSyncDestination = requestedDestination
        networkTask = Task {
            contentTask?.cancel(); await contentTask?.value
            contentLoading = false
            do {
                let requestedAccounts: [MailAccount]
                switch requestedDestination {
                case .account(let id): requestedAccounts = accounts.filter { $0.id == id && realAccountIDs.contains(id) }
                case .folder(let id): requestedAccounts = accounts.filter { $0.id == folders.first(where: { $0.id == id })?.accountID && realAccountIDs.contains($0.id) }
                default: requestedAccounts = accounts.filter { realAccountIDs.contains($0.id) }
                }
                var count = 0
                var failures: [String] = []
                for account in requestedAccounts {
                    beginSynchronization(account)
                    do {
                    // Do not switch from a Gmail scan into IMAP while an assistant
                    // is still reading through the single IMAP service.
                    while assistantReading || contentLoading {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    try Task.checkCancellation()
                    if account.provider == .gmail, let gmail {
                        let label: String?
                        if case .folder(let id) = requestedDestination { label = folders.first { $0.id == id && $0.accountID == account.id }?.providerID }
                        else if case .role(let role) = requestedDestination { label = folders.first { $0.role == role && $0.accountID == account.id }?.providerID }
                        else { label = nil }
                        try await gmail.synchronize(account: account, label: label) { [weak self] event in
                            await self?.reportGmailProgress(account: account, event: event)
                        }
                        allowMailActionChecks(afterSync: account.id)
                        count += try await workspace?.repository.gmailCheckpoint(account: account.id).knownIDs.count ?? 0
                        await announceNewInboxMessages(account: account.id)
                        desktop.record(.success, account: account.id)
                        synchronizationProgress?.finish()
                        continue
                    }
                    try await imap.refreshFolders(account: account.id)
                    try await imap.reconcilePending(account: account)
                    guard let service else { throw LocalStoreFailure.unavailable }
                    folders = try await service.folders(scope: scope)
                    let targets = folders.filter { $0.accountID == account.id }.sorted { left, right in
                        if (left.role == .inbox) != (right.role == .inbox) { return left.role == .inbox }
                        return left.name.localizedStandardCompare(right.name) == .orderedAscending
                    }
                    for folder in targets {
                        try Task.checkCancellation()
                        let summary = try await imap.sync(account: account, folder: folder) { [weak self] count in
                            await self?.reportSyncProgress(account: account.name, folder: folder.name, count: count)
                        }
                        count += summary.indexedCount
                    }
                    await announceNewInboxMessages(account: account.id)
                    desktop.record(.success, account: account.id)
                    synchronizationProgress?.finish()
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        desktop.record(Self.backgroundOutcome(error), account: account.id)
                        failures.append(account.name + ": " + Self.networkError(error))
                        synchronizationProgress?.finish(error: Self.networkError(error))
                    }
                }
                networkFailed = !failures.isEmpty
                networkMessage = "\(count) Nachrichten in allen Ordnern abgeglichen." + (failures.isEmpty ? " Inhalte werden beim Öffnen geladen." : " " + failures.joined(separator: " "))
                if !failures.isEmpty { synchronizationProgress?.finish(error: failures.joined(separator: " ")) }
            } catch {
                networkFailed = !(error is CancellationError)
                networkMessage = error is CancellationError ? "Abgleich pausiert. Geladene Nachrichten bleiben verfügbar; der nächste Abgleich setzt hier fort." : Self.networkError(error)
                synchronizationProgress?.finish(error: error is CancellationError ? nil : Self.networkError(error), cancelled: error is CancellationError)
                if error is KeychainFailure { keychainAccessNeeded = true }
            }
            networkMessage = nil
            networkBusy = false
            synchronizationActive = false
            manualSyncDestination = nil
            syncingAccountID = nil
            await start(autoSelectDemo: false, refreshView: !hasQueuedMailActions)
        }
    }
    func cancelSynchronization() {
        resumeSyncAfterActions = nil
        desktop.cancelCurrent()
        networkTask?.cancel()
        networkMessage = "Abgleich wird pausiert …"
        if synchronizationProgress?.isRunning == true { synchronizationProgress?.phase = "Abgleich wird pausiert …" }
    }
    func updatePassword(account: AccountID, password: String) async -> Bool {
        guard let imap, !networkBusy, !storageBusy else { return false }
        networkBusy = true; networkFailed = false; defer { networkBusy = false }
        contentTask?.cancel(); await contentTask?.value
        do {
            try await imap.updatePassword(account: account, password: password)
            desktop.record(.success, account: account)
            networkMessage = "Anmeldung geprüft und im Schlüsselbund aktualisiert."
            await start(); return true
        } catch {
            networkMessage = Self.networkError(error); networkFailed = true
            if error is KeychainFailure { keychainAccessNeeded = true }
            return false
        }
    }
    static func networkError(_ error: any Error) -> String {
        if let google = error as? GmailFailure {
            switch google {
            case .accessDenied(let operation, let reason): return "Gmail hat den Abruf abgelehnt (\(operation): \(reason)). Der bisherige Bestand bleibt erhalten."
            case .cancelled: return "Google-Anmeldung abgebrochen. Du kannst sie erneut starten."
            case .timeout: return "Google hat nicht rechtzeitig geantwortet. Der gespeicherte Stand bleibt erhalten; bitte den Vorgang erneut starten."
            case .insufficientScope: return "Bitte unter Einstellungen → Google-Anmeldung das Schreiben freigeben."
            case .pendingAction: return "Der letzte Gmail-Vorgang muss zuerst abgeglichen werden. Es wurde nichts wiederholt."
            case .tooLarge: return "Diese Gmail-Antwort überschreitet die unterstützte Grösse. Der bisherige Bestand bleibt erhalten."
            case .noBody: return "Kein darstellbarer Nachrichtentext verfügbar."
            case .clientSecretRequired: return "Google erwartet für diese Registrierung einen Clientschlüssel. Die native Google-Registrierung muss angepasst werden."
            case .invalidClient: return "Google hat die Client-Registrierung abgelehnt. Bitte die Google-Registrierung prüfen."
            case .authenticationFailed: return "Google konnte die Anmeldung nicht abschliessen. Bitte erneut versuchen."
            default: return "Gmail konnte nicht vollständig abgeglichen werden. Der letzte vollständige Stand bleibt erhalten."
            }
        }
        if (error as? MailFailure) == .authenticationExpired { return "Bitte das Konto unter Einstellungen erneut anmelden." }
        if (error as? MailFailure) == .permissionDenied { return "Zugriff abgelehnt. Bitte Konto und Freigaben prüfen." }
        return switch error {
        case MailFailure.rateLimited(let retryAfter): "Der Anbieter begrenzt den Abruf. Bitte nach \(Int(retryAfter)) Sekunden fortsetzen; der Fortschritt ist gespeichert."
        case MailFailure.offline: "Die Verbindung wurde unterbrochen. Der nächste Abgleich setzt am gespeicherten Stand fort."
        case MailFailure.providerFailure: "Der Anbieter konnte die Anfrage nicht abschliessen. Bitte den Abgleich erneut starten."
        case IMAPFailure.authentication, IMAPFailure.missingCredential:
            "Anmeldung fehlgeschlagen. Prüfe Benutzername und App-Passwort in den Kontoeinstellungen."
        case IMAPFailure.busy: "Ein Konto wird gerade abgeglichen. Öffne die Nachricht danach erneut."
        case IMAPFailure.timeout: "Der Server hat nicht rechtzeitig geantwortet. Der lokale Stand bleibt verfügbar."
        case IMAPFailure.mailboxChanged: "Der Ordner hat sich während des Abrufs geändert. Bitte synchronisiere ihn erneut."
        case IMAPFailure.noPlainText: "Diese Nachricht enthält keinen darstellbaren Text- oder HTML-Teil."
        case IMAPFailure.unsupportedAction: "Der Server unterstützt diese sichere Aktion nicht. Verschieben benötigt MOVE und UIDPLUS."
        case IMAPFailure.unconfirmedAction, IMAPFailure.reconciliationRequired: "Das Ergebnis ist noch unklar. Bitte synchronisiere beide betroffenen Ordner über «Synchronisieren». Die Aktion wird nicht automatisch wiederholt."
        case MailFailure.permissionDenied: "Diese Aktion ist für das Konto nicht freigegeben. Prüfe die Kontoeinstellungen."
        case is HTMLRenderingFailure: "Dieser HTML-Inhalt ist zu gross oder zu komplex. Versuche die Textansicht."
        case IMAPFailure.contentTooLarge: "Der Textteil überschreitet das aktuelle Limit von 256 KiB."
        case IMAPFailure.invalidResponse: "Die Serverantwort konnte nicht sicher verarbeitet werden. Der lokale Stand bleibt erhalten."
        case MailFailure.invalidInput, DomainError.invalidAddress:
            "Bitte prüfe E-Mail-Adresse, Servername, Port und Anmeldedaten."
        case is KeychainFailure: safeError(error)
        case MailFailure.notFound: "Diese Nachricht oder dieses Konto ist nicht mehr verfügbar. Bitte synchronisiere erneut."
        default: "Keine sichere Verbindung zum Mailserver möglich. Prüfe Netzwerk, Server und TLS-Einstellung. Der lokale Stand bleibt verfügbar."
        }
    }
    private static func safeError(_ error: any Error) -> String {
        switch error {
        case KeychainFailure.lockedOrInteractionRequired:
            "Der Schlüsselbund ist gesperrt oder verlangt eine Freigabe. Entsperre ihn und versuche es erneut."
        case KeychainFailure.missingDatabaseKey, LocalStoreFailure.missingKey:
            "Der Schlüssel für den vorhandenen Index fehlt im Schlüsselbund. Die Daten wurden nicht verändert."
        case KeychainFailure.accessDenied:
            "macOS erlaubt dieser App den Zugriff auf ihren Schlüssel nicht. Der lokale Index bleibt geschlossen."
        case LocalStoreFailure.wrongKeyOrCorrupt, LocalStoreFailure.incompatibleSchema:
            "Der lokale Index kann nicht sicher geöffnet werden. Die vorhandene Datei bleibt für eine Wiederherstellung erhalten."
        case LocalStoreFailure.budgetExceeded:
            "Das Textbudget dieses Kontos ist ausgeschöpft. Du kannst es in den Kontoeinstellungen anpassen oder die Textindexierung ausschalten."
        case LocalStoreFailure.cleanupPending:
            "Die Bereinigung ist noch nicht abgeschlossen. Sie wird beim nächsten App-Start fortgesetzt."
        case LocalStoreFailure.invalidInput:
            "Bitte prüfe den Kontonamen und die Speichergrenzen."
        case LocalStoreFailure.conflictingDataLocations:
            "Es gibt bereits Daten am neuen Speicherort. Die bestehenden Bestände wurden nicht überschrieben."
        case LocalStoreFailure.invalidBackup:
            "Die Sicherung konnte nicht sicher geprüft werden. Der bestehende Datenbestand bleibt erhalten."
        default:
            "Der lokale Speicher ist momentan nicht verfügbar. Bitte versuche es erneut."
        }
    }
    var displayedMessages: [MailMessage] {
        guard groupConversations else { return messages }
        func key(_ message: MailMessage) -> String {
            message.accountID.description + ":" + (message.threadID?.description ?? message.id.description)
        }
        let selected = messages.first { selection.contains($0.id) }
        var seen: Set<String> = []
        return messages.compactMap { message in
            guard seen.insert(key(message)).inserted else { return nil }
            // Keep the selected row reachable when a newer member of its conversation arrives.
            if let selected, key(selected) == key(message) { return selected }
            return message
        }
    }
    func visibleConversationCount(_ message: MailMessage) -> Int {
        guard groupConversations, let thread = message.threadID else { return 1 }
        return messages.filter { $0.accountID == message.accountID && $0.threadID == thread }.count
    }
    func loadConversation() {
        conversationTask?.cancel()
        guard !isOnlineSearch, let selected = selectedMessage, let thread = selected.threadID, let service else {
            conversation = []; conversationCursor = nil; conversationLoading = false; return
        }
        conversationLoading = true
        conversationTask = Task {
            do {
                let page = try await service.getThread(thread, page: PageRequest(limit: 100), scope: AccessScope(accountIDs: [selected.accountID]))
                guard !Task.isCancelled, selectedMessage?.threadID == thread, selectedMessage?.accountID == selected.accountID else { return }
                conversation = page.items.sorted { $0.receivedAt < $1.receivedAt }
                conversationCursor = page.nextCursor; conversationLoading = false
            } catch { if !Task.isCancelled { conversation = []; conversationCursor = nil; conversationLoading = false } }
        }
    }
    func loadMoreConversation() async {
        guard let selected = selectedMessage, let thread = selected.threadID, let cursor = conversationCursor, let service else { return }
        conversationLoading = true; defer { conversationLoading = false }
        do {
            let page = try await service.getThread(thread, page: PageRequest(limit: 100, cursor: cursor), scope: AccessScope(accountIDs: [selected.accountID]))
            guard selectedMessage?.threadID == thread, selectedMessage?.accountID == selected.accountID else { return }
            conversation = (conversation + page.items.filter { item in !conversation.contains { $0.id == item.id } }).sorted { $0.receivedAt < $1.receivedAt }
            conversationCursor = page.nextCursor
        } catch { networkMessage = "Weitere Nachrichten des Gesprächs konnten nicht geladen werden."; networkFailed = true }
    }
    var onlineSearchFolder: MailFolder? {
        guard let query = try? filter.searchQuery() else { return nil }
        let allowed = Set(accounts.filter { imapAccountIDs.contains($0.id) && $0.provider == .imap && $0.status != .demo && query.matchesAccount($0) }.map(\.id))
        let candidates = folders.filter { folder in
            allowed.contains(folder.accountID) && query.matchesFolder(folder)
                && (filter.accountID.map { $0 == folder.accountID } ?? true)
                && (filter.folderID.map { $0 == folder.id } ?? true)
                && (filter.role.map { $0 == folder.role } ?? true)
        }
        return candidates.count == 1 ? candidates.first : nil
    }
    var onlineSearchExplanation: String {
        guard let query = try? filter.searchQuery() else { return "Bitte korrigiere die Suche." }
        guard query.supportsOnline else { return SearchFailure.onlineFilterUnsupported.errorDescription! }
        guard let folder = onlineSearchFolder else { return "Wähle einen Ordner eines verbundenen IMAP-Kontos für die Serversuche." }
        let account = accounts.first { $0.id == folder.accountID }?.name ?? "Konto"
        return "\(account) · \(folder.name). Suchbegriffe gehen an diesen Mailserver. Seine Textsuche kann von der lokalen Suche abweichen."
    }
    var canSearchOnline: Bool {
        !networkBusy && !storageBusy && scenario == .standard && onlineSearchFolder != nil
            && (try? filter.searchQuery().supportsOnline) == true
    }
    func searchOnline(loadMore: Bool = false) {
        guard canSearchOnline, let imap, let folder = onlineSearchFolder,
              let account = accounts.first(where: { $0.id == folder.accountID }),
              !loadMore || (isOnlineSearch && nextCursor != nil && true) else { return }
        let request = filter, cursor = loadMore ? nextCursor : nil
        generation += 1; let current = generation
        searchTask?.cancel(); contentTask?.cancel()
        let precedingContent = contentTask
        isOnlineSearch = true; isLoading = true; networkBusy = true; error = nil; searchInvalid = false
        if !loadMore { messages = []; selection = []; coverage = nil; nextCursor = nil }
        networkMessage = "Auf dem Mailserver wird gesucht …"; networkFailed = false
        networkTask = Task {
            defer { networkBusy = false; if generation == current { isLoading = false } }
            await precedingContent?.value
            do {
                try Task.checkCancellation()
                let page = try await imap.search(account: account, folder: folder, filter: request,
                    page: PageRequest(limit: 50, cursor: cursor), scope: scope)
                guard !Task.isCancelled, generation == current else { return }
                let existing = Set(messages.map(\.id))
                messages += page.items.filter { !existing.contains($0.id) }
                nextCursor = page.nextCursor; onlineCheckedAt = page.checkedAt; onlineFolderTotal = page.totalMessagesInFolder
                networkMessage =
                    page.nextCursor == nil ? "Serversuche für den erfassten Stand abgeschlossen. Ergebnisse bleiben nur in dieser Ansicht." :
                    "Ausschnitt durchsucht. «Weitere Serverergebnisse» prüft auch ältere Bereiche."
            } catch {
                guard generation == current else { return }
                if error is KeychainFailure { keychainAccessNeeded = true }
                networkFailed = !(error is CancellationError)
                networkMessage = error is CancellationError ? "Serversuche abgebrochen. Geladene Treffer bleiben sichtbar." :
                    (error as? SearchFailure)?.errorDescription ?? Self.networkError(error)
            }
        }
    }
    var canMutate: Bool {
        guard !isOnlineSearch, let message = selectedMessage, let account = account(for: message), workspace != nil,
              canAcceptMailAction, !pendingActionMessageIDs.contains(message.id) else { return false }
        return account.status == .demo || ((imapAccountIDs.contains(account.id) || gmailConfigurations[account.id]?.permission == .manageMail) && accountSettings[account.id]?.serverActionsEnabled == true && !pendingAccounts.contains(account.id))
    }
    var moveDestinations: [MailFolder] {
        guard let message = selectedMessage else { return [] }
        return folders.filter { $0.accountID == message.accountID && !message.folderIDs.contains($0.id) &&
            (message.locator.kind != .gmail || ["INBOX", "TRASH", GmailIdentity.archive].contains($0.providerID) || $0.providerID.hasPrefix("Label_")) }
    }
    func targetFolder(_ role: FolderRole) -> MailFolder? {
        let candidates = moveDestinations.filter { $0.role == role }
        return candidates.count == 1 ? candidates.first : nil
    }
    func mutate(_ mutation: MailMutation, expectedMessage: MessageID? = nil) {
        guard canMutate, let message = selectedMessage, expectedMessage == nil || expectedMessage == message.id else { return }
        let kind: MailActionKind
        var target: FolderID?
        switch mutation { case .read(let read): kind = read ? .read : .unread
        case .flagged(let flag): kind = flag ? .flag : .unflag
        case .move(let folder): kind = .move; target = folder.id }
        runMailAction(kind: kind, messages: [message], target: target)
    }
    var selectedMessages: [MailMessage] { messages.filter { selection.contains($0.id) } }
    var canMutateSelection: Bool {
        guard !selection.isEmpty, selectedMessages.count == selection.count, Set(selectedMessages.map(\.accountID)).count == 1,
              canAcceptMailAction, !isOnlineSearch, selection.isDisjoint(with: pendingActionMessageIDs) else { return false }
        return selectedMessages.allSatisfy { message in
            guard let account = account(for: message) else { return false }
            return account.status == .demo || (accountSettings[account.id]?.serverActionsEnabled == true && !pendingAccounts.contains(account.id) && (imapAccountIDs.contains(account.id) || gmailConfigurations[account.id]?.permission == .manageMail))
        } && selection.count <= 100 && mailActions != nil
    }
    var bulkMoveDestinations: [MailFolder] {
        guard let message = selectedMessages.first, Set(selectedMessages.map(\.accountID)).count == 1 else { return [] }
        return folders.filter { folder in folder.accountID == message.accountID && selectedMessages.allSatisfy { !$0.folderIDs.contains(folder.id) } &&
            (message.locator.kind != .gmail || ["INBOX", "TRASH", GmailIdentity.archive].contains(folder.providerID) || folder.providerID.hasPrefix("Label_")) }
    }
    func mutateSelection(_ kind: MailActionKind, target: FolderID? = nil) {
        guard canMutateSelection else { return }
        runMailAction(kind: kind, messages: selectedMessages, target: target)
    }
    private func submitAssistantAction(_ request: MailActionRequest, scope: AccessScope, authorize: @escaping MailActions.Authorize) async throws -> MailActionReceipt {
        guard let actions = mailActions else { throw MailFailure.offline }
        try await authorize()
        if let pending = assistantEnqueueTasks[request.id] {
            let receipt = try await pending.value
            guard receipt.request == request, receipt.permitted(in: scope) else { throw MailFailure.invalidInput }
            try await authorize()
            return try await actions.get(id: request.id, account: request.accountID, scope: scope)
        }
        do {
            let existing = try await actions.get(id: request.id, account: request.accountID, scope: scope)
            guard existing.request == request else { throw MailFailure.invalidInput }
            // A reconnect retries the same saved job, never creates another one
            // and never promotes legacy, unqueued receipts into resumable work.
            if existing.isQueued && !existing.finished {
                try await refreshMailActionQueue(); yieldSynchronizationToMailActions(); resumeQueuedMailActions()
            }
            return existing
        } catch MailFailure.notFound { /* New request. Storage errors must propagate. */ }
        guard persistentStoreReady, !preparingToQuit, !storageBusy,
              let account = accounts.first(where: { $0.id == request.accountID }),
              account.status == .demo || (accountSettings[account.id]?.serverActionsEnabled == true &&
                (imapAccountIDs.contains(account.id) || gmailConfigurations[account.id]?.permission == .manageMail)) else { throw MailFailure.permissionDenied }
        let authorization = try assistant.actionAuthorization(account: request.accountID, scope: scope)
        assistantEnqueuingMessages[request.id] = Set(request.messageIDs)
        let task = Task {
            let receipt = try await actions.prepare(request, scope: scope, assistantAuthorization: authorization, authorize: authorize)
            if request.kind == .read || request.kind == .unread { suppressAutomaticRead(for: request.messageIDs) }
            do { try await refreshMailActionQueue() }
            catch { mailActionQueueError = Self.networkError(error) }
            yieldSynchronizationToMailActions()
            return receipt
        }
        assistantEnqueueTasks[request.id] = task
        defer {
            assistantEnqueueTasks.removeValue(forKey: request.id)
            assistantEnqueuingMessages.removeValue(forKey: request.id)
            resumeQueuedMailActions()
        }
        return try await task.value
    }
    private func undoAssistantAction(id: UUID, account: AccountID, requestID: UUID, scope: AccessScope, authorize: @escaping MailActions.Authorize) async throws -> MailActionReceipt {
        guard let actions = mailActions else { throw MailFailure.offline }
        try await authorize()
        let receipt = try await actions.get(id: id, account: account, scope: scope)
        if receipt.undoRequestID == requestID { return receipt }
        guard receipt.canUndo, !networkBusy, !storageBusy, !contentLoading, !compositionBusy, desktop.permitsUserReads else { throw MailFailure.permissionDenied }
        if receipt.request.kind == .read || receipt.request.kind == .unread { suppressAutomaticRead(for: receipt.request.messageIDs) }
        networkBusy = true
        networkTask = Task {
            do {
                lastMailAction = try await actions.undo(id: id, account: account, undoID: requestID, scope: scope, authorize: authorize)
                networkMessage = "KI-Auftrag: \(lastMailAction?.items.filter { $0.state == .undone }.count ?? 0) Änderungen rückgängig gemacht."
            } catch { networkFailed = true; networkMessage = Self.networkError(error) }
            networkBusy = false; await start()
        }
        return receipt
    }
    private func writeMailAction(_ mutation: MailMutation, message: MailMessage, account: MailAccount, scope: AccessScope) async throws {
        guard let workspace else { throw MailFailure.offline }
        if account.status != .demo { guard try await workspace.settings(for: account.id).serverActionsEnabled else { throw MailFailure.permissionDenied } }
        if account.status == .demo { try await workspace.repository.performDemoMutation(mutation, message: message.id, scope: scope) }
        else if account.provider == .gmail, let gmail { try await gmail.perform(mutation, message: message, account: account, scope: scope) }
        else if let imap { try await imap.perform(mutation, message: message, account: account, scope: scope) }
        else { throw MailFailure.unsupported }
    }
    private var canAcceptMailAction: Bool {
        persistentStoreReady && !preparingToQuit && (!networkBusy || synchronizationActive || mailActionProcessing) &&
        !storageBusy && !compositionBusy && scenario == .standard && desktop.permitsUserReads
    }
    var pendingActionMessageIDs: Set<MessageID> {
        enqueuingMessageIDs.union(assistantEnqueuingMessages.values.flatMap { $0 })
            .union(queuedMailActions.filter { !$0.finished }.flatMap { $0.request.messageIDs })
    }
    var hasQueuedMailActions: Bool { !enqueuingMessageIDs.isEmpty || !assistantEnqueuingMessages.isEmpty || queuedMailActions.contains { !$0.finished } }
    private var blockedQueueAccounts: Set<AccountID> {
        pendingAccounts.union(queuedMailActions.filter { $0.needsAttention && $0.blocksQueue }.map { $0.request.accountID })
    }
    private var queueWantsTurn: Bool {
        !enqueuingMessageIDs.isEmpty || !assistantEnqueuingMessages.isEmpty || queuedMailActions.contains { !$0.finished && !blockedQueueAccounts.contains($0.request.accountID) }
    }
    var mailActionQueueSummary: String {
        let waiting = queuedMailActions.filter { !$0.finished }.reduce(0) { $0 + $1.request.messageIDs.count }
        let attention = queuedMailActions.filter(\.needsAttention).count
        if checkingMailActionID != nil { return "Gmail-Ergebnis wird geprüft …" }
        if waiting > 0, queuedMailActions.contains(where: { !$0.finished && blockedQueueAccounts.contains($0.request.accountID) }) {
            return "\(waiting) \(waiting == 1 ? "Änderung wartet" : "Änderungen warten") auf Prüfung"
        }
        if waiting > 0 { return "\(waiting) \(waiting == 1 ? "Änderung" : "Änderungen") \(mailActionProcessing ? "in Bearbeitung" : "ausstehend")" }
        if !enqueuingMessageIDs.isEmpty || !assistantEnqueuingMessages.isEmpty { return "Änderung wird gesichert …" }
        if attention > 0 { return "\(attention) \(attention == 1 ? "Vorgang benötigt" : "Vorgänge benötigen") deine Prüfung" }
        return "Mailaktionen"
    }
    func mailActionLabel(_ receipt: MailActionReceipt) -> String {
        switch receipt.request.kind {
        case .read: return "Als gelesen markieren"
        case .unread: return "Als ungelesen markieren"
        case .flag: return "Als Favorit markieren"
        case .unflag: return "Favorit entfernen"
        case .move:
            guard let folder = folders.first(where: { $0.id == receipt.request.targetFolderID }) else { return "Verschieben" }
            return folder.role == .trash ? "In den Papierkorb" : folder.role == .archive ? "Archivieren" : "Nach \(folder.name)"
        }
    }
    private func refreshMailActionQueue() async throws {
        guard let actions = mailActions else { return }
        let receipts = try await actions.queue(scope: scope)
        var subjects: [UUID: [String]] = [:]
        if let service {
            for receipt in receipts {
                for id in receipt.request.messageIDs.prefix(3) {
                    if let message = try? await service.getEmail(id, scope: scope) { subjects[receipt.id, default: []].append(message.subject) }
                }
            }
        }
        queuedMailActions = receipts; mailActionSubjects = subjects
    }
    private func runMailAction(kind: MailActionKind, messages: [MailMessage], target: FolderID?) {
        guard let first = messages.first, let actions = mailActions,
              let request = try? MailActionRequest(accountID: first.accountID, messageIDs: messages.map(\.id), kind: kind, targetFolderID: target) else { return }
        if kind == .read || kind == .unread { suppressAutomaticRead(for: request.messageIDs) }
        actionSelections[request.id] = (destination, searchText, selectionRevision,
            kind == .move ? MailMoveContinuation(rows: displayedMessages, selection: selection, loadedCount: self.messages.count) : nil)
        enqueuingMessageIDs.formUnion(request.messageIDs)
        mailActionQueueError = nil
        enqueueTasks[request.id] = Task {
            defer {
                enqueuingMessageIDs.subtract(request.messageIDs)
                enqueueTasks.removeValue(forKey: request.id)
                resumeQueuedMailActions()
            }
            do {
                // Persist the user's intent before yielding the sync or showing it as queued.
                _ = try await actions.prepare(request, scope: scope, nativeQueue: true, authorize: {})
                try await refreshMailActionQueue()
                yieldSynchronizationToMailActions()
            } catch {
                mailActionQueueError = "Die Änderung konnte nicht sicher eingereiht werden. " + Self.networkError(error)
                try? await refreshMailActionQueue()
            }
        }
    }
    private func yieldSynchronizationToMailActions() {
        guard synchronizationActive else { return }
        let interrupted = manualSyncDestination
        cancelSynchronization()
        resumeSyncAfterActions = interrupted
    }
    private func authorizeQueuedMailAction(_ receipt: MailActionReceipt) throws {
        try Task.checkCancellation()
        guard !preparingToQuit, desktop.permitsUserReads else { throw CancellationError() }
        if receipt.assistantAuthorization != nil { try assistant.authorizeQueuedAction(receipt) }
    }
    func dismissMailActionResult(_ receipt: MailActionReceipt) {
        guard receipt.finished, let actions = mailActions else { return }
        Task {
            do {
                try await actions.dismissQueueResult(id: receipt.id, account: receipt.request.accountID, scope: scope)
                try await refreshMailActionQueue(); resumeQueuedMailActions()
            } catch { mailActionQueueError = Self.networkError(error) }
        }
    }
    private func canCheckMailAction(_ receipt: MailActionReceipt) -> Bool {
        gmail != nil && receipt.finished && receipt.uncertainCount > 0 && receipt.undoRequestID == nil &&
            gmailConfigurations[receipt.request.accountID] != nil && !attemptedMailActionChecks.contains(receipt.id)
    }
    func retryMailActionCheck(_ receipt: MailActionReceipt) {
        attemptedMailActionChecks.remove(receipt.id)
        mailActionQueueError = nil
        resumeQueuedMailActions()
    }
    func queuedMailActionStatus(_ receipt: MailActionReceipt) -> String {
        if processingMailActionID == receipt.id { return "Wird mit dem Server abgeglichen …" }
        if blockedQueueAccounts.contains(receipt.request.accountID) { return "Gesichert · wartet auf die Prüfung eines früheren Vorgangs dieses Kontos." }
        return "Gesichert · wartet auf Ausführung"
    }
    private func allowMailActionChecks(afterSync account: AccountID) {
        attemptedMailActionChecks.subtract(queuedMailActions.filter { $0.request.accountID == account }.map(\.id))
    }
    private func checkMailAction(_ receipt: MailActionReceipt, actions: MailActions) async {
        guard let gmail else { return }
        attemptedMailActionChecks.insert(receipt.id)
        networkBusy = true; checkingMailActionID = receipt.id
        defer { networkBusy = false; checkingMailActionID = nil }
        do {
            await keychain?.disallowUserInteraction()
            let executionScope = receipt.assistantAuthorization?.scope(account: receipt.request.accountID) ?? scope
            _ = try await actions.reconcile(id: receipt.id, account: receipt.request.accountID, scope: executionScope,
                authorize: { [weak self] in
                    guard let self else { throw MailFailure.offline }
                    try await self.authorizeQueuedMailAction(receipt)
                }, verify: { mutation, message, account, scope in
                    try await gmail.verify(mutation, message: message, account: account, scope: scope)
                })
            mailActionQueueError = nil
        } catch {
            mailActionQueueError = "Gmail-Ergebnis noch nicht prüfbar: " + Self.networkError(error)
        }
    }
    private func resumeQueuedMailActions() {
        guard mailActionQueueTask == nil, persistentStoreReady, !preparingToQuit, desktop.permitsUserReads,
              hasQueuedMailActions || queuedMailActions.contains(where: canCheckMailAction), let actions = mailActions else { return }
        mailActionQueueTask = Task {
            defer { mailActionQueueTask = nil; resumePausedSynchronizationIfReady() }
            while !Task.isCancelled, !preparingToQuit, desktop.permitsUserReads {
                // Sync and writes share one provider channel. No operation starts
                // until its predecessor has released that channel completely.
                if !mailActionChannelAvailable {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    continue
                }
                do { try await refreshMailActionQueue() }
                catch { mailActionQueueError = Self.networkError(error); return }
                // Refreshing receipts suspends this task. A sync, body request or
                // maintenance may have claimed the channel in the meantime.
                guard !Task.isCancelled, !preparingToQuit, desktop.permitsUserReads else { return }
                guard mailActionChannelAvailable else { continue }
                if let receipt = queuedMailActions.first(where: canCheckMailAction) {
                    await checkMailAction(receipt, actions: actions)
                    if Task.isCancelled { return }
                    await start(autoSelectDemo: false, refreshView: false)
                    reload(autoSelectDemo: false, preserveDisplayedContent: true)
                    continue
                }
                guard let receipt = queuedMailActions.first(where: { !$0.finished && !blockedQueueAccounts.contains($0.request.accountID) }) else { return }
                networkBusy = true; mailActionProcessing = true; processingMailActionID = receipt.id
                contentTask?.cancel(); markReadTask?.cancel(); await contentTask?.value
                var confirmedMove = false
                var failedToRecord = false
                do {
                    let executionScope = receipt.assistantAuthorization?.scope(account: receipt.request.accountID) ?? scope
                    let result = try await actions.execute(id: receipt.id, account: receipt.request.accountID, scope: executionScope, authorize: { [weak self] in
                        guard let self else { throw MailFailure.offline }
                        try await self.authorizeQueuedMailAction(receipt)
                    })
                    lastMailAction = result
                    confirmedMove = receipt.request.kind == .move && result.confirmedCount > 0
                    networkFailed = result.confirmedCount != receipt.request.messageIDs.count
                    networkMessage = "\(result.confirmedCount) von \(receipt.request.messageIDs.count) Änderungen bestätigt." + (result.uncertainCount > 0 ? " Ergebnis teilweise unklar. Bitte synchronisieren; die Aktion wird nicht wiederholt." : "")
                } catch { mailActionQueueError = Self.networkError(error); failedToRecord = true }
                mailActionProcessing = false; networkBusy = false; processingMailActionID = nil
                let context = actionSelections.removeValue(forKey: receipt.id)
                if Task.isCancelled { return }
                await start(autoSelectDemo: false, refreshView: false)
                let next = confirmedMove && context?.destination == destination && context?.search == searchText && context?.selection == selectionRevision ? context?.continuation : nil
                reload(autoSelectDemo: false, preserveDisplayedContent: true, afterMove: next)
                if failedToRecord { return }
                // Let the list and its selection settle before the next queued action.
                while isLoading, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
            }
        }
    }
    private var mailActionChannelAvailable: Bool {
        !networkBusy && !storageBusy && !starting && !contentLoading && !assistantReading && !compositionBusy && attachmentController?.busy != true
    }
    private func resumePausedSynchronizationIfReady() {
        guard let destination = resumeSyncAfterActions, !preparingToQuit, desktop.permitsUserReads,
              !starting, !networkBusy, !storageBusy, mailActionQueueTask == nil, !queueWantsTurn else { return }
        resumeSyncAfterActions = nil
        synchronize(destination)
    }
    func undoLastMailAction() {
        guard let receipt = lastMailAction, receipt.canUndo, !networkBusy, !storageBusy, let actions = mailActions else { return }
        if receipt.request.kind == .read || receipt.request.kind == .unread { suppressAutomaticRead(for: receipt.request.messageIDs) }
        networkBusy = true; networkMessage = "Änderung wird rückgängig gemacht …"
        networkTask = Task {
            do {
                lastMailAction = try await actions.undo(id: receipt.id, account: receipt.request.accountID, undoID: UUID(), scope: scope, authorize: {})
                let undone = lastMailAction?.items.filter { $0.state == .undone }.count ?? 0
                networkMessage = "\(undone) Änderungen rückgängig gemacht."
            } catch { networkMessage = Self.networkError(error); networkFailed = true }
            networkBusy = false; await start()
        }
    }
    private func suppressAutomaticRead(for ids: [MessageID]) {
        guard let current = selectedMessage?.id, ids.contains(current) else { return }
        markReadSuppressedMessage = current; markReadTask?.cancel()
    }
    private func scheduleMarkRead(_ message: MailMessage) {
        guard message.isUnread, markReadSuppressedMessage != message.id,
              let delay = accountSettings[message.accountID]?.markReadAfterSeconds, delay > 0 else { return }
        markReadTask = Task {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, selectedMessage?.id == message.id, !contentLoading, contentError == nil, canMutate,
                  NSApplication.shared.isActive, desktop.permitsUserReads else { return }
            mutate(.read(true), expectedMessage: message.id)
        }
    }
    static func accountStatusName(_ status: AccountStatus) -> String {
        switch status { case .demo: "Demo"; case .connected: "Verbunden"; case .offline: "Offline"; case .requiresAuthentication: "Anmeldung erforderlich" }
    }
    static func roleName(_ role: FolderRole) -> String {
        switch role { case .inbox: "Posteingang"; case .sent: "Gesendet"; case .drafts: "Entwürfe"; case .archive: "Archiv"; case .trash: "Papierkorb"; case .custom: "Ordner" }
    }
    static func roleIcon(_ role: FolderRole) -> String {
        switch role { case .inbox: "tray"; case .sent: "paperplane"; case .drafts: "doc"; case .archive: "archivebox"; case .trash: "trash"; case .custom: "folder" }
    }
}
