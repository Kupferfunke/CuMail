import Foundation
import MailDomain
import MailApplication

public struct DemoDataset: Sendable {
    public let snapshot: MailSnapshot
    public let contents: [MessageID: String]
    public static func empty() throws -> DemoDataset {
        DemoDataset(snapshot: try MailSnapshot(accounts: [], folders: [], threads: [], messages: []), contents: [:])
    }
    public var scope: AccessScope { AccessScope(accountIDs: Set(snapshot.accounts.map(\.id))) }
    public func repository() -> InMemoryMailRepository { InMemoryMailRepository(snapshot: snapshot, contents: contents) }
}

public enum SyntheticFixtures {
    /// Deterministic, fictional identities on reserved example.com addresses. No clock/randomness/network.
    public static func make() throws -> DemoDataset {
        func aid(_ n: Int) throws -> AccountID { try AccountID(string: String(format: "10000000-0000-4000-8000-%012d", n)) }
        func fid(_ n: Int) throws -> FolderID { try FolderID(string: String(format: "20000000-0000-4000-8000-%012d", n)) }
        func mid(_ n: Int) throws -> MessageID { try MessageID(string: String(format: "30000000-0000-4000-8000-%012d", n)) }
        func tid(_ n: Int) throws -> ThreadID { try ThreadID(string: String(format: "40000000-0000-4000-8000-%012d", n)) }
        let accounts = try [
            MailAccount(id: aid(1), name: "Werkstatt", address: EmailAddress("werkstatt@example.com"), provider: .imap),
            MailAccount(id: aid(2), name: "Persönlich", address: EmailAddress("privat@example.com"), provider: .gmail),
            MailAccount(id: aid(3), name: "Projekte", address: EmailAddress("projekte@example.com"), provider: .microsoft)
        ]
        let roles: [(FolderRole, String)] = [(.inbox,"Posteingang"),(.sent,"Gesendet"),(.drafts,"Entwürfe"),(.archive,"Archiv"),(.trash,"Papierkorb")]
        var folders: [MailFolder] = []
        for (a, account) in accounts.enumerated() {
            for (r, role) in roles.enumerated() {
                folders.append(try MailFolder(id: fid(a * 10 + r + 1), accountID: account.id, providerID: role.0.rawValue, name: role.1, role: role.0))
            }
        }
        struct Sample {
            let account: Int; let sender: String; let email: String; let subject: String
            let preview: String; let body: String; let unread: Bool; let flagged: Bool; let attachment: String?
            var role: FolderRole = .inbox
        }
        let samples: [Sample] = [
            .init(account: 0, sender: "Lena Muster", email: "lena", subject: "Die nächste Version nimmt Form an",
                  preview: "Die Muster sind da. Lass uns die Details gemeinsam anschauen.",
                  body: "Hoi Mike\n\nDie neuen Materialmuster sind angekommen. Das matte Papier und der warme Kupferton passen gut zusammen.\n\nIch habe die drei Varianten in der Übersicht zusammengestellt. Mein Favorit ist die zweite: klare Kanten, genug Raum und ein kleiner Funke an der richtigen Stelle.\n\nFür den nächsten Versuch würde ich zwei Dinge prüfen:\n\n• Bleibt das Zeichen auch in kleiner Grösse gut lesbar?\n• Fühlt sich die Oberfläche im Alltag angenehm an?\n\nWir können die Muster am Donnerstag in Ruhe vergleichen. Ich bringe die Skizzen mit.\n\nLiebe Grüsse\nLena",
                  unread: true, flagged: true, attachment: "Materialstudie.pdf"),
            .init(account: 2, sender: "Jonas Beispiel", email: "jonas", subject: "Werkstattnotiz · erste Rückmeldungen",
                  preview: "Drei Beobachtungen aus unserem letzten Prototypentest.", body: "Hoi Mike\n\nDer Prototyp ist durch den ersten Test. Die Navigation war verständlich. Bei den kleinen Beschriftungen brauchen wir noch etwas mehr Kontrast.\n\nAls Nächstes testen wir die überarbeitete Variante mit der Tastatur.\n\nViele Grüsse\nJonas", unread: true, flagged: false, attachment: nil),
            .init(account: 1, sender: "Nora Beispiel", email: "nora", subject: "Am Samstag an den See?",
                  preview: "Eine kleine Runde, ein Kaffee und etwas frische Luft.", body: "Hoi Mike\n\nWie wäre es am Samstag mit einem Spaziergang am See? Wir könnten danach einen Kaffee trinken.\n\nLiebe Grüsse\nNora", unread: true, flagged: false, attachment: nil),
            .init(account: 0, sender: "Atelier Muster", email: "atelier", subject: "Papiermuster für den nächsten Versuch",
                  preview: "Die Übersicht zu Grammatur, Oberfläche und Format.", body: "Guten Tag\n\nHier ist die fiktive Übersicht unserer Papiermuster. Alle Werte und Dateien in dieser Demo dienen nur der Gestaltung.\n\nFreundliche Grüsse\nAtelier Muster", unread: false, flagged: true, attachment: "Papierübersicht.pdf"),
            .init(account: 2, sender: "Mara Muster", email: "mara", subject: "Ein guter nächster Schritt",
                  preview: "Die überarbeitete Skizze ist bereit zum Besprechen.", body: "Hoi Mike\n\nDie Skizze ist überarbeitet. Wir haben den Einstieg vereinfacht und die drei wichtigsten Aktionen sichtbar gemacht.\n\nJetzt interessiert mich, ob sich der Ablauf im Alltag bewährt.\n\nBis bald\nMara", unread: false, flagged: false, attachment: "Skizze-v02.png"),
            .init(account: 1, sender: "Lesekreis Beispiel", email: "lesekreis", subject: "Eine Geschichte fürs Wochenende",
                  preview: "Unser nächstes Buch liegt bereit.", body: "Hallo zusammen\n\nFür das nächste Treffen haben wir eine kurze Geschichte ausgewählt. Es geht um eine kleine Werkstatt und eine grosse Idee.\n\nBis zum nächsten Mal!", unread: false, flagged: false, attachment: nil),
            .init(account: 0, sender: "Sam Beispiel", email: "sam", subject: "Die Details machen den Unterschied",
                  preview: "Noch zwei Gedanken zur Lesbarkeit und zu den Abständen.", body: "Hoi Mike\n\nMehr Freiraum tut dem Entwurf gut. Die schmalen Trennlinien reichen aus, um die Bereiche zu ordnen.\n\nIch würde den Kupferton gezielt für die wichtigen Stellen behalten.\n\nGruss\nSam", unread: false, flagged: false, attachment: nil),
            .init(account: 2, sender: "Jonas Beispiel", email: "jonas", subject: "Termin für die nächste Testrunde",
                  preview: "Ein Vorschlag für den gemeinsamen Prototypentest.", body: "Hoi Mike\n\nAm Freitag könnten wir die nächste Runde testen. Geplant sind Navigation, Tastaturbedienung und die leeren Zustände.\n\nViele Grüsse\nJonas", unread: true, flagged: false, attachment: nil),
            .init(account: 0, sender: "Werkstatt Demo", email: "werkstatt", subject: "Danke für die Materialmuster",
                  preview: "Die Muster sind angekommen. Wir schauen sie uns an.", body: "Hoi Lena\n\nDanke für die Muster. Wir vergleichen die Varianten beim nächsten Treffen.\n\nLiebe Grüsse\nMike", unread: false, flagged: false, attachment: nil, role: .sent),
            .init(account: 1, sender: "Archiv Demo", email: "archiv", subject: "Notizen vom letzten Ausflug",
                  preview: "Ein paar schöne Orte für ein anderes Mal.", body: "Ein synthetischer Archiveintrag. Der Inhalt stammt ausschliesslich aus dem mitgelieferten Demodatensatz.", unread: false, flagged: false, attachment: nil, role: .archive)
        ]
        let epoch = Date(timeIntervalSince1970: 1793610000) // Fixed fixture timestamp, never 'now'.
        var messages: [MailMessage] = []; var threads: [MailThread] = []; var contents: [MessageID:String] = [:]
        for (index, sample) in samples.enumerated() {
            let account = accounts[sample.account]; let id = try mid(index + 1); let threadID = try tid(index == 8 ? 1 : index + 1)
            let folder = folders.first { $0.accountID == account.id && $0.role == sample.role }!
            let locator: ProviderLocator
            switch account.provider {
            case .imap: locator = .imap(mailbox: folder.providerID, uidValidity: 1, uid: UInt32(index + 1))
            case .gmail: locator = .gmail(id: "demo-\(index + 1)")
            case .microsoft: locator = .graph(immutableID: "demo-\(index + 1)")
            }
            let attachments = try sample.attachment.map { filename in
                [try AttachmentMetadata(id: AttachmentID(string: String(format: "50000000-0000-4000-8000-%012d", index + 1)),
                                        messageID: id, accountID: account.id, filename: filename,
                                        mimeType: filename.hasSuffix("png") ? "image/png" : "application/pdf", byteCount: 284_000)]
            } ?? []
            if !threads.contains(where: { $0.id == threadID }) { threads.append(MailThread(id: threadID, accountID: account.id, subject: sample.subject)) }
            messages.append(try MailMessage(id: id, accountID: account.id, locator: locator, threadID: threadID,
                                           folderIDs: [folder.id], subject: sample.subject,
                                           sender: MailPerson(name: sample.sender, address: EmailAddress("\(sample.email)@example.com")),
                                           recipients: [MailPerson(name: "Mike · Demo", address: account.address)],
                                           receivedAt: epoch.addingTimeInterval(-Double(index) * 3900), isUnread: sample.unread,
                                           isFlagged: sample.flagged, preview: sample.preview, attachments: attachments))
            contents[id] = sample.body
        }
        return DemoDataset(snapshot: try MailSnapshot(accounts: accounts, folders: folders, threads: threads, messages: messages), contents: contents)
    }
}
