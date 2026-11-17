import Testing
@testable import MailIMAP
import Foundation
import SwiftMail
import MailDomain
import MailApplication
import MailPersistence
import MailRendering

private actor TestCredentials: CredentialStore {
    var values: [CredentialReference: Data] = [:]
    func read(_ reference: CredentialReference) -> Data? { values[reference] }
    func save(_ secret: Data, for reference: CredentialReference) { values[reference] = secret }
    func delete(_ reference: CredentialReference) { values.removeValue(forKey: reference) }
}

private final class LoopbackFixture {
    let root: URL
    let process: Process
    let port: Int
    private let exited: DispatchSemaphore
    init(mode: String = "tls") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MikeMailIMAPFixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(#"{"uids":[11,12],"validity":7}"#.utf8).write(to: root.appendingPathComponent("state.json"), options: .atomic)
        process = Process()
        let finished = DispatchSemaphore(value: 0)
        exited = finished
        process.terminationHandler = { _ in finished.signal() }
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", Bundle.module.url(forResource: "imap_fixture", withExtension: "py", subdirectory: "Fixtures")!.path, root.path, mode]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        var bytes = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte[0] != 10 { bytes.append(byte) }
        guard let value = Int(String(decoding: bytes, as: UTF8.self)), value > 0 else { throw IMAPFailure.connection }
        port = value
    }
    func set(_ values: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: values).write(to: root.appendingPathComponent("state.json"), options: .atomic)
    }
    var commands: String { (try? String(contentsOf: root.appendingPathComponent("commands.txt"), encoding: .utf8)) ?? "" }
    func close() {
        if process.isRunning {
            process.terminate()
            // Foundation's waitUntilExit can lose its run-loop wakeup on a cooperative test thread.
            #expect(exited.wait(timeout: .now() + 3) == .success, "Synthetic IMAP peer did not terminate")
        }
        try? FileManager.default.removeItem(at: root)
    }
}

private struct Harness {
    let account: MailAccount
    let config: IMAPConfiguration
    let repo: EncryptedMailRepository
    let keys = TestCredentials()
    let path: URL
    let dbKey = Data(repeating: 0x37, count: 32)
    init(port: Int, security: IMAPSecurity = .implicitTLS) throws {
        account = MailAccount(id: try AccountID(), name: "Synthetic IMAP", address: try MailDomain.EmailAddress("reader@example.invalid"),
                              provider: .imap, status: .connected)
        config = try IMAPConfiguration(accountID: account.id, host: "localhost", port: port, security: security, username: "reader@example.invalid")
        path = FileManager.default.temporaryDirectory.appendingPathComponent("MikeMailIMAPIndex-\(UUID())")
        repo = try EncryptedMailRepository(paths: WorkspacePaths(root: path, cache: path.appendingPathComponent("Cache")), key: dbKey)
    }
    var scope: AccessScope { AccessScope(accountIDs: [account.id]) }
    func service(verifiedTLS: Bool = false) -> IMAPService {
        IMAPService(index: repo, credentials: keys) { config, password in
            if verifiedTLS { return SwiftMailTransport(configuration: config, password: password) }
            // Only the synthetic loopback peer gets a self-signed fixture certificate.
            // The exported production initializer always enforces full verification.
            precondition(config.host == "localhost")
            let peer = IMAPServer(host: config.host, port: config.port,
                transportSecurity: config.security == .implicitTLS ? .implicitTLS : .startTLS,
                certificateVerificationPolicy: .noVerification, minimumTLSVersion: .tlsv12,
                responseBufferLimit: 1024 * 1024,
                parserLimits: IMAPParserLimits(bodySizeLimit: 512 * 1024, messageAttributeLimit: 64, literalSizeLimit: 8192))
            return SwiftMailTransport(configuration: config, password: password, fixtureServer: peer)
        }
    }
    func inbox() async throws -> MailFolder {
        try #require(try await repo.folders(in: scope).first { $0.providerID == "INBOX" })
    }
    func messages() async throws -> [MailMessage] {
        try await repo.messages(filter: MessageFilter(), page: PageRequest(limit: 100), in: scope).items
    }
    func close() async throws { try await repo.close(); try? FileManager.default.removeItem(at: path) }
}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct IMAPSyncTests {
    @Test func onlineSearchPagesShareLocalIdentityWithoutChangingIndexOrFlags() async throws {
        let peer = try LoopbackFixture(); defer { peer.close() }
        try peer.set(["uids": Array(1...300), "validity": 7])
        let h = try Harness(port: peer.port), service = h.service()
        try await service.connectAccount(h.account, configuration: h.config, password: "synthetic")
        let folder = try await h.inbox()
        _ = try await service.sync(account: h.account, folder: folder)
        let original = try await h.repo.summary()
        var filter = MessageFilter()
        filter.text = "subject:Fixture from:sender to:reader after:2026-11-03 before:2026-11-04 unread:true"
        filter.timeZoneID = "Europe/Zurich"
        let first = try await service.search(account: h.account, folder: folder, filter: filter, page: PageRequest(limit: 3), scope: h.scope)
        #expect(first.items.count == 3 && first.items.allSatisfy(\.isUnread))
        let cursor = try #require(first.nextCursor)
        for message in first.items { #expect(try await h.repo.message(id: message.id, in: h.scope).locator == message.locator) }
        try peer.set(["uids": Array(1...301), "validity": 7])
        let next = try await service.search(account: h.account, folder: folder, filter: filter, page: PageRequest(limit: 3, cursor: cursor), scope: h.scope)
        #expect(next.items.count == 3 && Set(first.items.map(\.id)).isDisjoint(with: next.items.map(\.id)))
        #expect(!next.items.contains { $0.locator == .imap(mailbox: "INBOX", uidValidity: 7, uid: 301) })
        #expect(try await h.repo.summary().messageCount == original.messageCount)
        #expect(try await h.repo.summary().indexedTextCount == 0)
        #expect(peer.commands.contains("UID SEARCH") && peer.commands.contains("FROM") && peer.commands.contains("SUBJECT"))
        #expect(peer.commands.contains("OR") && peer.commands.contains("SINCE") && peer.commands.contains("BEFORE"))
        #expect(!peer.commands.contains("STORE") && !peer.commands.contains("MOVE") && !peer.commands.contains("BODY.PEEK[1]"))
        filter.text = "is:read"
        await #expect(throws: SearchFailure.invalidCursor) {
            try await service.search(account: h.account, folder: folder, filter: filter, page: PageRequest(limit: 3, cursor: cursor), scope: h.scope)
        }
        await #expect(throws: MailFailure.permissionDenied) {
            try await service.search(account: h.account, folder: folder, filter: MessageFilter(), page: PageRequest(), scope: AccessScope(accountIDs: [h.account.id], folderIDs: []))
        }
        try await h.close()
    }
    @Test func onlineUIDWindowsContinueAcrossEmptyPagesAndRejectOversizedSets() async throws {
        let peer = try LoopbackFixture(); defer { peer.close() }
        try peer.set(["uids": [1,9000,9999], "validity": 7, "esearch": true])
        let h = try Harness(port: peer.port), service = h.service()
        try await service.connectAccount(h.account, configuration: h.config, password: "synthetic")
        let folder = try await h.inbox(), query = MessageFilter()
        let first = try await service.search(account: h.account, folder: folder, filter: query, page: PageRequest(), scope: h.scope)
        #expect(first.items.count == 2)
        let second = try await service.search(account: h.account, folder: folder, filter: query, page: PageRequest(cursor: first.nextCursor), scope: h.scope)
        #expect(second.items.isEmpty && second.nextCursor != nil)
        let third = try await service.search(account: h.account, folder: folder, filter: query, page: PageRequest(cursor: second.nextCursor), scope: h.scope)
        #expect(third.items.count == 1 && third.nextCursor == nil)
        #expect(try await h.repo.summary().messageCount == 0)
        try peer.set(["uids": [1,9000,9999], "validity": 7, "esearch": true, "search_bad_range": true])
        await #expect(throws: IMAPFailure.invalidResponse) {
            try await service.search(account: h.account, folder: folder, filter: query, page: PageRequest(), scope: h.scope)
        }
        var unsupported = MessageFilter(); unsupported.text = "has:attachment"
        let count = peer.commands.count
        await #expect(throws: SearchFailure.onlineFilterUnsupported) {
            try await service.search(account: h.account, folder: folder, filter: unsupported, page: PageRequest(), scope: h.scope)
        }
        #expect(peer.commands.count == count)
        try await h.close()
    }
    @Test func onlineSearchUTF8ExactDatesValidityAndCancellation() async throws {
        let peer = try LoopbackFixture(); defer { peer.close() }
        let h = try Harness(port: peer.port), service = h.service()
        try await service.connectAccount(h.account, configuration: h.config, password: "synthetic")
        let folder = try await h.inbox()
        var query = MessageFilter(); query.text = #"subject:"Grüsse Zürich" after:2026-11-04"#
        query.timeZoneID = "Europe/Zurich"
        let result = try await service.search(account: h.account, folder: folder, filter: query, page: PageRequest(), scope: h.scope)
        #expect(result.items.isEmpty) // Fixture's date is Nov 3; exact client-side date bounds apply.
        #expect(peer.commands.contains("CHARSET UTF-8") && peer.commands.contains("Grüsse Zürich"))
        try peer.set(["uids": [11,12], "validity": 7, "search_change_validity": true])
        await #expect(throws: IMAPFailure.mailboxChanged) {
            try await service.search(account: h.account, folder: folder, filter: MessageFilter(), page: PageRequest(), scope: h.scope)
        }
        try peer.set(["uids": [11,12], "validity": 7, "search_stall": true])
        let task = Task { try await service.search(account: h.account, folder: folder, filter: MessageFilter(), page: PageRequest(), scope: h.scope) }
        try await Task.sleep(for: .milliseconds(150)); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await h.repo.summary().messageCount == 0)
        try await h.close()
    }
    @Test func failedAuthenticationAndDuplicateProfileDoNotPersistSecrets() async throws {
        let peer = try LoopbackFixture(); defer { peer.close() }
        let h = try Harness(port: peer.port), service = h.service()
        let reference = CredentialReference(accountID: h.account.id, purpose: .incomingPassword)
        try peer.set(["auth_fail": true])
        await #expect(throws: IMAPFailure.authentication) { try await service.connectAccount(h.account, configuration: h.config, password: "synthetic") }
        #expect(try await h.repo.imapConfigurations().isEmpty)
        #expect(await h.keys.read(reference) == nil)
        try peer.set(["uids": [11,12], "validity": 7])
        try await service.connectAccount(h.account, configuration: h.config, password: "original-synthetic")
        let duplicate = MailAccount(id: try AccountID(), name: "Duplicate", address: h.account.address, provider: .imap, status: .connected)
        let config = try IMAPConfiguration(accountID: duplicate.id, host: h.config.host, port: h.config.port, security: h.config.security, username: h.config.username)
        await #expect(throws: (any Error).self) { try await service.connectAccount(duplicate, configuration: config, password: "duplicate-synthetic") }
        #expect(try await h.repo.imapConfigurations().count == 1)
        #expect(await h.keys.read(CredentialReference(accountID: duplicate.id, purpose: .incomingPassword)) == nil)
        try peer.set(["auth_fail": true])
        await #expect(throws: IMAPFailure.authentication) { try await service.updatePassword(account: h.account.id, password: "wrong-synthetic") }
        #expect(await h.keys.read(reference) == Data("original-synthetic".utf8))
        try await h.close()
    }
    @Test func loopbackTLSIncrementalSyncPEEKOfflineReconnectAndValidityReset() async throws {
        let peer = try LoopbackFixture(); defer { peer.close() }
        let h = try Harness(port: peer.port), service = h.service()
        let secret = "synthetic-password-never-log"
        try await service.connectAccount(h.account, configuration: h.config, password: secret)
        let folder = try await h.inbox()
        #expect(try await h.repo.folders(in: h.scope).contains { $0.role == .sent })
        #expect(try await h.repo.folders(in: h.scope).contains { $0.name == "Entwürfe" && $0.providerID == "Entw&APw-rfe" })
        #expect(try await h.repo.summary().messageCount == 0)
        #expect(!peer.commands.contains("BODY"))
        _ = try await service.sync(account: h.account, folder: folder)
        let first = try await h.messages()
        #expect(first.count == 2)
        #expect(first.allSatisfy { $0.isUnread && $0.attachments.count == 1 && $0.threadID != nil && $0.preview == nil })
        #expect(first.allSatisfy { $0.attachments[0].providerPartID == "2" })
        #expect(try await h.repo.summary().indexedTextCount == 0)
        #expect(try await h.repo.messages(filter: MessageFilter(), page: PageRequest(), in: h.scope).coverage.isSynthetic == false)
        let metadataBefore = peer.commands.components(separatedBy: "\n").filter { $0.contains("ENVELOPE") }.count
        _ = try await service.sync(account: h.account, folder: folder)
        #expect(peer.commands.components(separatedBy: "\n").filter { $0.contains("ENVELOPE") }.count == metadataBefore)
        #expect(Set(try await h.messages().map(\.id)) == Set(first.map(\.id)))
        let message = try #require(first.first)
        let text = try await service.plainText(for: message, scope: h.scope)
        #expect(text.hasPrefix("Synthetic message body"))
        #expect(peer.commands.contains("BODY.PEEK[1]<0.65536>"))
        #expect(try await h.repo.summary().indexedTextCount == 0)
        var settings = try await h.repo.settings(for: h.account.id)
        settings.textIndexEnabled = true
        try await h.repo.saveSettings(settings)
        try await h.repo.storeExtract(text, for: message.id, account: h.account.id)
        // Flags change on the fixture side; the app merely observes them.
        try peer.set(["uids": [11,12,13], "validity": 7, "seen": [11]])
        _ = try await service.sync(account: h.account, folder: folder)
        let changed = try await h.messages()
        #expect(changed.count == 3)
        #expect(changed.contains { $0.locator == .imap(mailbox: "INBOX", uidValidity: 7, uid: 11) && !$0.isUnread })
        #expect(try await h.repo.extractedText(for: message.id, account: h.account.id) == text)
        let beforeFailure = Set(changed.map(\.id))
        try peer.set(["uids": [11,12,13], "validity": 7, "disconnect": true])
        await #expect(throws: (any Error).self) { _ = try await service.sync(account: h.account, folder: folder) }
        #expect(Set(try await h.messages().map(\.id)) == beforeFailure)
        #expect(try await h.repo.accounts(in: h.scope).first?.status == .offline)
        try peer.set(["uids": [11,13], "validity": 8])
        _ = try await service.sync(account: h.account, folder: folder)
        let reset = try await h.messages()
        #expect(reset.count == 2 && Set(reset.map(\.id)).isDisjoint(with: beforeFailure))
        #expect(try await h.repo.summary().indexedTextCount == 0)
        #expect(try await h.repo.imapCheckpoint(account: h.account.id, folder: folder.id)?.uidValidity == 8)
        await #expect(throws: IMAPFailure.mailboxChanged) { _ = try await service.plainText(for: message, scope: h.scope) }
        #expect(!peer.commands.contains(secret))
        for forbidden in ["SELECT ", "STORE ", "EXPUNGE", "CLOSE", "APPEND", "FORBIDDEN", "BODY[]", "BODY[1]"] {
            #expect(!peer.commands.contains(forbidden))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: h.path.path)
        #expect(!files.contains { $0.hasSuffix(".eml") || $0.hasSuffix(".pdf") })
        let configs = try await h.repo.imapConfigurations()
        #expect(configs == [h.config])
        try await h.close()
    }

    @Test func entireMailboxBeyond200AndDeletedUIDReconciliation() async throws {
        let peer = try LoopbackFixture(); defer { peer.close() }
        try peer.set(["uids": Array(1...240), "validity": 99])
        let h = try Harness(port: peer.port), service = h.service()
        try await service.connectAccount(h.account, configuration: h.config, password: "synthetic")
        let folder = try await h.inbox()
        let summary = try await service.sync(account: h.account, folder: folder)
        #expect(summary.indexedCount == 240 && summary.totalOnServer == 240)
        #expect(try await h.repo.summary().messageCount == 240)
        #expect(try await h.repo.imapCheckpoint(account: h.account.id, folder: folder.id)?.knownUIDs == Set(1...240).map(UInt32.init).reduce(into: Set<UInt32>()) { $0.insert($1) })
        try peer.set(["uids": Array(1...239), "validity": 99])
        _ = try await service.sync(account: h.account, folder: folder)
        let checkpoint = try #require(try await h.repo.imapCheckpoint(account: h.account.id, folder: folder.id))
        #expect(checkpoint.knownUIDs.contains(40) && !checkpoint.knownUIDs.contains(240))
        #expect(try await h.repo.summary().messageCount == 239)
        #expect(peer.commands.contains("UID SEARCH"))
        try await h.close()
    }

    @Test func rejectsUntrustedTLSAndMissingSTARTTLSBeforeSendingCredentials() async throws {
        for mode in ["tls", "missing-starttls"] {
            let peer = try LoopbackFixture(mode: mode)
            let h = try Harness(port: peer.port, security: mode == "tls" ? .implicitTLS : .startTLS)
            await #expect(throws: (any Error).self) {
                try await h.service(verifiedTLS: true).connectAccount(h.account, configuration: h.config, password: "synthetic")
            }
            #expect(!peer.commands.contains("LOGIN"))
            #expect(try await h.repo.imapConfigurations().isEmpty)
            #expect(await h.keys.read(CredentialReference(accountID: h.account.id, purpose: .incomingPassword)) == nil)
            try await h.close(); peer.close()
        }
    }

    @Test func rejectsWrongPartialOriginAndOversizedResponse() async throws {
        let peer = try LoopbackFixture(); defer { peer.close() }
        let h = try Harness(port: peer.port), service = h.service()
        try await service.connectAccount(h.account, configuration: h.config, password: "synthetic")
        _ = try await service.sync(account: h.account, folder: h.inbox())
        let message = try #require(try await h.messages().first)
        for mode in ["wrong_origin", "oversized"] {
            try peer.set(["uids": [11,12], "validity": 7, mode: true])
            await #expect(throws: (any Error).self) { _ = try await service.plainText(for: message, scope: h.scope) }
        }
        #expect(try await h.repo.summary().indexedTextCount == 0)
        try await h.close()
    }

    @Test func cancellationDoesNotAdvanceCheckpointOrLeavePartialMessages() async throws {
        let peer = try LoopbackFixture(); defer { peer.close() }
        let h = try Harness(port: peer.port), service = h.service()
        try await service.connectAccount(h.account, configuration: h.config, password: "synthetic")
        let folder = try await h.inbox()
        try peer.set(["uids": [11,12], "validity": 7, "stall": true])
        let task = Task { try await service.sync(account: h.account, folder: folder) }
        try await Task.sleep(for: .milliseconds(250))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await h.repo.imapCheckpoint(account: h.account.id, folder: folder.id) == nil)
        #expect(try await h.repo.summary().messageCount == 0)
        try peer.set(["uids": [11,12], "validity": 7])
        _ = try await service.sync(account: h.account, folder: folder)
        #expect(try await h.repo.summary().messageCount == 2)
        try await h.close()
    }

    @Test func inputAndAccountIsolation() async throws {
        let a = try AccountID(), b = try AccountID()
        for host in ["https://mail.example.com", "mail.example.com/path", "a..b", "-a.example", "evil\nhost", "mail.example:993"] {
            #expect(throws: MailFailure.invalidInput) { try IMAPConfiguration(accountID: a, host: host, port: 993, security: .implicitTLS, username: "reader") }
        }
        #expect(throws: MailFailure.invalidInput) { try IMAPConfiguration(accountID: a, host: "mail.example", port: 0, security: .startTLS, username: "reader") }
        #expect(try IMAPIdentity.message(account: a, mailbox: "INBOX", validity: 1, uid: 1) != IMAPIdentity.message(account: b, mailbox: "INBOX", validity: 1, uid: 1))
        #expect(try IMAPIdentity.message(account: a, mailbox: "INBOX", validity: 1, uid: 1) != IMAPIdentity.message(account: a, mailbox: "Sent", validity: 1, uid: 1))
        let peer = try LoopbackFixture(); defer { peer.close() }
        let h = try Harness(port: peer.port), service = h.service()
        try await service.connectAccount(h.account, configuration: h.config, password: "synthetic")
        let folder = try await h.inbox()
        _ = try await service.sync(account: h.account, folder: folder)
        let message = try #require(try await h.messages().first)
        let before = peer.commands
        await #expect(throws: MailFailure.permissionDenied) { _ = try await service.plainText(for: message, scope: AccessScope(accountIDs: [b])) }
        #expect(peer.commands == before)
        let broken = try IMAPFolderBatch(uidValidity: 77, totalOnServer: 1, flags: [IMAPFlags(uid: 1, unread: true, flagged: false)], newMessages: [])
        await #expect(throws: IMAPFailure.invalidResponse) { try await h.repo.applyIMAPBatch(broken, account: h.account, folder: folder) }
        #expect(try await h.repo.imapCheckpoint(account: h.account.id, folder: folder.id)?.uidValidity == 7)
        #expect(try await h.repo.summary().messageCount == 2)
        try await h.close()
    }
}

extension IMAPSyncTests {
    private func connected(_ peer: LoopbackFixture) async throws -> (Harness, IMAPService, MailFolder) {
        let h = try Harness(port: peer.port), service = h.service()
        try await service.connectAccount(h.account, configuration: h.config, password: "synthetic")
        var settings = try await h.repo.settings(for: h.account.id)
        settings.serverActionsEnabled = true
        try await h.repo.saveSettings(settings)
        let folder = try await h.inbox()
        _ = try await service.sync(account: h.account, folder: folder)
        return (h, service, folder)
    }
    @Test func replyHeadersAndHTMLUseBoundedPEEK() async throws {
        let peer = try LoopbackFixture(); defer { peer.close() }
        try peer.set(["uids":[11,12],"validity":7,"html":true,"threads":["12":["reply":"11@example.invalid","refs":["11@example.invalid"]]]])
        let (h, service, _) = try await connected(peer)
        let messages = try await h.messages()
        #expect(Set(messages.compactMap(\.threadID)).count == 1)
        #expect(messages.first { $0.locator == .imap(mailbox: "INBOX", uidValidity: 7, uid: 12) }?.references == ["<11@example.invalid>"])
        let message = try #require(messages.first)
        let html = try await service.body(for: message, scope: h.scope, preferHTML: true)
        #expect(html.format == .html && html.text.contains("Fixture HTML"))
        #expect(try await service.plainText(for: message, scope: h.scope).contains("Synthetic message body"))
        #expect(peer.commands.contains("BODY.PEEK[2]<0.65536>"))
        #expect(peer.commands.uppercased().contains("BODY.PEEK[HEADER.FIELDS"))
        #expect(!peer.commands.contains("SELECT ") && !peer.commands.contains("STORE "))
        #expect(try await h.repo.summary().indexedTextCount == 0)
        try await h.close()
    }
    @Test func htmlLoadsOnlyReferencedInlineImagesAndLongBodiesUseSmallPEEKChunks() async throws {
        let peer = try LoopbackFixture(); defer { peer.close() }
        try peer.set(["uids":[11], "validity":7, "html_only":true, "inline":true, "large_html":true])
        let (h, service, _) = try await connected(peer)
        let message = try #require(try await h.messages().first)
        let body = try await service.body(for: message, scope: h.scope, preferHTML: true)
        #expect(body.format == .html && body.text.utf8.count > 256 * 1024)
        #expect(Set(body.inlineImages.keys) == ["logo@mail"])
        let safe = try MailHTMLSanitizer.sanitize(body.text, inlineImages: body.inlineImages)
        #expect(safe.unavailableImageCount == 0 && safe.remoteImageCount == 1)
        #expect(peer.commands.contains("BODY.PEEK[1]<65536.65536>"))
        #expect(peer.commands.contains("BODY.PEEK[2]<0."))
        #expect(!peer.commands.contains("BODY.PEEK[3]") && !peer.commands.contains("SELECT ") && !peer.commands.contains("STORE "))
        try await h.close()
    }
    @Test func htmlPreferenceFallsBackToPlainAndTextOnlyReadsDoNotFetchInlineImages() async throws {
        let peer = try LoopbackFixture(); defer { peer.close() }
        let (h, service, _) = try await connected(peer)
        let message = try #require(try await h.messages().first)
        let plain = try await service.body(for: message, scope: h.scope, preferHTML: true)
        #expect(plain.format == .plainText && plain.inlineImages.isEmpty)
        try peer.set(["uids":[11,12], "validity":7, "html_only":true, "inline":true])
        let body = try await service.body(for: message, scope: h.scope, preferHTML: false)
        #expect(body.format == .html && body.inlineImages.isEmpty)
        #expect(!peer.commands.contains("BODY.PEEK[2]"))
        try await h.close()
    }
    @Test func confirmedFlagChangesAndMoveReconcileOnlyTheSameAccount() async throws {
        let peer = try LoopbackFixture(); defer { peer.close() }
        try peer.set(["uids":[11,12],"validity":7,"writes":true,"keywords":["$Forwarded"]])
        let (h, service, folder) = try await connected(peer)
        let original = try #require(try await h.messages().first)
        try await service.perform(.read(true), message: original, account: h.account, scope: h.scope)
        #expect(try await h.repo.message(id: original.id, in: h.scope).isUnread == false)
        try await service.perform(.flagged(true), message: original, account: h.account, scope: h.scope)
        #expect(try await h.repo.message(id: original.id, in: h.scope).isFlagged)
        #expect(try await h.repo.pendingMailActions(account: h.account.id).isEmpty)
        let trash = try #require(try await h.repo.folders(in: h.scope).first { $0.role == .trash })
        try await service.perform(.move(trash), message: original, account: h.account, scope: h.scope)
        var filter = MessageFilter(); filter.folderID = trash.id
        let moved = try await h.repo.messages(filter: filter, page: PageRequest(), in: h.scope).items
        #expect(moved.count == 1 && moved[0].accountID == h.account.id && moved[0].isFlagged && !moved[0].isUnread)
        #expect(moved[0].id != original.id)
        #expect(try await h.repo.imapCheckpoint(account: h.account.id, folder: folder.id)?.knownUIDs.count == 1)
        #expect(try await h.repo.pendingMailActions(account: h.account.id).isEmpty)
        for forbidden in ["UID COPY", "EXPUNGE", "CLOSE", "APPEND", "\\Deleted", "FORBIDDEN"] { #expect(!peer.commands.contains(forbidden)) }
        try await h.close()
    }
    @Test func lostMoveReplyPersistsUncertaintyAndReconcilesWithoutReplay() async throws {
        let peer = try LoopbackFixture(); defer { peer.close() }
        try peer.set(["uids":[11],"validity":7,"writes":true,"drop_after_move":true])
        let (h, service, _) = try await connected(peer)
        let message = try #require(try await h.messages().first)
        let trash = try #require(try await h.repo.folders(in: h.scope).first { $0.role == .trash })
        await #expect(throws: (any Error).self) { try await service.perform(.move(trash), message: message, account: h.account, scope: h.scope) }
        #expect(try await h.repo.pendingMailActions(account: h.account.id).count == 1)
        await #expect(throws: IMAPFailure.reconciliationRequired) { try await service.perform(.read(true), message: message, account: h.account, scope: h.scope) }
        try await h.repo.close()
        let reopened = try EncryptedMailRepository(paths: WorkspacePaths(root: h.path, cache: h.path.appendingPathComponent("Cache")), key: h.dbKey)
        #expect(try await reopened.pendingMailActions(account: h.account.id).count == 1)
        try await reopened.close()
        // Recreate service against the reopened index using the same synthetic-only transport.
        let repo = try EncryptedMailRepository(paths: WorkspacePaths(root: h.path, cache: h.path.appendingPathComponent("Cache")), key: h.dbKey)
        let service2 = IMAPService(index: repo, credentials: h.keys) { config, password in
            let server = IMAPServer(host: config.host, port: config.port, transportSecurity: .implicitTLS, certificateVerificationPolicy: .noVerification, minimumTLSVersion: .tlsv12)
            return SwiftMailTransport(configuration: config, password: password, fixtureServer: server)
        }
        try await service2.reconcilePending(account: h.account)
        #expect(try await repo.pendingMailActions(account: h.account.id).isEmpty)
        let messages = try await repo.messages(filter: MessageFilter(), page: PageRequest(), in: h.scope).items
        #expect(messages.count == 1 && messages[0].folderIDs == [trash.id])
        #expect(peer.commands.components(separatedBy: "\n").filter { $0.hasPrefix("UID MOVE") }.count == 1)
        try await repo.close(); try? FileManager.default.removeItem(at: h.path)
    }
    @Test func writePermissionScopeValidityAndMoveCapabilityFailClosed() async throws {
        let peer = try LoopbackFixture(); defer { peer.close() }
        try peer.set(["uids":[11],"validity":7,"writes":true,"move":false])
        let (h, service, folder) = try await connected(peer)
        let message = try #require(try await h.messages().first)
        var settings = try await h.repo.settings(for: h.account.id); settings.serverActionsEnabled = false
        try await h.repo.saveSettings(settings)
        let before = peer.commands
        await #expect(throws: MailFailure.permissionDenied) { try await service.perform(.read(true), message: message, account: h.account, scope: h.scope) }
        #expect(peer.commands == before)
        settings.serverActionsEnabled = true; try await h.repo.saveSettings(settings)
        await #expect(throws: MailFailure.permissionDenied) { try await service.perform(.read(true), message: message, account: h.account, scope: AccessScope(accountIDs: [])) }
        let other = try MailFolder(id: FolderID(), accountID: AccountID(), providerID: "Trash", name: "Other", role: .trash)
        await #expect(throws: MailFailure.permissionDenied) { try await service.perform(.move(other), message: message, account: h.account, scope: h.scope) }
        let trash = try #require(try await h.repo.folders(in: h.scope).first { $0.role == .trash })
        await #expect(throws: IMAPFailure.unsupportedAction) { try await service.perform(.move(trash), message: message, account: h.account, scope: h.scope) }
        #expect(!peer.commands.contains("UID MOVE") && !peer.commands.contains("UID COPY"))
        try await service.reconcilePending(account: h.account)
        try peer.set(["uids":[11],"validity":8,"writes":true])
        await #expect(throws: IMAPFailure.mailboxChanged) { try await service.perform(.read(true), message: message, account: h.account, scope: h.scope) }
        #expect(!peer.commands.contains("UID STORE"))
        try await service.reconcilePending(account: h.account)
        #expect(try await h.repo.imapCheckpoint(account: h.account.id, folder: folder.id)?.uidValidity == 8)
        try await h.close()
    }
    @Test func unconfirmedStoreAndMoveNeverReportSuccess() async throws {
        for option in ["ignore_store", "move_nomap", "read_only"] {
            let peer = try LoopbackFixture(); defer { peer.close() }
            try peer.set(["uids":[11], "validity":7, "writes":true, option:true])
            let (h, service, _) = try await connected(peer)
            let original = try #require(try await h.messages().first)
            let trash = try #require(try await h.repo.folders(in: h.scope).first { $0.role == .trash })
            let mutation: MailMutation = option == "move_nomap" ? .move(trash) : .read(true)
            await #expect(throws: (any Error).self) { try await service.perform(mutation, message: original, account: h.account, scope: h.scope) }
            #expect(try await h.repo.message(id: original.id, in: h.scope).isUnread == original.isUnread)
            #expect(try await h.repo.pendingMailActions(account: h.account.id).count == 1)
            if option == "read_only" { #expect(!peer.commands.contains("UID STORE")) }
            try await service.reconcilePending(account: h.account)
            #expect(try await h.repo.pendingMailActions(account: h.account.id).isEmpty)
            #expect(!peer.commands.contains("EXPUNGE") && !peer.commands.contains("UID COPY"))
            try await h.close()
        }
    }
}

private actor AttachmentCapture {
    var bytes = Data()
    var sizes: [Int] = []
    func append(_ data: Data) { bytes.append(data); sizes.append(data.count) }
}
extension IMAPSyncTests {
    @Test func attachmentReadsInBoundedPEEKChunksWithoutSeenAndDetectsChanges() async throws {
        let peer = try LoopbackFixture(); defer { peer.close() }
        try peer.set(["uids": [11], "validity": 7, "attachment_bytes": 150_000])
        let h = try Harness(port: peer.port), service = h.service()
        try await service.connectAccount(h.account, configuration: h.config, password: "synthetic")
        _ = try await service.sync(account: h.account, folder: h.inbox())
        let message = try #require(try await h.messages().first), attachment = try #require(message.attachments.first)
        let request = try AttachmentRequest(message: message, attachment: attachment, scope: h.scope)
        let capture = AttachmentCapture()
        try await service.download(request, sink: { await capture.append($0) }, progress: { _, _ in })
        #expect(await capture.bytes == Data(repeating: 120, count: 150_000))
        #expect(await capture.sizes.allSatisfy { $0 <= 65_536 })
        #expect(peer.commands.contains("BODY.PEEK[2]<0.65536>"))
        #expect(peer.commands.contains("BODY.PEEK[2]<65536.65536>"))
        #expect(!peer.commands.contains("UID STORE") && !peer.commands.contains("FORBIDDEN"))
        #expect(try await h.messages().allSatisfy(\.isUnread))
        try peer.set(["uids": [11], "validity": 7, "attachment_bytes": 4])
        await #expect(throws: AttachmentFailure.changed) { try await service.download(request, sink: { _ in }, progress: { _, _ in }) }
        try await h.close()
    }
    @Test func truncatedAttachmentDoesNotPublishPartialFile() async throws {
        let peer = try LoopbackFixture(); defer { peer.close() }
        try peer.set(["uids": [11], "validity": 7, "attachment_bytes": 150_000, "attachment_drop": true])
        let h = try Harness(port: peer.port), service = h.service()
        try await service.connectAccount(h.account, configuration: h.config, password: "synthetic")
        _ = try await service.sync(account: h.account, folder: h.inbox())
        let message = try #require(try await h.messages().first), attachment = try #require(message.attachments.first)
        let capture = AttachmentCapture()
        await #expect(throws: (any Error).self) {
            try await service.download(AttachmentRequest(message: message, attachment: attachment, scope: h.scope),
                sink: { await capture.append($0) }, progress: { _, _ in })
        }
        #expect(await capture.bytes.isEmpty)
        try await h.close()
    }
}
