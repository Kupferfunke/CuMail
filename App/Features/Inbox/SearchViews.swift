import SwiftUI
import MailApplication
import MailDomain

struct SearchFiltersView: View {
    @Bindable var model: InboxModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var draft: String
    @ViewState private var field = "from"
    @ViewState private var value = ""
    init(model: InboxModel) { self.model = model; _draft = ViewState(initialValue: model.searchText) }
    private var validation: String? {
        do { _ = try MailSearchParser.parse(draft); return nil }
        catch { return (error as? SearchFailure)?.errorDescription ?? "Bitte prüfe die Eingabe." }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Post gezielt finden").font(Brand.headline(27))
            Text("Alle Begriffe und Filter werden kombiniert. Die gewählte Postfachansicht begrenzt die Suche zusätzlich.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Suche", text: $draft, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("search-filter-query")
            HStack {
                Picker("Feld", selection: $field) {
                    Text("Absender").tag("from"); Text("Empfänger").tag("to")
                    Text("Betreff").tag("subject"); Text("Dateiname").tag("filename")
                    Text("Ab Datum").tag("after"); Text("Vor Datum").tag("before")
                }.frame(width: 180).accessibilityIdentifier("search-field-kind")
                TextField(field == "after" || field == "before" ? "JJJJ-MM-TT" : "Wert", text: $value)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("search-field-value")
                Button("Einfügen") {
                    append(field + ":" + (field == "after" || field == "before" ? value : MailSearchParser.quote(value)))
                    value = ""
                }.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("insert-search-filter")
            }
            HStack {
                Menu("Konto") {
                    ForEach(model.accounts) { account in
                        Button(account.name + " · " + account.address.value) { append("account:" + MailSearchParser.quote(account.address.value)) }
                    }
                }
                Menu("Ordner") {
                    ForEach(model.accounts) { account in
                        Menu(account.name) {
                            ForEach(model.folders.filter { $0.accountID == account.id }) { folder in
                                Button(folder.name) {
                                    if (try? MailSearchParser.parse(draft).account) == nil { append("account:" + MailSearchParser.quote(account.address.value)) }
                                    append("folder:" + MailSearchParser.quote(folder.name))
                                }
                            }
                        }
                    }
                }
                Button("Ungelesen") { append("is:unread") }
                Button("Favoriten") { append("is:flagged") }
                Button("Mit Anhang") { append("has:attachment") }.accessibilityIdentifier("filter-has-attachment")
            }.controlSize(.small)
            Text("Beispiele").font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 5) {
                Text("Rechnung after:2026-01-01 before:2026-02-01")
                Text("from:\"Lena Beispiel\" has:attachment")
            }.font(Brand.mono(11)).textSelection(.enabled)
            Text("Ohne Anführungszeichen wird auch der Wortanfang gefunden. Anführungszeichen suchen eine genaue Wortfolge. «Ab» zählt ab Mitternacht mit; «Vor» schliesst diesen Tag aus. Zeitzone: \(TimeZone.current.identifier).")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let validation { Text(validation).font(.system(size: 12)).foregroundStyle(.red).accessibilityIdentifier("search-filter-error") }
            HStack {
                Button("Zurücksetzen") { draft = "" }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Suchen") { model.searchText = draft; dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(validation != nil).accessibilityIdentifier("apply-search-filters")
            }
        }.padding(28).frame(width: 620)
    }
    private func append(_ token: String) {
        draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft += (draft.isEmpty ? "" : " ") + token
    }
}

struct SearchCoverageView: View {
    @Bindable var model: InboxModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Suchabdeckung").font(Brand.headline(24))
                if model.isOnlineSearch {
                    Text("Quelle: Mailserver · Ergebnisse nur im Arbeitsspeicher").font(.system(size: 12, weight: .semibold))
                    Text("\(model.messages.count) Treffer geladen. \(model.onlineFolderTotal ?? 0) Nachrichten liegen insgesamt im ausgewählten Ordner.")
                    if let date = model.onlineCheckedAt { Text("Geprüft: \(date.formatted(date: .abbreviated, time: .shortened))") }
                    Text("Die Serversuche arbeitet mit Teilzeichenfolgen und der Suchsemantik des Anbieters, die lokale Suche mit Wörtern. Online werden höchstens 4096 UID-Positionen pro Schritt geprüft und 50 Treffer geladen. Weitere Ergebnisse können auch nach einer leeren Seite folgen. Reihenfolge: absteigende Server-UID. Neue Nachrichten nach Suchbeginn werden erst bei einer neuen Suche berücksichtigt.")
                    Text("Nachrichteninhalte werden erst beim Öffnen geladen. Online-Treffer werden nicht automatisch in den lokalen Index übernommen.")
                } else if let coverage = model.coverage {
                    Text(coverage.isSynthetic ? "Quelle: lokaler Index · synthetische Daten" : "Quelle: verschlüsselter lokaler Index").font(.system(size: 12, weight: .semibold))
                    Text("\(coverage.messageCount) Treffer · \(coverage.eligibleMessageCount) Metadatensätze im Filterbereich")
                    Text("\(coverage.indexedTextCount) Texte indexiert · \(coverage.truncatedTextCount) davon gekürzt")
                    if let oldest = coverage.oldest, let newest = coverage.newest {
                        Text("Erfasster Zeitraum: \(oldest.formatted(date: .abbreviated, time: .omitted)) – \(newest.formatted(date: .abbreviated, time: .omitted))")
                    } else { Text("Für diesen Filterbereich ist noch kein Zeitraum erfasst.") }
                    Text("Die Textsuche umfasst nur ausdrücklich gespeicherte Extrakte. Fehlende oder gekürzte Texte können weitere Treffer enthalten. Der Metadatenabgleich erfasst den gesamten Bestand aller Ordner. Ein laufender Erstabgleich kann noch unvollständig sein.")
                    ForEach(coverage.folders, id: \.folderID) { folder in
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text((model.accounts.first { $0.id == folder.accountID }?.name ?? "Konto") + " · " + folder.name)
                                .fontWeight(.semibold)
                            Text("\(folder.indexedCount) lokal" + (folder.serverCount.map { " von \($0) auf dem Server" } ?? " · Serverbestand unbekannt"))
                            Text(folder.lastSuccess.map { "Abgeglichen: " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Noch kein Serverabgleich")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else { Text("Die Abdeckung erscheint nach einer gültigen Suche.") }
            }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(22)
        }.frame(width: 410, height: 430)
    }
}
