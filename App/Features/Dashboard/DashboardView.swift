import SwiftUI
import MailDomain

struct DashboardView: View {
    @Bindable var model: InboxModel
    @Environment(\.colorScheme) private var scheme
    @ViewState private var showingSync = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    heading
                    if let dashboard = model.dashboard {
                        if let error = model.error { problem(error) }
                        overview(dashboard, wide: geometry.size.width >= 880)
                        if !dashboard.accounts.isEmpty {
                            accountSection(dashboard, wide: geometry.size.width >= 880)
                            if geometry.size.width >= 790 {
                                HStack(alignment: .top, spacing: 18) {
                                    week(dashboard).frame(maxWidth: .infinity)
                                    unread(dashboard).frame(maxWidth: .infinity)
                                }
                            } else {
                                week(dashboard)
                                unread(dashboard)
                            }
                        } else { emptyAccounts }
                        footer(dashboard)
                    } else if let error = model.error {
                        problem(error)
                    } else {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text("Deine Postübersicht wird geladen …").foregroundStyle(Brand.secondary(scheme))
                        }.frame(maxWidth: .infinity, minHeight: 240)
                    }
                }.padding(geometry.size.width < 700 ? 24 : 32)
                    .frame(maxWidth: 1220).frame(maxWidth: .infinity, alignment: .top)
            }.accessibilityIdentifier("dashboard-scroll")
        }.background(Brand.canvas(scheme)).foregroundStyle(Brand.text(scheme))
            .accessibilityIdentifier("dashboard")
    }

    private var heading: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Dashboard").foregroundStyle(Brand.accent(scheme))
                Text("Deine Post im Blick.").font(Brand.headline(34))
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 5) {
                Text(Date.now, format: .dateTime.weekday(.wide)).font(.system(size: 12, weight: .medium))
                Text(Date.now, format: .dateTime.day().month(.wide)).font(Brand.mono(11))
                    .foregroundStyle(Brand.secondary(scheme))
                if let progress = model.synchronizationProgress, progress.isRunning {
                    Button { showingSync = true } label: {
                        Label("Abgleich läuft", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10)).foregroundStyle(Brand.accent(scheme))
                    }.buttonStyle(.plain).help(progress.accountName + " · " + progress.phase)
                        .popover(isPresented: $showingSync) {
                            SynchronizationStatusView(progress: progress, pause: model.cancelSynchronization) { showingSync = false }
                                .frame(width: 340)
                        }
                }
            }.accessibilityElement(children: .combine)
        }
    }

    private func overview(_ data: MailDashboard, wide: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(data.unread == 0 ? "ZEIT ZUM DURCHATMEN" : "BEREIT FÜR DEINEN BLICK")
                        .font(Brand.mono(10)).tracking(1.4).foregroundStyle(Brand.spark)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(data.unread.formatted()).font(Brand.headline(58)).monospacedDigit()
                        Text(data.unread == 1 ? "ungelesene Mail" : "ungelesene Mails")
                            .font(.system(size: 16, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(data.unread == 0 ? "Deine Posteingänge sind auf dem neuesten Lesestand." : "In deinen Posteingängen. Alles andere kann warten.")
                        .font(.system(size: 12)).foregroundStyle(Brand.paper.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                    Button { model.showDashboardDestination(data.unread == 0 ? .inbox : .unread) } label: {
                        HStack(spacing: 10) {
                            Text(data.unread == 0 ? "Zu den Posteingängen" : "Ungelesene öffnen")
                            Image(systemName: "arrow.right")
                        }.font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.ink)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Brand.spark, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).padding(.top, 8).accessibilityIdentifier("dashboard-open-unread")
                }.frame(maxWidth: .infinity, alignment: .leading)
                inboxRing(data).frame(width: 120, height: 120)
                if wide {
                    Rectangle().fill(Brand.paper.opacity(0.13)).frame(width: 1, height: 136)
                    VStack(alignment: .leading, spacing: 20) {
                        heroMetric(data.inbox, title: "Im Posteingang", icon: "tray", destination: .inbox)
                        heroMetric(data.flagged, title: "Favoriten", icon: "star", destination: .flagged)
                        heroMetric(model.savedDrafts.filter { $0.status.editable }.count, title: "Entwürfe", icon: "square.and.pencil", destination: .localDrafts)
                    }.frame(width: 145)
                }
            }.padding(24)
            if !wide {
            HStack(spacing: 0) {
                heroMetric(data.inbox, title: "Im Posteingang", icon: "tray", destination: .inbox)
                Rectangle().fill(Brand.paper.opacity(0.13)).frame(width: 1, height: 30)
                heroMetric(data.flagged, title: "Favoriten", icon: "star", destination: .flagged)
                Rectangle().fill(Brand.paper.opacity(0.13)).frame(width: 1, height: 30)
                heroMetric(model.savedDrafts.filter { $0.status.editable }.count, title: "Entwürfe", icon: "square.and.pencil", destination: .localDrafts)
            }.padding(.vertical, 16).background(.white.opacity(0.04))
            }
        }
        .foregroundStyle(Brand.paper)
        .background(LinearGradient(colors: [Brand.inkSoft, Brand.ink], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.line.opacity(0.14), lineWidth: 1) }
    }

    private func inboxRing(_ data: MailDashboard) -> some View {
        let fraction = data.inbox > 0 ? Double(data.unread) / Double(data.inbox) : 0
        return ZStack {
            Circle().stroke(Brand.paper.opacity(0.11), lineWidth: 9)
            if fraction > 0 {
                Circle().trim(from: 0, to: min(1, fraction))
                    .stroke(AngularGradient(colors: [Brand.spark, Brand.copperLight], center: .center, startAngle: .degrees(0), endAngle: .degrees(360)),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 5) {
                Image(systemName: data.unread == 0 ? "checkmark" : "envelope.badge")
                    .font(.system(size: 25, weight: .light)).foregroundStyle(Brand.spark)
                Text("POSTEINGANG").font(Brand.mono(8)).tracking(1).foregroundStyle(Brand.paper.opacity(0.7))
                Text(data.inbox.formatted() + " Mails").font(.system(size: 11))
            }
        }.padding(6).accessibilityElement(children: .ignore)
            .accessibilityLabel("\(data.unread) von \(data.inbox) Nachrichten im Posteingang sind ungelesen")
    }

    private func heroMetric(_ value: Int, title: String, icon: String, destination: SidebarDestination) -> some View {
        Button { model.showDashboardDestination(destination) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16, weight: .light)).foregroundStyle(Brand.spark)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.formatted()).font(Brand.headline(22)).monospacedDigit()
                    Text(title).font(.system(size: 10)).foregroundStyle(Brand.paper.opacity(0.7))
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 20).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(title), \(value)")
            .disabled(destination == .localDrafts && !model.persistentStoreReady)
    }

    private func accountSection(_ data: MailDashboard, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("Deine Konten")
                Spacer()
                Text("\(data.accounts.count) Konten").font(Brand.mono(10)).foregroundStyle(Brand.secondary(scheme))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: wide ? 4 : 2), spacing: 12) {
                ForEach(data.accounts) { item in accountCard(item) }
            }
        }
    }

    private func accountCard(_ item: MailDashboard.Account) -> some View {
        Button {
            let inbox = model.folders.first { $0.accountID == item.id && $0.role == .inbox }
            model.showDashboardDestination(inbox.map { .folder($0.id) } ?? .account(item.id))
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    AccountSymbol(account: item.account, onDarkBackground: scheme == .dark)
                        .frame(width: 34, height: 34).background(Brand.canvas(scheme), in: RoundedRectangle(cornerRadius: 9))
                    Spacer()
                    Text(item.unread == 0 ? "Gelesen" : "\(item.unread) ungelesen")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(item.unread == 0 ? Brand.secondary(scheme) : Brand.accent(scheme))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Brand.accent(scheme).opacity(item.unread == 0 ? 0 : 0.08), in: Capsule())
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.account.name).font(Brand.headline(18)).lineLimit(1)
                    Text(item.account.address.value).font(.system(size: 10)).foregroundStyle(Brand.secondary(scheme)).lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(item.inbox.formatted()).font(Brand.headline(24)).monospacedDigit()
                    Text("im Posteingang").font(.system(size: 10)).foregroundStyle(Brand.secondary(scheme))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(Brand.secondary(scheme))
                }
                Text(accountState(item)).font(.system(size: 9)).foregroundStyle(Brand.secondary(scheme)).lineLimit(1)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.surface(scheme), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.line.opacity(0.22), lineWidth: 0.7) }
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(DashboardCardStyle()).help("Posteingang von \(item.account.name) öffnen · \(item.total.formatted()) Nachrichten im Konto")
            .accessibilityIdentifier("dashboard-account-\(item.id)")
    }

    private func accountState(_ item: MailDashboard.Account) -> String {
        if model.syncingAccountID == item.id { return "Wird gerade aktualisiert …" }
        if item.account.status == .requiresAuthentication { return "Erneute Anmeldung nötig" }
        if item.account.status == .offline { return "Offline · gespeicherter Stand" }
        if let date = item.lastSync { return "Abgleich \(date.formatted(.dateTime.day().month(.twoDigits).hour().minute()))" }
        return item.account.status == .demo ? "Beispielkonto" : "Noch kein Abgleich"
    }

    private func week(_ data: MailDashboard) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    sectionTitle("Die letzten 7 Tage")
                    Text("Im Posteingang · nach Empfangsdatum").font(.system(size: 10)).foregroundStyle(Brand.secondary(scheme))
                }
                Spacer()
                Text(data.weekTotal.formatted()).font(Brand.headline(28)).monospacedDigit().foregroundStyle(Brand.accent(scheme))
            }
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(data.days) { day in
                    Button { model.showDashboardDay(day) } label: {
                        VStack(spacing: 8) {
                            VStack(spacing: 5) {
                                Spacer(minLength: 0)
                                Text(day.count.formatted()).font(Brand.mono(10)).foregroundStyle(Brand.secondary(scheme))
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(LinearGradient(colors: day.date == data.days.last?.date ? [Brand.copperLight, Brand.copper] : [Brand.accent(scheme).opacity(0.35), Brand.accent(scheme).opacity(0.18)], startPoint: .top, endPoint: .bottom))
                                    .frame(height: day.count == 0 ? 0 : max(3, 83 * Double(day.count) / Double(max(1, data.days.map(\.count).max() ?? 1))))
                            }.frame(height: 108)
                            Rectangle().fill(Brand.line.opacity(0.3)).frame(height: 1)
                            Text(day.date == data.days.last?.date ? "Heute" : day.date.formatted(.dateTime.weekday(.abbreviated)))
                                .font(.system(size: 10, weight: day.date == data.days.last?.date ? .semibold : .regular))
                                .foregroundStyle(Brand.secondary(scheme))
                        }.frame(maxWidth: .infinity).contentShape(Rectangle())
                    }.buttonStyle(DashboardCardStyle())
                        .help("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.count) Nachrichten im Posteingang")
                        .accessibilityLabel("\(day.date.formatted(date: .complete, time: .omitted)), \(day.count) Nachrichten. Posteingang öffnen.")
                }
            }
            Text(data.weekTotal == 0 ? "Keine Nachrichten aus diesen Tagen im Posteingang." : "Wähle einen Tag, um seine Nachrichten zu öffnen.")
                .font(.system(size: 10)).foregroundStyle(Brand.secondary(scheme))
        }.padding(20).dashboardPanel(scheme).accessibilityIdentifier("dashboard-week")
    }

    private func unread(_ data: MailDashboard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle("Zuletzt eingetroffen")
                Spacer()
                Button { model.showDashboardDestination(.unread) } label: { Image(systemName: "arrow.right") }
                    .buttonStyle(.plain).foregroundStyle(Brand.accent(scheme)).accessibilityLabel("Alle ungelesenen Nachrichten öffnen")
            }
            if data.recentUnread.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(Brand.accent(scheme))
                    Text("Alles gelesen.").font(Brand.headline(20))
                    Text("Keine ungelesene Mail im Posteingang.").font(.system(size: 11)).foregroundStyle(Brand.secondary(scheme))
                }.frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Text("Ungelesen in deinen Posteingängen").font(.system(size: 10)).foregroundStyle(Brand.secondary(scheme))
                VStack(spacing: 0) {
                    ForEach(data.recentUnread) { message in
                        Button { model.openDashboardMessage(message) } label: {
                            HStack(spacing: 10) {
                                Circle().fill(Brand.accent(scheme)).frame(width: 5, height: 5).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(message.sender.name.isEmpty ? message.sender.address.value : message.sender.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(message.receivedAt, format: .dateTime.day().month(.twoDigits)).font(Brand.mono(9)).foregroundStyle(Brand.secondary(scheme))
                                    }
                                    Text(message.subject.isEmpty ? "Ohne Betreff" : message.subject).font(.system(size: 11)).lineLimit(1).foregroundStyle(Brand.secondary(scheme))
                                }
                            }.padding(.vertical, 9).contentShape(Rectangle())
                        }.buttonStyle(DashboardCardStyle()).accessibilityIdentifier("dashboard-message-\(message.id)")
                        if message.id != data.recentUnread.last?.id { Divider().opacity(0.5) }
                    }
                }
            }
        }.padding(20).dashboardPanel(scheme)
    }

    private func footer(_ data: MailDashboard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let progress = model.synchronizationProgress, progress.state != .completed {
                SynchronizationStatusView(progress: progress, pause: model.cancelSynchronization) { model.synchronizationProgress = nil }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "externaldrive").foregroundStyle(Brand.accent(scheme))
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(data.total.formatted()) Nachrichten in \(data.accounts.count) Konten · Übersicht \(data.refreshedAt.formatted(date: .omitted, time: .shortened))")
                    Text(model.isDemoMode ? "Beispieldaten" : model.desktop.status)
                    if !data.accounts.isEmpty && data.accounts.contains(where: { !$0.complete && $0.account.status != .demo }) {
                        Text("Die Zahlen zeigen den bisher synchronisierten Bestand.")
                    }
                }
                Spacer(minLength: 0)
                if model.isLoading { ProgressView().controlSize(.mini).accessibilityLabel("Übersicht wird aktualisiert") }
            }.font(.system(size: 10)).foregroundStyle(Brand.secondary(scheme))
        }
    }

    private var emptyAccounts: some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope.open").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(Brand.accent(scheme))
            Text("Deine Konten machen den Anfang.").font(Brand.headline(24))
            Text("Verbinde ein Mailkonto, damit hier deine Postübersicht entsteht.").font(.system(size: 12)).foregroundStyle(Brand.secondary(scheme))
            SettingsLink { Text("Konto hinzufügen") }.buttonStyle(.bordered)
        }.frame(maxWidth: .infinity).padding(32).dashboardPanel(scheme)
    }

    private func problem(_ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Brand.accent(scheme))
            Text(text).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            Button("Erneut laden") { Task { await model.start(autoSelectDemo: false) } }.buttonStyle(.bordered)
        }.padding(16).dashboardPanel(scheme)
    }

    private func sectionTitle(_ text: String) -> some View { Text(text).font(Brand.headline(20)) }
}

private struct DashboardCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private extension View {
    func dashboardPanel(_ scheme: ColorScheme) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surface(scheme), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.line.opacity(0.22), lineWidth: 0.7) }
    }
}
