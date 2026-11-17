import Foundation
import Testing
import GRDB
import MailDomain
import MailApplication
import MailDemo
@testable import MailPersistence

struct SearchIndexFixture {
    let a = MailAccount(id: try! AccountID(), name: "Alpha Büro", address: try! EmailAddress("alpha@example.invalid"), provider: .imap, status: .connected)
    let b = MailAccount(id: try! AccountID(), name: "Beta", address: try! EmailAddress("beta@example.invalid"), provider: .imap, status: .connected)
    let zone = TimeZone(identifier: "Europe/Zurich")!
    var scope: AccessScope { AccessScope(accountIDs: [a.id, b.id]) }
    func snapshot() throws -> MailSnapshot {
        let inbox = try MailFolder(id: IMAPIdentity.folder(account: a.id, mailbox: "INBOX"), accountID: a.id, providerID: "INBOX", name: "Posteingang", role: .inbox)
        let archive = try MailFolder(id: IMAPIdentity.folder(account: a.id, mailbox: "Archive"), accountID: a.id, providerID: "Archive", name: "Archiv", role: .archive)
        let other = try MailFolder(id: IMAPIdentity.folder(account: b.id, mailbox: "INBOX"), accountID: b.id, providerID: "INBOX", name: "Posteingang", role: .inbox)
        let start = try MailSearchParser.day("2026-03-29", timeZone: zone)
        func mail(_ uid: UInt32, _ folder: MailFolder, _ subject: String, _ date: Date, attachment: Bool = false) throws -> MailMessage {
            let id = try IMAPIdentity.message(account: folder.accountID, mailbox: folder.providerID, validity: 1, uid: uid)
            return try MailMessage(id: id, accountID: folder.accountID, locator: .imap(mailbox: folder.providerID, uidValidity: 1, uid: uid),
                threadID: nil, folderIDs: [folder.id], subject: subject,
                sender: MailPerson(name: "Lena Müller", address: EmailAddress("lena@example.invalid")),
                recipients: [MailPerson(name: "Mara Käser", address: EmailAddress("mara@example.invalid"))],
                receivedAt: date, isUnread: uid % 2 == 1, isFlagged: uid == 2, preview: nil,
                attachments: attachment ? [AttachmentMetadata(id: IMAPIdentity.attachment(message: id, section: "2"),
                    messageID: id, accountID: folder.accountID, filename: "Rechnung Zürich.pdf", mimeType: "application/pdf", byteCount: 42)] : [])
        }
        return try MailSnapshot(accounts: [a, b], folders: [inbox, archive, other], threads: [], messages: [
            mail(1, inbox, "Rechnung rote Mappe", start, attachment: true),
            mail(2, inbox, "Rechnung Mappe rote", start.addingTimeInterval(23 * 3600 - 0.001)),
            mail(3, archive, "Plan ausserhalb", start.addingTimeInterval(23 * 3600), attachment: true),
            mail(4, inbox, "Vorheriger Tag", start.addingTimeInterval(-0.001)),
            mail(1, other, "Rechnung rote Mappe", start, attachment: true)
        ])
    }
}

struct SearchIndexTests {
    @Test func metadataOnlySearchCannotInferIndexedBodyAndCursorCannotChangePermission() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let h = SearchIndexFixture(), snapshot = try h.snapshot()
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key); try await repo.upsert(snapshot)
        var settings = try await repo.settings(for: h.a.id); settings.textIndexEnabled = true
        try await repo.saveSettings(settings)
        try await repo.storeExtract("BodyOnlySecretToken", for: snapshot.messages[0].id, account: h.a.id)
        var filter = MessageFilter(); filter.text = "BodyOnlySecretToken"
        #expect(try await repo.messages(filter: filter, page: PageRequest(), in: h.scope).items.count == 1)
        filter.includeIndexedText = false
        let hidden = try await repo.messages(filter: filter, page: PageRequest(), in: h.scope)
        #expect(hidden.items.isEmpty && hidden.coverage.indexedTextCount == 0 && hidden.coverage.truncatedTextCount == 0)
        filter.text = "from:muller subject:Rechnung"
        let first = try await repo.messages(filter: filter, page: PageRequest(limit: 1), in: h.scope)
        #expect(first.items.count == 1)
        let cursor = try #require(first.nextCursor)
        filter.includeIndexedText = true
        await #expect(throws: MailFailure.invalidInput) { try await repo.messages(filter: filter, page: PageRequest(limit: 1, cursor: cursor), in: h.scope) }
        filter.text = ""; filter.receivedAfter = snapshot.messages[2].receivedAt
        #expect(try await repo.messages(filter: filter, page: PageRequest(), in: h.scope).items.map(\.id) == [snapshot.messages[2].id])
        try await repo.close()
    }
    @Test func fieldFiltersAccountFolderDatesAndFalseFlagsStayScoped() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let h = SearchIndexFixture(), snapshot = try h.snapshot()
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key); try await repo.upsert(snapshot)
        func ids(_ input: String, scope: AccessScope? = nil) async throws -> [MessageID] {
            var filter = MessageFilter(); filter.text = input; filter.timeZoneID = h.zone.identifier
            return try await repo.messages(filter: filter, page: PageRequest(), in: scope ?? h.scope).items.map(\.id)
        }
        #expect(try await ids("from:muller to:kaser").count == 5)
        #expect(try await ids("from:rechnung").isEmpty)
        #expect(try await ids("filename:zurich has:attachment").count == 3)
        #expect(try await ids(#"subject:"rote Mappe""#).count == 2)
        #expect(try await ids("subject:Rech").count == 3)
        #expect(try await ids("account:alpha@example.invalid folder:INBOX after:2026-03-29 before:2026-03-30").count == 2)
        #expect(try await ids(#"account:"Alpha Büro" unread:false flagged:true"#) == [snapshot.messages[1].id])
        #expect(try await ids("has_attachment:false").count == 2)
        #expect(try await ids("account:beta@example.invalid", scope: AccessScope(accountIDs: [h.a.id])).isEmpty)
        #expect(try await ids("folder:Archive", scope: AccessScope(accountIDs: [h.a.id], folderIDs: [snapshot.folders[0].id])).isEmpty)
        #expect(try await ids(MailSearchParser.quote("\" OR * --")).isEmpty)
        try await repo.close()
    }
    @Test func coverageIsForFilteredCorpusEvenWhenNothingMatchesAndCursorsAreBound() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let h = SearchIndexFixture(), snapshot = try h.snapshot()
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key); try await repo.upsert(snapshot)
        var settings = try await repo.settings(for: h.a.id); settings.textIndexEnabled = true; settings.messageTextLimit = 20
        try await repo.saveSettings(settings)
        try await repo.storeExtract(String(repeating: "ä", count: 100), for: snapshot.messages[0].id, account: h.a.id, source: .sanitizedHTML)
        var filter = MessageFilter(); filter.text = "account:alpha@example.invalid keinTreffer"
        let empty = try await repo.messages(filter: filter, page: PageRequest(), in: h.scope)
        #expect(empty.items.isEmpty && !empty.coverage.isSynthetic)
        #expect(empty.coverage.eligibleMessageCount == 4 && empty.coverage.indexedTextCount == 1 && empty.coverage.truncatedTextCount == 1)
        #expect(empty.coverage.oldest != nil && empty.coverage.newest != nil)
        #expect(empty.coverage.folders.count == 2 && empty.coverage.folders.allSatisfy { $0.accountID == h.a.id && $0.lastSuccess == nil })
        filter.text = "Rechnung"
        let first = try await repo.messages(filter: filter, page: PageRequest(limit: 1), in: h.scope)
        let cursor = try #require(first.nextCursor)
        let second = try await repo.messages(filter: filter, page: PageRequest(limit: 1, cursor: cursor), in: h.scope)
        #expect(Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
        filter.timeZoneID = "Pacific/Auckland"
        await #expect(throws: MailFailure.invalidInput) { try await repo.messages(filter: filter, page: PageRequest(limit: 1, cursor: cursor), in: h.scope) }
        try await repo.close()
    }
    @Test func approvedExtractProvenanceSurvivesMetadataRefreshAndPurgesIndependently() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let h = SearchIndexFixture(), snapshot = try h.snapshot(), a = snapshot.messages[0], b = snapshot.messages[4]
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key); try await repo.upsert(snapshot)
        for account in [h.a, h.b] {
            var settings = try await repo.settings(for: account.id); settings.textIndexEnabled = true
            settings.messageTextLimit = 40; settings.accountTextBudget = 50
            try await repo.saveSettings(settings)
        }
        try await repo.storeExtract("Suchbeleg " + String(repeating: "🦊", count: 20), for: a.id, account: a.accountID, source: .sanitizedHTML)
        try await repo.storeExtract("Suchbeleg Beta", for: b.id, account: b.accountID)
        let before = try #require(try await repo.storedExtract(for: a.id, account: a.accountID))
        #expect(before.truncated && before.source == .sanitizedHTML && before.version == 2 && !before.text.contains("\u{FFFD}"))
        try await repo.upsert(snapshot)
        let after = try #require(try await repo.storedExtract(for: a.id, account: a.accountID))
        #expect(after.text == before.text && after.originalByteCount == before.originalByteCount && after.indexedAt == before.indexedAt)
        await #expect(throws: LocalStoreFailure.budgetExceeded) {
            try await repo.storeExtract("Ein zusätzlicher Text ist zu gross", for: snapshot.messages[1].id, account: h.a.id)
        }
        try await repo.clearExtracts(account: h.a.id)
        #expect(try await repo.settings(for: h.a.id).textIndexEnabled)
        var filter = MessageFilter(); filter.text = "Suchbeleg"
        #expect(try await repo.messages(filter: filter, page: PageRequest(), in: h.scope).items.map(\.id) == [b.id])
        #expect(try await repo.summary().messageCount == 5)
        try await repo.close()
        let reopened = try EncryptedMailRepository(paths: test.paths, key: test.key)
        #expect(try await reopened.storedExtract(for: a.id, account: a.accountID) == nil)
        #expect(try await reopened.storedExtract(for: b.id, account: b.accountID)?.text == "Suchbeleg Beta")
        try await reopened.close()
    }
    @Test func phaseFourMigrationRetainsLegacyTextAndItsFTSMatches() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }; try test.paths.prepare()
        let h = SearchIndexFixture(), snapshot = try h.snapshot(), message = snapshot.messages[0]
        let old = try DatabaseQueue(path: test.paths.database.path, configuration: IndexDatabase.configuration(key: test.key))
        try IndexSchema.migrator().migrate(old, upTo: "v4")
        try await old.write { db in
            try IndexWriter.upsert(snapshot, db: db)
            try db.execute(sql: "UPDATE account_settings SET text_index_enabled=1 WHERE account_id=?", arguments: [message.accountID.description])
            try db.execute(sql: "INSERT INTO message_text VALUES(?,?,?,'plainTextOnOpen',1,100,8,8,0)",
                arguments: [message.id.description, message.accountID.description, "Altbeleg"])
            try IndexRecords.refreshSearch(db, message: message.id.description)
        }
        try old.close()
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        let extract = try #require(try await repo.storedExtract(for: message.id, account: message.accountID))
        #expect(extract.text == "Altbeleg" && extract.source == .legacyUnknown)
        var filter = MessageFilter(); filter.text = "Altbeleg"
        #expect(try await repo.messages(filter: filter, page: PageRequest(), in: h.scope).items.map(\.id) == [message.id])
        #expect(try await repo.summary().schemaVersion == 14)
        try await repo.close()
    }
}
