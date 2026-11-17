import SwiftUI
import MailDomain
import MailApplication
import AppKit

struct MessageDetailView: View {
    @Bindable var model: InboxModel
    @Environment(\.colorScheme) private var scheme
    @ViewState private var moveRequest: MoveRequest?
    @ViewState private var confirmMove = false
    @ViewState private var linkTarget: URL?
    @ViewState private var confirmLink = false
    @ViewState private var conversationExpanded = true
    @ViewState private var htmlDocumentHeight: CGFloat = 420
    private struct MoveRequest { let message: MessageID; let folder: MailFolder; let account: String }

    var body: some View {
        VStack(spacing: 0) {
            if let message = model.selectedMessage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Label(model.account(for: message)?.name ?? "Demo", systemImage: "tray")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(Brand.selectionAccent(scheme))
                                .padding(.horizontal, 10).padding(.vertical, 6).background(Brand.selection(scheme), in: RoundedRectangle(cornerRadius: 3))
                            Spacer()
                            if message.isFlagged { Image(systemName: "star.fill").foregroundStyle(Brand.accent(scheme)).accessibilityLabel("Favorit") }
                            if let folder = model.folders.first(where: { message.folderIDs.contains($0.id) }) {
                                Text(folder.name).font(.system(size: 11)).foregroundStyle(Brand.secondary(scheme))
                            }
                        }.padding(.bottom, 24)
                        messageActions(message).padding(.bottom, 20)
                        if model.conversation.count > 1 {
                            DisclosureGroup(isExpanded: $conversationExpanded) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(model.conversation) { item in
                                        Button { model.openConversationMessage(item.id) } label: {
                                            HStack {
                                                Image(systemName: item.id == message.id ? "envelope.open" : "envelope")
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(item.subject).lineLimit(1)
                                                    Text(item.sender.displayName + " · " + item.receivedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10))
                                                }
                                                Spacer()
                                                if item.isUnread { Text("Ungelesen").font(.system(size: 10)) }
                                            }.padding(8)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(item.id == message.id ? Brand.selection(scheme) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                                                .contentShape(Rectangle())
                                        }.buttonStyle(.plain).accessibilityIdentifier("thread-message-\(item.id)")
                                    }
                                    if model.conversationCursor != nil {
                                        Button("Weitere Gesprächsnachrichten") { Task { await model.loadMoreConversation() } }.disabled(model.conversationLoading)
                                    }
                                }.padding(.top, 8)
                            } label: {
                                Text("Gespräch · \(model.conversation.count) Nachrichten im lokalen Bestand").font(.system(size: 12, weight: .medium))
                            }.padding(.bottom, 22)
                        }
                        Text(message.subject).font(.system(size: 27, weight: .semibold)).lineSpacing(3)
                            .textSelection(.enabled).accessibilityIdentifier("message-subject")
                            .padding(.bottom, 24)
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "person.crop.circle.fill").font(.system(size: 34, weight: .light)).foregroundStyle(Brand.secondary(scheme))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.sender.displayName).font(.system(size: 13, weight: .semibold))
                                Text(message.sender.address.value).font(.system(size: 11)).foregroundStyle(Brand.secondary(scheme)).textSelection(.enabled)
                                Text("An: " + message.recipients.map { $0.address.value }.joined(separator: ", "))
                                    .font(.system(size: 11)).foregroundStyle(Brand.secondary(scheme)).textSelection(.enabled)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 5) {
                                Text(message.receivedAt, format: .dateTime.day().month(.abbreviated).year())
                                Text(message.receivedAt, format: .dateTime.hour().minute())
                            }.font(.system(size: 10)).foregroundStyle(Brand.secondary(scheme))
                        }.padding(.bottom, 24)
                        Divider().padding(.bottom, 28)
                        Picker("Nachrichtendarstellung", selection: $model.showHTML) {
                            Text("Text").tag(false)
                            Text("HTML").tag(true).disabled(model.htmlAvailable == false)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 170).accessibilityIdentifier("body-format").padding(.bottom, 14)
                        if let note = model.contentNote {
                            Text(note).font(.system(size: 11)).foregroundStyle(Brand.secondary(scheme)).padding(.bottom, 14)
                        }
                        if model.contentLoading {
                            ProgressView("Nachricht wird geöffnet …").padding(.vertical, 30)
                        } else if let error = model.contentError {
                            Label(error, systemImage: "info.circle").font(.system(size: 14)).foregroundStyle(Brand.secondary(scheme)).padding(.vertical, 28)
                            Button("Erneut öffnen") { model.loadContent() }.disabled(model.networkBusy)
                        } else if model.showHTML, let safe = model.safeHTML {
                            if safe.unavailableImageCount > 0 { Text("Einige eingebettete Bilder sind noch nicht verfügbar.").font(.system(size: 11)).foregroundStyle(.secondary) }
                            SafeMailWebView(html: safe, dark: scheme == .dark, allowRemoteImages: !model.selectedIsDemo,
                                openLink: { linkTarget = $0; confirmLink = true }, failed: { model.contentError = "Die HTML-Ansicht konnte nicht geladen werden. Wechsle zur Textansicht." },
                                heightChanged: { height in if abs(htmlDocumentHeight - height) > 1 { htmlDocumentHeight = height } })
                                .frame(height: htmlDocumentHeight)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .id(message.id)
                        } else {
                            Text(model.content).font(.system(size: 14)).lineSpacing(7).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("message-body")
                        }
                        if !message.attachments.isEmpty {
                            Divider().padding(.top, 30).padding(.bottom, 20)
                            Text("Anhänge").font(.system(size: 12, weight: .semibold)).padding(.bottom, 10)
                            ForEach(message.attachments) { attachment in
                                HStack(spacing: 12) {
                                    Image(systemName: attachment.mimeType == "application/pdf" ? "doc.richtext" : "photo").font(.system(size: 22)).foregroundStyle(Brand.accent(scheme))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(AttachmentSafety.filename(attachment.filename)).font(.system(size: 12, weight: .medium))
                                        Text("\(attachment.byteCount.formatted(.byteCount(style: .file))) · \(attachment.mimeType)").font(.system(size: 10)).foregroundStyle(Brand.secondary(scheme))
                                    }
                                    Spacer()
                                    if let controller = model.attachmentController, controller.busy, controller.selected == attachment.id {
                                        ProgressView().controlSize(.small)
                                        Button("Abbrechen") { controller.cancel() }.accessibilityIdentifier("attachment-cancel")
                                    } else {
                                        Button("Vorschau / Sichern …") { model.openAttachment(attachment) }
                                            .disabled(model.attachmentController == nil || model.attachmentController?.busy == true || model.contentLoading || model.networkBusy || model.storageBusy)
                                            .accessibilityIdentifier("attachment-open-" + attachment.id.description)
                                    }
                                }.padding(14).background(Brand.canvas(scheme), in: RoundedRectangle(cornerRadius: 3))
                            }
                            if let controller = model.attachmentController {
                                if controller.busy {
                                    Text("Übertragen: \(controller.received.formatted(.byteCount(style: .file)))" + (controller.expected.map { " von \($0.formatted(.byteCount(style: .file)))" } ?? ""))
                                        .font(.system(size: 11)).accessibilityIdentifier("attachment-progress")
                                }
                                if let status = controller.status { Text(status).font(.system(size: 11)).foregroundStyle(controller.failed ? Color.red : .secondary) }
                            }
                            Text(model.selectedIsDemo ? "Die Demo lädt eine gekennzeichnete synthetische Testdatei." : "Download nur auf Auswahl · bis 8 MiB, bei IMAP inklusive Kodierung. Vorschau wird beim Schliessen entfernt.").font(.system(size: 10)).foregroundStyle(Brand.secondary(scheme)).padding(.top, 8)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { responseButtons }
                            VStack(alignment: .leading, spacing: 8) { responseButtons }
                        }.buttonStyle(.bordered).padding(.top, 30)
                        Text(!model.selectedIsDemo && !message.threadingHeadersLoaded ? "Bitte den Ordner synchronisieren, damit Antwortadressen vollständig sind." : "Antworten verwenden das ursprüngliche Konto. Entwürfe bleiben auf diesem Mac.")
                            .font(.system(size: 10)).foregroundStyle(Brand.secondary(scheme)).padding(.top, 10)
                    }
                    .padding(32).frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity)
                }
                // A new message is a new document: reset scroll and selectable-text accessibility state.
                .id(message.id)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: model.selection.count > 1 ? "rectangle.stack" : "tray").font(.system(size: 36, weight: .ultraLight)).foregroundStyle(Brand.accent(scheme))
                    Text(model.selection.count > 1 ? "\(model.selection.count) Nachrichten ausgewählt" : "Raum für deine Post.").font(Brand.headline(28))
                    Text(model.selection.count > 1 ? "Die Aktionen oberhalb der Nachrichtenliste gelten für deine Auswahl." : "Wähle links eine Nachricht aus.")
                        .font(.system(size: 13)).foregroundStyle(Brand.secondary(scheme)).multilineTextAlignment(.center)
                }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.foregroundStyle(Brand.text(scheme)).background(Brand.surface(scheme))
        .sheet(item: Binding(get: { model.attachmentController?.prepared }, set: { model.attachmentController?.prepared = $0 }), onDismiss: {
            model.attachmentController?.closePreview()
        }) { item in
            if let controller = model.attachmentController { AttachmentSheet(controller: controller, item: item) }
        }
        .onChange(of: model.selectedMessage?.id) { _, _ in
            htmlDocumentHeight = 420
            Task { await model.attachmentController?.stopAndWait() }
        }
        .alert("Nachricht verschieben?", isPresented: $confirmMove, presenting: moveRequest) { request in
            Button("Abbrechen", role: .cancel) {}
            Button("Verschieben") { model.mutate(.move(request.folder), expectedMessage: request.message) }.accessibilityIdentifier("confirm-message-move")
        } message: { request in Text("Konto: \(request.account)\nZiel: \(request.folder.name)\nDie Nachricht wird in diesen Ordner verschoben.") }
        .alert("Link im Browser öffnen?", isPresented: $confirmLink) {
            Button("Abbrechen", role: .cancel) {}
            Button("Im Browser öffnen") { if let url = linkTarget { NSWorkspace.shared.open(url) } }
        } message: { Text(linkTarget?.absoluteString ?? "") }

    }
    @ViewBuilder private var responseButtons: some View {
        Button { model.compose(kind: .reply) } label: { Label("Antworten", systemImage: "arrowshape.turn.up.left") }.disabled(!model.canRespond).accessibilityIdentifier("compose-reply")
        Button { model.compose(kind: .replyAll) } label: { Label("Allen antworten", systemImage: "arrowshape.turn.up.left.2") }.disabled(!model.canRespond).accessibilityIdentifier("compose-reply-all")
        Button { model.compose(kind: .forward) } label: { Label("Weiterleiten", systemImage: "arrowshape.turn.up.right") }.disabled(!model.canRespond).accessibilityIdentifier("compose-forward")
    }
    private func requestMove(_ folder: MailFolder, message: MailMessage) {
        if folder.role == .archive || folder.role == .trash {
            model.mutate(.move(folder), expectedMessage: message.id)
            return
        }
        moveRequest = MoveRequest(message: message.id, folder: folder, account: model.account(for: message)?.name ?? "Konto")
        confirmMove = true
    }
    @ViewBuilder private func messageActions(_ message: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { model.mutate(.read(message.isUnread)) } label: {
                    Label(message.isUnread ? "Gelesen" : "Ungelesen", systemImage: message.isUnread ? "envelope.open" : "envelope.badge")
                }.help(message.isUnread ? "Als gelesen markieren" : "Als ungelesen markieren").accessibilityIdentifier("mark-read")
                Button { model.mutate(.flagged(!message.isFlagged)) } label: { Image(systemName: message.isFlagged ? "star.fill" : "star") }
                    .help(message.isFlagged ? "Favorit entfernen" : "Als Favorit markieren").accessibilityLabel(message.isFlagged ? "Favorit entfernen" : "Als Favorit markieren").accessibilityIdentifier("toggle-flag")
                Menu {
                    ForEach(model.moveDestinations) { folder in Button(folder.name) { requestMove(folder, message: message) } }
                } label: { Image(systemName: "folder") }.help("In einen Ordner dieses Kontos verschieben").accessibilityLabel("Verschieben").accessibilityIdentifier("move-message")
                Button { if let folder = model.targetFolder(.archive) { requestMove(folder, message: message) } } label: { Image(systemName: "archivebox") }
                    .disabled(model.targetFolder(.archive) == nil).help("Archivieren").accessibilityLabel("Archivieren").accessibilityIdentifier("archive-message")
                Button { if let folder = model.targetFolder(.trash) { requestMove(folder, message: message) } } label: { Image(systemName: "trash") }
                    .disabled(model.targetFolder(.trash) == nil).help("In den Papierkorb verschieben").accessibilityLabel("In den Papierkorb verschieben").accessibilityIdentifier("trash-message")
                Spacer(minLength: 0)
            }.buttonStyle(.bordered).disabled(!model.canMutate)
            if model.pendingAccounts.contains(message.accountID) {
                Text("Ein Aktionsergebnis wartet auf den Abgleich. Bitte synchronisieren.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if !model.selectedIsDemo && model.accountSettings[message.accountID]?.serverActionsEnabled != true {
                Text("Lesender Zugriff · Serveraktionen lassen sich in den Kontoeinstellungen freigeben.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

}
