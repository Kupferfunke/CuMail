import SwiftUI
import AppKit
import MailDomain
import MailApplication

struct SynchronizationStatusView: View {
    let progress: MailSynchronizationProgress
    let pause: () -> Void
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: progress.isRunning ? "arrow.triangle.2.circlepath" : progress.state == .completed ? "checkmark.circle" : progress.state == .paused ? "pause.circle" : "exclamationmark.circle")
                    .foregroundStyle(progress.state == .failed ? Color.red : Brand.accent(scheme))
                Text(progress.accountName + " · " + progress.phase)
                    .font(.system(size: 11, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: progress.isRunning ? pause : dismiss) {
                    Image(systemName: progress.isRunning ? "pause" : "xmark")
                }.buttonStyle(.plain).accessibilityLabel(progress.isRunning ? "Abgleich pausieren" : "Abgleichstatus schliessen")
            }
            Text(progress.detail).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Brand.secondary(scheme))
            if progress.isRunning {
                if let fraction = progress.fraction { ProgressView(value: fraction).tint(Brand.accent(scheme)) }
                else { ProgressView().controlSize(.small) }
                if let explanation = progress.explanation {
                    Text(explanation).font(.system(size: 10)).foregroundStyle(Brand.secondary(scheme))
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(progress.timing(at: context.date)).font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(Brand.secondary(scheme)).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(progress.timing(at: progress.lastProgressAt)).font(.system(size: 10)).foregroundStyle(Brand.secondary(scheme))
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Brand.text(scheme)).background(Brand.canvas(scheme))
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain).accessibilityIdentifier("synchronization-progress")
    }
}

struct InboxView: View {
    @Bindable var model: InboxModel
    @Environment(\.colorScheme) private var scheme
    @ViewState private var bulkTarget: MailFolder?
    @ViewState private var bulkSnapshot: Set<MessageID> = []
    @ViewState private var visibility: NavigationSplitViewVisibility = .all
    @ViewState private var searchFocusRequest = 0
    @ViewState private var dashboardSearchText = ""
    @ViewState private var showingSearchFilters = false
    @ViewState private var showingSearchCoverage = false
    @ViewState private var folderOrderAccount: MailAccount?
    @ViewState private var submissionNotice: String?
    @ViewState private var expandedAccounts: Set<AccountID> = []
    @ViewState private var showingMailActions = false

    var body: some View {
        Group {
            if model.destination == .dashboard {
                NavigationSplitView(columnVisibility: $visibility) {
                    sidebar.frame(minHeight: 0, maxHeight: .infinity)
                        .navigationSplitViewColumnWidth(min: 235, ideal: 265, max: 320)
                } detail: {
                    DashboardView(model: model).frame(minWidth: 500, minHeight: 0, maxHeight: .infinity)
                }
            } else {
        NavigationSplitView(columnVisibility: $visibility) {
            // Columns must shrink with the window. Otherwise the native split
            // view can retain a document-sized minimum after a large-window layout.
            sidebar.frame(minHeight: 0, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: 235, ideal: 265, max: 320)
        } content: {
            VStack(spacing: 0) {
                Group {
                    if model.destination == .localDrafts { LocalDraftList(model: model) }
                    else { messageList }
                }.frame(minHeight: 0, maxHeight: .infinity)
                if let progress = model.synchronizationProgress {
                    SynchronizationStatusView(progress: progress, pause: model.cancelSynchronization) {
                        model.synchronizationProgress = nil
                    }
                }
            }.frame(minHeight: 0, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: 300, ideal: 355, max: 470)
        } detail: {
            Group {
                if model.destination == .localDrafts { LocalDraftDetail(model: model) }
                else { MessageDetailView(model: model) }
            }.frame(minWidth: 360, minHeight: 0, maxHeight: .infinity)
        }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Brand.accent(scheme))
        .background(Brand.canvas(scheme))
        .onReceive(NotificationCenter.default.publisher(for: .focusMailSearch)) { _ in
            searchFocusRequest += 1
        }
        .sheet(isPresented: $showingSearchFilters) { SearchFiltersView(model: model) }
        .onReceive(NotificationCenter.default.publisher(for: .localDraftsDidChange)) { _ in model.refreshLocalDrafts() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.destination == .dashboard { model.reload(autoSelectDemo: false) }
            model.refreshLocalDrafts()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { _ in model.refreshLocalDrafts() }
        .onReceive(NotificationCenter.default.publisher(for: .mailSubmissionDidComplete)) { notification in
            model.networkFailed = false
            model.networkMessage = notification.userInfo?["status"] as? String == DraftStatus.sent.rawValue
                ? "Nachricht gesendet."
                : "Nachricht gesendet. Die Gesendet-Kopie wird noch geprüft; den Beleg findest du unter Entwürfe → Versandstatus."
            submissionNotice = model.networkMessage
        }
        .sheet(item: $folderOrderAccount) { account in FolderOrderEditor(model: model, account: account) }
        .alert("App-Link öffnen", isPresented: Binding(get: { model.routeError != nil }, set: { if !$0 { model.routeError = nil } })) {
            Button("OK") { model.routeError = nil }
        } message: { Text(model.routeError ?? "") }
        .toolbar { mailboxToolbar }
        .toolbarBackground(Brand.toolbar(scheme), for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .overlay(alignment: .bottomTrailing) {
            if let submissionNotice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.accent(scheme))
                    Text(submissionNotice).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Button { self.submissionNotice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Versandhinweis schliessen")
                }.padding(15).frame(maxWidth: 390).background(Brand.canvas(scheme), in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.line.opacity(0.4), lineWidth: 0.5) }
                    .padding(20).accessibilityIdentifier("send-success-notice")
            }
        }
        .task(id: submissionNotice) {
            guard submissionNotice != nil else { return }
            do { try await Task.sleep(for: .seconds(7)); submissionNotice = nil } catch { }
        }
        .frame(minWidth: 840, minHeight: 600)
        .alert("Ausgewählte Nachrichten verschieben?", isPresented: Binding(get: { bulkTarget != nil }, set: { if !$0 { bulkTarget = nil } })) {
            Button("Verschieben", role: bulkTarget?.role == .trash ? .destructive : nil) {
                if model.selection == bulkSnapshot, let target = bulkTarget { model.mutateSelection(.move, target: target.id) }
                bulkTarget = nil
            }
            Button("Abbrechen", role: .cancel) { bulkTarget = nil }
        } message: { Text("\(bulkSnapshot.count) Nachrichten nach «\(bulkTarget?.name ?? "")». Es wird nichts endgültig gelöscht.") }
    }

    @ToolbarContentBuilder private var mailboxToolbar: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .primaryAction) { toolbarControls }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { toolbarControls }
        }
    }

    private var toolbarControls: some View {
        HStack(spacing: 8) {
            ToolbarSearchField(text: model.destination == .localDrafts ? $model.draftSearchText : model.destination == .dashboard ? $dashboardSearchText : $model.searchText,
                               focusRequest: searchFocusRequest,
                               placeholder: model.destination == .localDrafts ? "Entwürfe durchsuchen" : model.destination == .dashboard ? "Nachrichten suchen · Enter" : "Nachrichten durchsuchen",
                               onSubmit: {
                guard model.destination == .dashboard, !dashboardSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                // Switching the native split view destroys its toolbar editor.
                // Keep the dashboard stable while typing; navigate only after Enter.
                model.searchText = dashboardSearchText
                model.destination = .inbox
                dashboardSearchText = ""
            })
                .frame(width: 200, height: 28).padding(.horizontal, 5)
                .background(Brand.surface(scheme), in: RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Brand.line.opacity(0.3), lineWidth: 0.5) }
            Button {
                if model.destination == .dashboard { model.showDashboardDestination(.inbox) }
                showingSearchFilters = true
            } label: { Image(systemName: "line.3.horizontal.decrease") }
                .help("Suchfilter und Beispiele").accessibilityLabel("Suchfilter").accessibilityIdentifier("search-filters")
                .disabled(model.destination == .localDrafts)
            Rectangle().fill(Brand.line.opacity(0.35)).frame(width: 1, height: 18).padding(.horizontal, 2)
            if model.destination != .dashboard {
            Button { model.groupConversations.toggle() } label: {
                Label("Gespräche", systemImage: "bubble.left.and.bubble.right")
                    .foregroundStyle(model.groupConversations ? Brand.accent(scheme) : Brand.secondary(scheme))
            }.help("Zusammengehörige Mails in der Nachrichtenliste als Gespräch bündeln")
                .accessibilityLabel("Gespräche gruppieren").accessibilityValue(model.groupConversations ? "Ein" : "Aus")
                .accessibilityIdentifier("thread-grouping").disabled(model.destination == .localDrafts)
            }
            if model.networkBusy {
                Button { model.cancelSynchronization() } label: { Image(systemName: "pause") }
                    .help("Abgleich pausieren").accessibilityLabel("Abgleich pausieren").accessibilityIdentifier("cancel-sync")
            } else {
                Button { model.synchronize() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .disabled(model.realAccountIDs.isEmpty || model.storageBusy)
                    .help("Alle Ordner der ausgewählten Konten abgleichen").accessibilityLabel("Synchronisieren")
                    .accessibilityIdentifier("sync-mail")
            }
            Button { model.compose() } label: { Label("Neue Mail", systemImage: "square.and.pencil") }
                .buttonStyle(MailToolbarButtonStyle(emphasized: true))
                .disabled(!model.canCompose).help("Neue Nachricht verfassen · ⌘N")
                .accessibilityLabel("Neue Nachricht").accessibilityIdentifier("new-message")
            if model.isDemoMode {
                Menu {
                    Picker("Demo-Zustand", selection: $model.scenario) {
                        ForEach(DemoScenario.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Image(systemName: "slider.horizontal.3") }
                .help("Demo-Zustand").accessibilityIdentifier("demo-scenarios")
            }
        }.buttonStyle(MailToolbarButtonStyle()).labelStyle(.titleAndIcon)
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Brand.secondary(scheme))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Deine Post. Ein Ort.").foregroundStyle(Brand.spark)
                CuMailWordmark(size: 32)
                Text("BY KUPFERFUNKE").font(Brand.mono(9)).tracking(2.4).foregroundStyle(Brand.paper.opacity(0.6))
            }.padding(.horizontal, 22).padding(.top, 28).padding(.bottom, 28)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    sidebarRow("Dashboard", icon: "square.grid.2x2", destination: .dashboard).padding(.bottom, 12)
                    sidebarRow("Alle Posteingänge", icon: "tray.2", destination: .inbox, count: model.inboxCount, countLabel: "Nachrichten")
                    sidebarRow("Ungelesen", icon: "envelope.badge", destination: .unread, count: model.unreadCount)
                    sidebarRow("Favoriten", icon: "star", destination: .flagged)
                    sidebarRow("Entwürfe", icon: "square.and.pencil", destination: .localDrafts)
                        .disabled(!model.persistentStoreReady).help("Automatisch gesicherte Entwürfe auf diesem Mac")
                    sidebarRow("Server-Entwürfe", icon: InboxModel.roleIcon(.drafts), destination: .role(.drafts))
                        .padding(.top, 12)
                    HStack {
                        Eyebrow(text: "Konten").foregroundStyle(Brand.paper.opacity(0.65))
                        Spacer()
                        Button { folderOrderAccount = model.accounts.first } label: { Image(systemName: "arrow.up.arrow.down") }
                            .buttonStyle(.plain).foregroundStyle(Brand.paper.opacity(0.75))
                            .help("Ordnerreihenfolge pro Konto ändern").accessibilityLabel("Ordnerreihenfolge ändern")
                            .accessibilityIdentifier("folder-order-open").disabled(!model.persistentStoreReady || model.accounts.isEmpty)
                    }.padding(.horizontal, 14).padding(.top, 28).padding(.bottom, 8)
                    if model.scenario != .noAccounts {
                        ForEach(model.accounts) { account in
                            DisclosureGroup(isExpanded: Binding(get: { expandedAccounts.contains(account.id) }, set: {
                                if $0 { expandedAccounts.insert(account.id) } else { expandedAccounts.remove(account.id) }
                            })) {
                                ForEach(model.orderedFolders(for: account.id)) { folder in
                                    sidebarRow(folder.name, icon: InboxModel.roleIcon(folder.role), destination: .folder(folder.id), compact: true)
                                }
                            } label: {
                                sidebarRow(account.name, icon: "envelope", destination: .account(account.id), count: model.accountUnread[account.id], status: model.syncingAccountID == account.id ? "Abgleich läuft" : InboxModel.accountStatusName(account.status), account: account)
                            }.tint(Brand.paper.opacity(0.7))
                                .contextMenu {
                                    Button("Ordnerreihenfolge …") { folderOrderAccount = account }
                                        .disabled(!model.persistentStoreReady)
                                }
                        }
                    } else {
                        Text("Noch keine Konten").font(.system(size: 13)).foregroundStyle(Brand.paper.opacity(0.75)).padding(14)
                    }
                }.padding(.horizontal, 12)
            }
            .accessibilityIdentifier("sidebar-scroll")
            if model.hasQueuedMailActions || !model.queuedMailActions.isEmpty || model.mailActionQueueError != nil {
                Button { showingMailActions = true } label: {
                    Label(model.mailActionQueueSummary, systemImage: model.mailActionQueueError != nil || model.queuedMailActions.contains(where: \.needsAttention) ? "exclamationmark.circle" : "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .medium)).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.buttonStyle(.plain).foregroundStyle(Brand.spark)
                    .background(Brand.inkSoft, in: RoundedRectangle(cornerRadius: 6)).padding(.horizontal, 14)
                    .accessibilityIdentifier("mail-action-queue")
                    .popover(isPresented: $showingMailActions) { mailActionQueueDetails }
            }
            VStack(alignment: .leading, spacing: 14) {
                SettingsLink { Label("Einstellungen", systemImage: "gearshape").font(.system(size: 13)) }
                    .buttonStyle(.plain).foregroundStyle(Brand.paper).accessibilityIdentifier("settings-link")
            }.padding(22)
        }.background(Brand.ink).environment(\.colorScheme, .dark)
    }

    private var mailActionQueueDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mailaktionen").font(Brand.headline(22))
            Text("Deine Aufträge werden zuerst auf diesem Mac gesichert und dann einzeln mit dem Server abgeglichen.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let error = model.mailActionQueueError { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.queuedMailActions) { receipt in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.mailActionLabel(receipt)).font(.system(size: 13, weight: .semibold))
                            Text((model.accounts.first { $0.id == receipt.request.accountID }?.name ?? "Postfach") + " · \(receipt.request.messageIDs.count) Nachrichten")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(receipt.createdAt, format: .dateTime.day().month().hour().minute())
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            ForEach(Array((model.mailActionSubjects[receipt.id] ?? []).enumerated()), id: \.offset) { _, subject in
                                Text(subject).font(.system(size: 11)).lineLimit(2)
                            }
                            if receipt.assistantAuthorization != nil {
                                Label("Auftrag aus ChatGPT / Work", systemImage: "bubble.left").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            if receipt.needsAttention {
                                Text("\(receipt.confirmedCount) bestätigt · \(receipt.uncertainCount) unklar · \(receipt.items.filter { $0.state == .notAttempted }.count) nicht ausgeführt")
                                    .font(.system(size: 11)).foregroundStyle(.orange)
                                Text(receipt.uncertainCount > 0 ? (receipt.blocksQueue ? "Ein früheres Ergebnis ist noch unklar und hält weitere Änderungen dieses Kontos zurück. Bitte beim Server prüfen. Der Auftrag wird nicht nochmals ausgeführt." : "Beim Server geprüft: Die gewünschte Änderung ist aktuell nicht bestätigt. Dieser Auftrag wird nicht wiederholt. Weitere Aufträge laufen weiter.") : "Die restlichen Änderungen wurden nicht ausgeführt. Bitte die Konto- und KI-Freigaben sowie die betroffenen Ordner prüfen.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                if receipt.uncertainCount > 0, receipt.undoRequestID == nil, model.gmailConfigurations[receipt.request.accountID] != nil {
                                    Button(model.checkingMailActionID == receipt.id ? "Prüfung läuft …" : "Bei Gmail prüfen") { model.retryMailActionCheck(receipt) }
                                        .font(.system(size: 11)).disabled(model.checkingMailActionID != nil)
                                        .accessibilityIdentifier("mail-action-verify-" + receipt.id.uuidString)
                                }
                                Button("Hinweis als geprüft schliessen") { model.dismissMailActionResult(receipt) }.font(.system(size: 11))
                                    .disabled(model.checkingMailActionID == receipt.id)
                            } else {
                                Label(model.queuedMailActionStatus(receipt), systemImage: model.processingMailActionID == receipt.id ? "arrow.triangle.2.circlepath" : "clock")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("mail-action-" + receipt.id.uuidString)
                        Divider()
                    }
                }
            }.frame(maxHeight: 320)
            if model.queuedMailActions.isEmpty { Text(model.hasQueuedMailActions ? "Auftrag wird gesichert …" : "Keine offenen Aufträge.").font(.system(size: 12)) }
        }.padding(22).frame(width: 380).accessibilityIdentifier("mail-action-queue-details")
    }

    private func sidebarRow(_ title: String, icon: String, destination: SidebarDestination, count: Int? = nil, countLabel: String = "ungelesen", compact: Bool = false, status: String? = nil, account: MailAccount? = nil) -> some View {
        let selected = model.destination == destination
        return Button { model.destination = destination } label: {
            HStack(spacing: 10) {
                if let account {
                    AccountSymbol(account: account)
                } else {
                    Image(systemName: icon).font(.system(size: compact ? 12 : 14)).frame(width: 19)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: compact ? 12 : 13, weight: selected ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.9)
                    if let status { Text(status).font(.system(size: 9)).foregroundStyle(Brand.paper.opacity(0.75)) }
                }
                Spacer(minLength: 2)
                if let count, count > 0 {
                    Text(count.formatted()).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Brand.paper.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
                        .help("\(count.formatted()) \(countLabel)")
                }
            }
            .foregroundStyle(selected ? Brand.spark : Brand.paper)
            .padding(.horizontal, 12).frame(minHeight: compact ? 34 : 40)
            .background(selected ? Brand.inkSoft : .clear, in: RoundedRectangle(cornerRadius: 3))
            .overlay(alignment: .leading) { if selected { Rectangle().fill(Brand.spark).frame(width: 2).padding(.vertical, 9) } }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(sidebarIdentifier(destination))
            .accessibilityLabel(title + (count.map { ", \($0.formatted()) \(countLabel)" } ?? "") + (status.map { ", " + $0 } ?? ""))
    }
    private func sidebarIdentifier(_ destination: SidebarDestination) -> String {
        switch destination {
        case .dashboard: "sidebar-dashboard"
        case .inbox: "sidebar-inbox"
        case .unread: "sidebar-unread"
        case .flagged: "sidebar-flagged"
        case .localDrafts: "local-drafts"
        case .role(let role): "sidebar-role-\(role.rawValue)"
        case .folder(let id): "sidebar-folder-\(id)"
        case .account(let id): "sidebar-account-\(id)"
        }
    }

    private var messageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Postfach").foregroundStyle(Brand.accent(scheme))
                Text(model.title).font(Brand.headline(27)).foregroundStyle(Brand.text(scheme)).accessibilityIdentifier("mailbox-title")
                Text(model.subtitle).font(.system(size: 12)).foregroundStyle(Brand.secondary(scheme))
                HStack {
                    if model.isOnlineSearch {
                        Button("Zur lokalen Suche") { model.reload() }.accessibilityIdentifier("search-local")
                    } else {
                        Button("Auf Server suchen") { model.searchOnline() }
                            .disabled(!model.canSearchOnline).accessibilityIdentifier("search-online")
                    }
                    Image(systemName: "info.circle").help(model.onlineSearchExplanation)
                }.controlSize(.small).help(model.onlineSearchExplanation)
            }.padding(24)
            if model.selection.count > 1 {
                HStack(spacing: 8) {
                    Text("\(model.selection.count) ausgewählt").font(.system(size: 11))
                    Spacer(minLength: 0)
                    Menu {
                        Button("Als gelesen markieren") { model.mutateSelection(.read) }
                        Button("Als ungelesen markieren") { model.mutateSelection(.unread) }
                        Divider()
                        Button("Favoriten hinzufügen") { model.mutateSelection(.flag) }
                        Button("Favoriten entfernen") { model.mutateSelection(.unflag) }
                        Divider()
                        ForEach(model.bulkMoveDestinations) { folder in
                            Button(folder.role == .archive ? "Archivieren" : folder.role == .trash ? "In den Papierkorb" : "Nach \(folder.name) …") {
                                if folder.role == .archive || folder.role == .trash { model.mutateSelection(.move, target: folder.id) }
                                else { bulkSnapshot = model.selection; bulkTarget = folder }
                            }
                        }
                    } label: { Label("Aktionen", systemImage: "ellipsis.circle") }
                    .disabled(!model.canMutateSelection).accessibilityIdentifier("bulk-mail-actions")
                }.padding(12).background(Brand.selection(scheme))
                if !model.canMutateSelection && !model.networkBusy {
                    Text("Bis zu 100 Nachrichten eines Kontos auswählen. Serveraktionen müssen für dieses Konto erlaubt sein.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
                }
            }
            if model.lastMailAction?.canUndo == true {
                Button("Letzte Änderung rückgängig") { model.undoLastMailAction() }
                    .font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 6)
                    .disabled(model.networkBusy || model.storageBusy).accessibilityIdentifier("undo-mail-action")
            }
            if let note = model.networkMessage, model.synchronizationProgress?.isRunning != true {
                Text(note).font(.system(size: 11)).foregroundStyle(model.networkFailed ? Color.red : Brand.secondary(scheme))
                    .padding(12).accessibilityIdentifier("network-status")
            }
            if model.scenario == .offline || model.scenario == .expired {
                Label(model.scenario == .offline ? "Offline-Vorschau" : "Anmeldung abgelaufen", systemImage: model.scenario == .offline ? "wifi.slash" : "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 12)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.selection(scheme)).foregroundStyle(Brand.text(scheme))
            }
            Divider()
            if let error = model.error {
                emptyState(model.searchInvalid ? "Suche prüfen" : "Laden nicht möglich", icon: "exclamationmark.circle", message: error)
            } else if model.isLoading && model.messages.isEmpty {
                ProgressView("Nachrichten werden geladen …").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.messages.isEmpty {
                emptyState(model.scenario == .noAccounts ? "Willkommen." : model.searchText.isEmpty ? "Alles aufgeräumt." : "Keine Treffer",
                           icon: model.scenario == .noAccounts ? "person.crop.circle.badge.plus" : "tray",
                           message: model.scenario == .noAccounts ? "Verbinde dein Konto in den Einstellungen." : model.searchText.isEmpty ? "In dieser Ansicht liegen keine Nachrichten. «Synchronisieren» gleicht alle Ordner ab." : "Versuche einen Namen, Betreff oder Dateinamen. Nachrichtentexte werden nur nach aktivierter Textindexierung durchsucht.")
            } else {
                List(selection: $model.selection) {
                    ForEach(model.displayedMessages) { message in
                        MessageRow(message: message, account: model.account(for: message), selected: model.selection.contains(message.id), conversationCount: model.visibleConversationCount(message), actionPending: model.pendingActionMessageIDs.contains(message.id))
                            .tag(message.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .accessibilityIdentifier("message-list")
            }
            if model.nextCursor != nil {
                Button(model.isOnlineSearch ? "Weitere Serverergebnisse" : "Weitere Nachrichten") { Task { await model.loadMore() } }
                    .padding(12).disabled(model.isLoading)
                    .accessibilityIdentifier("search-next-page")
            }
            Divider()
            Button { showingSearchCoverage = true } label: {
                HStack(spacing: 7) { Image(systemName: model.isOnlineSearch ? "network" : "externaldrive"); Text(model.searchCoverageLabel); Image(systemName: "info.circle") }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Brand.secondary(scheme)).padding(14)
                .accessibilityIdentifier("search-coverage")
                .popover(isPresented: $showingSearchCoverage) { SearchCoverageView(model: model) }
        }.background(Brand.canvas(scheme))
    }
    private func emptyState(_ title: String, icon: String, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(Brand.accent(scheme))
            Text(title).font(Brand.headline(24))
            Text(message).font(.system(size: 13)).foregroundStyle(Brand.secondary(scheme)).multilineTextAlignment(.center)
            if model.keychainAccessNeeded { Button("Schlüsselbundzugriff freigeben …") { Task { await model.allowKeychainAccess() } }.buttonStyle(.bordered) }
            if model.error != nil { Button("Erneut versuchen") { Task { await model.retry() } }.buttonStyle(.bordered) }
            if model.isDemoMode && model.scenario == .noAccounts { Button("Demo erkunden") { model.scenario = .standard }.buttonStyle(.bordered) }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FolderOrderEditor: View {
    @Bindable var model: InboxModel
    let account: MailAccount
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selectedAccount: AccountID?
    @ViewState private var selectedFolder: FolderID?
    @ViewState private var busy = false
    @ViewState private var notice: String?
    @ViewState private var failed = false
    @ViewState private var dropTarget: FolderID?
    private var current: AccountID { selectedAccount ?? account.id }
    private var rows: [MailFolder] { model.orderedFolders(for: current) }
    private var selectedIndex: Int? { rows.firstIndex { $0.id == selectedFolder } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Deine Ordner. Deine Reihenfolge.").font(Brand.headline(25))
            Picker("Postfach", selection: Binding(get: { current }, set: { selectedAccount = $0 })) {
                ForEach(model.accounts) { Text($0.address.value).tag($0.id) }
            }.accessibilityIdentifier("folder-order-account").disabled(busy)
            Text("Ziehe die Ordner an ihre Position oder verwende die Pfeile. Jede Änderung wird für dieses Konto gespeichert.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(rows) { folder in
                            Button { selectedFolder = folder.id } label: {
                                HStack {
                                    Image(systemName: InboxModel.roleIcon(folder.role)).frame(width: 20)
                                    Text(folder.name)
                                    Spacer()
                                    Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                                }.padding(.horizontal, 10).frame(height: 36).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .background(selectedFolder == folder.id ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(dropTarget == folder.id ? Color.accentColor : .clear))
                                .accessibilityIdentifier("folder-order-row-\(folder.id)")
                                .id(folder.id)
                                .accessibilityAddTraits(selectedFolder == folder.id ? .isSelected : [])
                                .highPriorityGesture(DragGesture(minimumDistance: 5)
                                    .onChanged { value in
                                        guard !busy, let target = dragTarget(folder: folder.id, translation: value.translation.height) else { return }
                                        dropTarget = rows[target].id
                                    }
                                    .onEnded { value in
                                        defer { dropTarget = nil }
                                        guard !busy,
                                              let source = rows.firstIndex(where: { $0.id == folder.id }),
                                              let target = dragTarget(folder: folder.id, translation: value.translation.height),
                                              source != target else { return }
                                        var changed = rows
                                        changed.move(fromOffsets: IndexSet(integer: source), toOffset: target + (target > source ? 1 : 0))
                                        selectedFolder = folder.id
                                        save(changed.map(\.id))
                                    })
                        }
                    }
                }.accessibilityIdentifier("folder-order-list").disabled(busy)
                    .onChange(of: rows.map(\.id)) { _, _ in
                        if let selectedFolder { scroll.scrollTo(selectedFolder, anchor: .center) }
                    }
            }
            HStack {
                Button { move(-1) } label: { Image(systemName: "arrow.up") }
                    .accessibilityLabel("Ordner nach oben").accessibilityIdentifier("folder-order-up")
                    .keyboardShortcut(.upArrow, modifiers: .option).help("Nach oben verschieben · ⌥↑")
                    .disabled(busy || selectedIndex == nil || selectedIndex == 0)
                Button { move(1) } label: { Image(systemName: "arrow.down") }
                    .accessibilityLabel("Ordner nach unten").accessibilityIdentifier("folder-order-down")
                    .keyboardShortcut(.downArrow, modifiers: .option).help("Nach unten verschieben · ⌥↓")
                    .disabled(busy || selectedIndex == nil || selectedIndex == rows.count - 1)
                Button("Alphabetisch") { save([]) }.disabled(busy)
                    .help("Die eigene Reihenfolge dieses Kontos zurücksetzen").accessibilityIdentifier("folder-order-reset")
                Spacer()
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction).disabled(busy)
            }
            Text(notice ?? "Die Reihenfolge bleibt auch nach dem nächsten Öffnen erhalten.")
                .font(.system(size: 11)).foregroundStyle(failed ? Color.red : Color.secondary)
        }.padding(24).frame(width: 500, height: 490)
            .onChange(of: selectedAccount) { _, _ in selectedFolder = rows.first?.id; notice = nil }
            .onAppear { selectedFolder = rows.first?.id }
    }
    private func move(_ offset: Int) {
        guard let index = selectedIndex, rows.indices.contains(index + offset) else { return }
        var changed = rows; changed.swapAt(index, index + offset); save(changed.map(\.id))
    }
    private func dragTarget(folder: FolderID, translation: CGFloat) -> Int? {
        guard let source = rows.firstIndex(where: { $0.id == folder }) else { return nil }
        // Rows stay in place while dragging, so the 36 pt row plus 2 pt spacing
        // gives a stable destination without starting a system pasteboard drag.
        return min(max(source + Int((translation / 38).rounded()), 0), rows.count - 1)
    }
    private func save(_ order: [FolderID]) {
        guard !busy else { return }
        let accountID = current
        busy = true; notice = "Wird gespeichert …"
        Task {
            defer { busy = false }
            do { try await model.saveFolderOrder(order, account: accountID); notice = "Reihenfolge gespeichert."; failed = false }
            catch { notice = "Die Reihenfolge konnte nicht gespeichert werden. Bitte erneut versuchen."; failed = true }
        }
    }
}

private struct MailToolbarButtonStyle: ButtonStyle {
    var emphasized = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, emphasized ? 10 : 6).frame(height: 30)
            .foregroundStyle(emphasized ? Brand.accent(scheme) : Brand.secondary(scheme))
            .background((configuration.isPressed || emphasized) ? Brand.selection(scheme) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

/// AppKit owns the toolbar field editor so Cmd-F reliably transfers keyboard focus.
private struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    var placeholder = "Nachrichten durchsuchen"
    var onSubmit: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focusRequest: focusRequest) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 12)
        field.setAccessibilityIdentifier("mail-search")
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.textColor = NSColor(Brand.text(scheme))
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            field.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var focusRequest: Int
        var onSubmit: () -> Void = {}
        init(text: Binding<String>, focusRequest: Int) {
            self.text = text
            self.focusRequest = focusRequest
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if let field = control as? NSSearchField { text.wrappedValue = field.stringValue }
            onSubmit()
            return true
        }
    }
}

struct MessageRow: View {
    let message: MailMessage
    let account: MailAccount?
    let selected: Bool
    var conversationCount: Int = 1
    var actionPending = false
    @Environment(\.colorScheme) private var scheme
    private var initials: String { message.sender.displayName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined() }
    private var secondaryColor: Color { selected && scheme == .light ? Brand.inkSoft : Brand.secondary(scheme) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(initials).font(.system(size: 12, weight: .medium)).frame(width: 32, height: 32)
                    .foregroundStyle(Brand.accent(scheme)).background(Brand.surface(scheme), in: RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.sender.displayName).font(.system(size: 13, weight: message.isUnread ? .semibold : .regular)).lineLimit(1)
                    Text(account?.name ?? "Postfach").font(.system(size: 10)).foregroundStyle(secondaryColor)
                }
                Spacer(minLength: 2)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(message.receivedAt, format: Calendar.current.isDateInToday(message.receivedAt) ? .dateTime.hour().minute() : .dateTime.day().month(.twoDigits).year(.twoDigits))
                        .font(.system(size: 10)).foregroundStyle(secondaryColor)
                        .help(message.receivedAt.formatted(date: .long, time: .shortened))
                    if message.isUnread { Circle().fill(Brand.accent(scheme)).frame(width: 6, height: 6).accessibilityHidden(true) }
                }
            }
            Text(message.subject).font(.system(size: 14, weight: message.isUnread ? .semibold : .medium)).lineLimit(2)
            if let preview = message.preview, !preview.isEmpty {
                Text(preview).font(.system(size: 12)).foregroundStyle(secondaryColor).lineLimit(2).lineSpacing(3)
            }
            HStack(spacing: 10) {
                if actionPending { Label("Änderung ausstehend", systemImage: "clock").font(.system(size: 10)).foregroundStyle(Brand.accent(scheme)) }
                if conversationCount > 1 { Label("\(conversationCount)", systemImage: "bubble.left.and.bubble.right").accessibilityLabel("\(conversationCount) Nachrichten in dieser Ansicht") }
                if message.isUnread { Text("Ungelesen").font(.system(size: 10, weight: .medium)).foregroundStyle(selected ? Brand.selectionAccent(scheme) : Brand.accent(scheme)) }
                Spacer()
                if message.isFlagged { Image(systemName: "star.fill").accessibilityLabel("Favorit") }
                if !message.attachments.isEmpty { Label("\(message.attachments.count)", systemImage: "paperclip") }
            }.font(.system(size: 10)).foregroundStyle(secondaryColor)
        }
        .foregroundStyle(Brand.text(scheme))
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Brand.selection(scheme) : Brand.canvas(scheme))
        .overlay(alignment: .leading) { if selected { Rectangle().fill(Brand.accent(scheme)).frame(width: 3) } }
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, 20) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("message-\(message.id)")
    }
}
