import Foundation
import Testing
import MailDomain
import MailApplication
import MailPersistence

struct SearchPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIKE_MAIL_SEARCH_PERF"] == "1"), .timeLimit(.minutes(10)))
    func hundredThousandSyntheticMessages() async throws {
        let test = TestWorkspace(); defer { test.cleanup() }
        let repo = try EncryptedMailRepository(paths: test.paths, key: test.key)
        let accounts = try (1...3).map { n in
            try MailAccount(id: AccountID(string: String(format: "a0000000-0000-4000-8000-%012d", n)), name: "Benchmark \(n)",
                address: EmailAddress("bench\(n)@example.invalid"), provider: .imap)
        }
        let folders = try accounts.map { account in
            try MailFolder(id: IMAPIdentity.folder(account: account.id, mailbox: "INBOX"), accountID: account.id,
                providerID: "INBOX", name: "Posteingang", role: .inbox)
        }
        let startDate = try MailSearchParser.day("2026-11-04", timeZone: TimeZone(secondsFromGMT: 0)!)
        let sender = try MailPerson(name: "Lena Müller", address: EmailAddress("lena@example.invalid"))
        let recipient = try MailPerson(name: "Mara Käser", address: EmailAddress("mara@example.invalid"))
        let scope = AccessScope(accountIDs: Set(accounts.map(\.id)))
        try await repo.upsert(MailSnapshot(accounts: accounts, folders: folders, threads: [], messages: []))
        for account in accounts {
            var settings = try await repo.settings(for: account.id); settings.textIndexEnabled = true
            try await repo.saveSettings(settings)
        }
        let loadStart = DispatchTime.now().uptimeNanoseconds
        for batchStart in stride(from: 0, to: 100_000, by: 1000) {
            var messages: [MailMessage] = []
            for index in batchStart..<batchStart + 1000 {
                let account = accounts[index % 3], folder = folders[index % 3]
                let id = try MessageID(string: String(format: "b0000000-0000-4000-8000-%012d", index + 1))
                let attachments = index % 5 == 0 ? [try AttachmentMetadata(
                    id: AttachmentID(string: String(format: "c0000000-0000-4000-8000-%012d", index + 1)),
                    messageID: id, accountID: account.id, filename: "Rechnung Zürich \(index).pdf", mimeType: "application/pdf", byteCount: 4096)] : []
                messages.append(try MailMessage(id: id, accountID: account.id,
                    locator: .imap(mailbox: "INBOX", uidValidity: 1, uid: UInt32(index + 1)), threadID: nil, folderIDs: [folder.id],
                    subject: index % 10 == 0 ? "Rechnung Zürich Projekt \(index % 100)" : "Materialplanung Projekt \(index % 100)",
                    sender: sender, recipients: [recipient], receivedAt: startDate.addingTimeInterval(-Double(index) * 60),
                    isUnread: index % 3 == 0, isFlagged: index % 7 == 0, preview: nil, attachments: attachments))
            }
            try await repo.upsert(MailSnapshot(accounts: accounts, folders: folders, threads: [], messages: messages))
            for offset in stride(from: 0, to: 1000, by: 100) {
                let message = messages[offset]
                try await repo.storeExtract("Textbeleg mit synthetischen Rückmeldungen zur Papierqualität.", for: message.id, account: message.accountID)
            }
        }
        let loadMS = Double(DispatchTime.now().uptimeNanoseconds - loadStart) / 1_000_000
        let summary = try await repo.summary()
        #expect(summary.messageCount == 100_000 && summary.indexedTextCount == 1000)
        var measurements: [[String: Any]] = []
        for text in ["Rechnung", "from:muller has:attachment", "filename:rechnung", "after:2026-10-01 before:2026-10-31", "Textbeleg", "unread:true flagged:true"] {
            var filter = MessageFilter(); filter.text = text; filter.timeZoneID = "Europe/Zurich"
            var timings: [Double] = []; var count = 0
            for _ in 0..<9 {
                let begin = DispatchTime.now().uptimeNanoseconds
                let result = try await repo.messages(filter: filter, page: PageRequest(limit: 20), in: scope)
                timings.append(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000)
                count = result.coverage.messageCount
                #expect(result.items.count == 20)
            }
            let sorted = timings.sorted()
            measurements.append(["synthetic_query": text, "matches": count, "first_ms": timings[0], "median_ms": sorted[4],
                                 "p95_ms": sorted[8], "samples_ms": timings, "median_under_300ms": sorted[4] < 300])
        }
        #if DEBUG
        let configuration = "Debug (-Onone)"
        #else
        let configuration = "Release (-O)"
        #endif
        let report: [String: Any] = ["generated_utc": ISO8601DateFormatter().string(from: Date()), "configuration": configuration,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "message_count": summary.messageCount,
            "text_count": summary.indexedTextCount, "attachment_count": 20_000, "account_count": 3,
            "database_and_journal_bytes": summary.databaseBytes, "extract_bytes": summary.extractBytes,
            "load_ms": loadMS, "method": "Real encrypted repository, 20-row first page including counts and coverage; 9 serial samples per query; no network; corpus built via normal upsert and text APIs. First sample is not a cold OS-cache measurement.",
            "queries": measurements]
        if let path = ProcessInfo.processInfo.environment["MIKE_MAIL_PERF_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print("Synthetic search benchmark: 100000 messages; medians ms: \(measurements.map { $0["median_ms"]! })")
        try await repo.close()
    }
}
