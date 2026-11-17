import Foundation
import Testing
import MailDomain
import MailApplication
import MailPersistence
import MailIMAP
@testable import MailGoogle

private let publicClient = "1234567890-synthetic.apps.googleusercontent.com"
private actor GmailAuthorization {
    private var checks = 0
    let revokeAt: Int
    init(_ revokeAt: Int) { self.revokeAt = revokeAt }
    func check() throws {
        checks += 1
        if checks >= revokeAt { throw MailFailure.permissionDenied }
    }
}
private actor Tokens: GoogleTokenSource {
    var refreshFlags: [Bool] = []
    func accessToken(for configuration: GmailConfiguration, forceRefresh: Bool) -> String {
        refreshFlags.append(forceRefresh); return "synthetic-test-token"
    }
}
private actor Transport: ProviderTransport {
    struct Reply: Sendable { let status: Int; let body: String }
    var replies: [Reply]
    var paths: [String] = []
    var methods: [String] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func data(for request: URLRequest, maximumBytes: Int) throws -> (Data, HTTPURLResponse) {
        paths.append(request.url!.absoluteString); methods.append(request.httpMethod ?? "GET")
        guard !replies.isEmpty else { throw MailFailure.offline }
        let next = replies.removeFirst()
        return (Data(next.body.utf8), HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}
private func wire(_ id: String = "a1", labels: [String] = ["INBOX", "Label_test", "UNREAD"], thread: String = "b1") throws -> GmailMessage {
    let value: [String: Any] = ["id": id, "threadId": thread, "labelIds": labels, "internalDate": "1793815200000",
        "payload": ["mimeType": "text/plain", "headers": [["name": "From", "value": "Tester <sender@example.invalid>"],
        ["name": "To", "value": "reader@example.invalid"], ["name": "Subject", "value": "=?UTF-8?B?R3LDvHNzZQ==?="],
        ["name": "Message-ID", "value": "<synthetic@example.invalid>"]], "body": ["size": 0]]]
    return try JSONDecoder().decode(GmailMessage.self, from: JSONSerialization.data(withJSONObject: value))
}
private func folders(_ account: AccountID) throws -> [MailFolder] {
    try ["INBOX", "Label_test", "SENT", "DRAFT", GmailIdentity.archive].map {
        try MailFolder(id: GmailIdentity.folder(account: account, label: $0), accountID: account, providerID: $0,
                       name: $0, role: $0 == "INBOX" ? .inbox : $0 == "SENT" ? .sent : .custom)
    }
}
private struct Workspace {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GmailTests-" + UUID().uuidString)
    var paths: WorkspacePaths { WorkspacePaths(root: root.appendingPathComponent("index"), cache: root.appendingPathComponent("cache")) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func repository() throws -> EncryptedMailRepository { try EncryptedMailRepository(paths: paths, key: Data(repeating: 0x9a, count: 32)) }
}
private actor FakeGmail: GmailAPI {
    nonisolated let accountID: AccountID
    var ids = ["a1"]
    var failMetadata = false
    var expired = false
    var fetches = 0
    var sends = 0
    var saves = 0
    var modifications = 0
    var profileReads = 0
    var ignoreWrites = false
    var messageLabels = ["INBOX", "Label_test", "UNREAD"]
    var sendError: ComposeFailure?
    var version = "v1"
    init(_ account: AccountID) { accountID = account }
    func configure(ids: [String]? = nil, fail: Bool = false, expired: Bool = false, sendError: ComposeFailure? = nil, version: String = "v1", ignoreWrites: Bool = false) {
        if let ids { self.ids = ids }; failMetadata = fail; self.expired = expired; self.sendError = sendError; self.version = version; self.ignoreWrites = ignoreWrites
    }
    func profile() -> GmailProfile { profileReads += 1; return GmailProfile(email: "reader@example.invalid", historyID: "42") }
    func folders() throws -> [MailFolder] { try MailGoogleTestsFolders.make(accountID) }
    func messageIDs(label: String, limit: Int, query: String?) -> [String] { query == nil ? ids : [] }
    func history(since: String) throws -> GmailHistory {
        if expired { throw GmailFailure.historyExpired }
        return GmailHistory(changedIDs: [], historyID: "43")
    }
    func metadata(id: String, folders: [MailFolder]) throws -> (MailMessage, String) {
        fetches += 1; if failMetadata { throw MailFailure.offline }
        return try GmailMapping.message(wire(id, labels: messageLabels), account: accountID, folders: folders)
    }
    func body(id: String, preferHTML: Bool, maximumBytes: Int) -> MailBody { MailBody(text: "synthetic", format: .plainText) }
    func modify(id: String, adding: [String], removing: [String]) {
        modifications += 1
        if !ignoreWrites { messageLabels = Array(Set(messageLabels).union(adding).subtracting(removing)) }
    }
    func send(raw: Data, draftID: String?) throws -> String { sends += 1; if let sendError { throw sendError }; return "c1" }
    func saveDraft(raw: Data, draftID: String?) -> GmailDraftReceipt { saves += 1; return GmailDraftReceipt(id: "r1", messageID: version) }
    func draftVersion(id: String) -> GmailDraftReceipt { GmailDraftReceipt(id: id, messageID: version) }
    func findDraft(internetMessageID: String) -> GmailDraftReceipt? { nil }
}
private enum MailGoogleTestsFolders { static func make(_ account: AccountID) throws -> [MailFolder] { try folders(account) } }

struct GmailTests {
    @Test func discardedDraftsStayInTrashAndOldIndexesAreRepairedWithoutRemovingMail() async throws {
        let workspace = Workspace(); defer { workspace.cleanup() }
        let repo = try workspace.repository(), account = try makeAccount()
        let labels = try [("INBOX", FolderRole.inbox), ("DRAFT", .drafts), ("TRASH", .trash)].map {
            try MailFolder(id: GmailIdentity.folder(account: account.id, label: $0.0), accountID: account.id,
                           providerID: $0.0, name: $0.0, role: $0.1)
        }
        let drafts = try #require(labels.first { $0.role == .drafts }), trash = try #require(labels.first { $0.role == .trash })
        let (active, activeThread) = try GmailMapping.message(wire("a1", labels: ["DRAFT"], thread: "b1"), account: account.id, folders: labels)
        let (discarded, discardedThread) = try GmailMapping.message(wire("a2", labels: ["DRAFT", "TRASH"], thread: "b2"), account: account.id, folders: labels)
        #expect(active.folderIDs == [drafts.id])
        #expect(discarded.folderIDs == [trash.id])
        // Reproduce the old on-disk representation, before GmailMapping was fixed.
        let old = try MailMessage(id: discarded.id, accountID: account.id, locator: discarded.locator,
            threadID: discarded.threadID, folderIDs: [drafts.id, trash.id], subject: discarded.subject,
            sender: discarded.sender, recipients: discarded.recipients, receivedAt: discarded.receivedAt,
            isUnread: false, isFlagged: false, preview: nil)
        try await repo.saveGmailAccount(account, configuration: configuration(account.id), folders: labels)
        try await repo.applyGmailBatch(GmailBatch(folders: labels, messages: [active, old],
            providerThreads: [active.threadID!: activeThread, old.threadID!: discardedThread],
            wantedIDs: ["a1", "a2"], labels: ["INBOX", "DRAFT", "TRASH"], historyID: "42"), account: account)
        try await repo.reconcileGmailFolders(labels, account: account)
        try await repo.reconcileGmailFolders(labels, account: account)
        let scope = AccessScope(accountIDs: [account.id])
        var query = MessageFilter(); query.role = .drafts
        #expect(try await repo.messages(filter: query, page: PageRequest(), in: scope).items.map(\.id) == [active.id])
        #expect(try await repo.message(id: old.id, in: scope).folderIDs == [trash.id])
        #expect(try await repo.summary().messageCount == 2)
        // Restoring at Gmail makes the draft visible again on the next metadata update.
        let (restored, thread) = try GmailMapping.message(wire("a2", labels: ["DRAFT"], thread: "b2"), account: account.id, folders: labels)
        try await repo.applyGmailChanges(account: account, folders: labels, messages: [restored], providerThreads: [restored.threadID!: thread], removedIDs: [], historyID: nil)
        #expect(try await repo.messages(filter: query, page: PageRequest(), in: scope).coverage.messageCount == 2)
        query.role = .trash
        #expect(try await repo.messages(filter: query, page: PageRequest(), in: scope).items.isEmpty)
        try await repo.close()
    }
    @Test(arguments: [1, 2, 3]) func gmailRevalidatesAuthorizationIncludingAfterDurableIntent(revokeAt: Int) async throws {
        let workspace = Workspace(); defer { workspace.cleanup() }
        let repo = try workspace.repository(), account = try makeAccount()
        try await repo.saveGmailAccount(account, configuration: configuration(account.id), folders: folders(account.id))
        var initial = LocalDraft(accountID: account.id, sender: account.address.value)
        initial.to = "recipient@example.invalid"; initial.body = "Synthetic explicit send test"
        let draft = try await repo.saveDraft(initial, expectedRevision: 0)
        let api = FakeGmail(account.id), authorization = GmailAuthorization(revokeAt)
        let service = GmailSubmission(repository: repo, index: repo) { _ in api }
        await #expect(throws: MailFailure.permissionDenied) {
            try await service.send(id: draft.id, account: account.id, expectedRevision: draft.revision, attachments: [], authorize: { try await authorization.check() })
        }
        #expect(await api.sends == 0)
        let saved = try await repo.draft(id: draft.id, account: account.id)
        #expect(saved.status == (revokeAt == 3 ? .failed : .editing))
        try await repo.close()
    }
    @Test func stableIdentityAndProviderThreadAreAccountScopedAndLabelsDoNotDuplicateMessages() async throws {
        let workspace = Workspace(); defer { workspace.cleanup() }
        let repo = try workspace.repository(), account = try makeAccount(), other = try makeAccount()
        let labels = try folders(account.id), config = try configuration(account.id)
        try await repo.saveGmailAccount(account, configuration: config, folders: labels)
        let (message, thread) = try GmailMapping.message(wire(), account: account.id, folders: labels)
        #expect(message.folderIDs.count == 2 && message.subject == "Grüsse" && message.isUnread)
        #expect(try GmailIdentity.message(account: account.id, id: "a1") != GmailIdentity.message(account: other.id, id: "a1"))
        #expect(try GmailIdentity.thread(account: account.id, id: thread) != GmailIdentity.thread(account: other.id, id: thread))
        let batch = try GmailBatch(folders: labels, messages: [message], providerThreads: [message.threadID!: thread], wantedIDs: ["a1"], labels: ["INBOX", "Label_test"], historyID: "42")
        try await repo.applyGmailBatch(batch, account: account)
        #expect(try await repo.summary().messageCount == 1)
        let checkpoint = try await repo.gmailCheckpoint(account: account.id)
        #expect(checkpoint.knownIDs == ["a1"] && checkpoint.historyID == "42")
        try await repo.close()
        let reopened = try workspace.repository()
        #expect(try await reopened.gmailConfigurations() == [config])
        let restored = try await reopened.message(id: message.id, in: AccessScope(accountIDs: [account.id]))
        #expect(restored.folderIDs == message.folderIDs && restored.threadID == message.threadID)
        try await reopened.close()
    }
    @Test func failedBatchCannotAdvanceCursorOrRemoveExistingMessages() async throws {
        let workspace = Workspace(); defer { workspace.cleanup() }
        let repo = try workspace.repository(), account = try makeAccount(), labels = try folders(account.id)
        try await repo.saveGmailAccount(account, configuration: configuration(account.id), folders: labels)
        let api = FakeGmail(account.id), service = GmailService(index: repo) { _ in api }
        try await service.synchronize(account: account)
        await api.configure(ids: ["a2"], fail: true)
        await #expect(throws: MailFailure.offline) { try await service.synchronize(account: account) }
        let checkpoint = try await repo.gmailCheckpoint(account: account.id)
        #expect(checkpoint.knownIDs == ["a1"] && checkpoint.historyID == "42")
        let invalid = try GmailBatch(folders: labels, messages: [], providerThreads: [:], wantedIDs: ["a2"], labels: ["INBOX"], historyID: "99")
        await #expect(throws: GmailFailure.invalidResponse) { try await repo.applyGmailBatch(invalid, account: account) }
        #expect(try await repo.gmailCheckpoint(account: account.id).historyID == "42")
        try await repo.close()
    }
    @Test func incrementalSyncReusesMetadataAndExpiredHistoryRefetchesOnlyBoundedCoverage() async throws {
        let workspace = Workspace(); defer { workspace.cleanup() }
        let repo = try workspace.repository(), account = try makeAccount()
        try await repo.saveGmailAccount(account, configuration: configuration(account.id), folders: folders(account.id))
        let api = FakeGmail(account.id), service = GmailService(index: repo) { _ in api }
        try await service.synchronize(account: account)
        try await service.synchronize(account: account, label: "Label_test")
        #expect(await api.fetches == 1)
        await api.configure(expired: true)
        try await service.synchronize(account: account)
        #expect(await api.fetches == 2)
        #expect(try await repo.summary().messageCount == 1)
        try await repo.close()
    }
    @Test func readOnlyCannotMutateAndCrossAccountBodiesAreDenied() async throws {
        let account = try makeAccount(), config = try configuration(account.id, .readOnly), transport = Transport([])
        let client = GmailClient(configuration: config, tokens: Tokens(), transport: transport)
        await #expect(throws: GmailFailure.insufficientScope) { try await client.modify(id: "a1", adding: ["STARRED"], removing: []) }
        #expect(await transport.paths.isEmpty)
        await #expect(throws: MailFailure.invalidInput) { try await client.body(id: "../evil", preferHTML: false, maximumBytes: 10) }
    }
    @Test func read401RefreshesOnceAndRedirectResponsesNeverFollow() async throws {
        let config = try configuration(AccountID()), tokens = Tokens()
        let transport = Transport([.init(status: 401, body: "{}"), .init(status: 500, body: "{}"), .init(status: 200, body: "{\"emailAddress\":\"reader@example.invalid\",\"historyId\":\"42\"}")])
        let client = GmailClient(configuration: config, tokens: tokens, transport: transport)
        #expect(try await client.profile().historyID == "42")
        #expect(await tokens.refreshFlags == [false, true, false])
        let redirect = Transport([.init(status: 302, body: "")])
        await #expect(throws: MailFailure.providerFailure) { try await GmailClient(configuration: config, tokens: tokens, transport: redirect).profile() }
        #expect(await redirect.paths.count == 1)
    }
    @Test func sendNeverRetries429OrServerErrorsOr401() async throws {
        let config = try configuration(AccountID())
        for status in [429, 500, 401] {
            let transport = Transport([.init(status: status, body: "{}"), .init(status: 200, body: "{\"id\":\"a1\"}")])
            let client = GmailClient(configuration: config, tokens: Tokens(), transport: transport)
            await #expect(throws: ComposeFailure.self) { try await client.send(raw: Data("synthetic".utf8), draftID: nil) }
            #expect(await transport.paths.count == 1)
        }
    }
    @Test func metadataRequestsExcludeBodiesAndBodiesAreBounded() async throws {
        #expect(!GmailClient.metadataFields.contains("data"))
        let part = try JSONDecoder().decode(GmailPart.self, from: Data(#"{"mimeType":"multipart/mixed","parts":[{"mimeType":"text/plain","filename":"private.txt","body":{"data":"YXR0YWNobWVudA"}},{"mimeType":"text/plain","body":{"data":"SGFsbG8"}}]}"#.utf8))
        let selected = try GmailMapping.bodyPart(part, preferHTML: false)
        #expect(selected.filename == nil)
        #expect(try GmailMapping.body(selected.body!.data!, mime: selected.mimeType, headers: [], maximumBytes: 5).text == "Hallo")
        #expect(throws: GmailFailure.self) { try GmailMapping.body("SGFsbG8", mime: "text/plain", headers: [], maximumBytes: 2) }
        #expect(throws: GmailFailure.invalidResponse) { try GmailMapping.body("!!!", mime: "text/plain", headers: [], maximumBytes: 10) }
    }
    @Test func htmlPreferenceAndReferencedInlineImagesUseOnlyTheSameGmailMessage() async throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPYm2zwHwAFgQJQmStAeQAAAABJRU5ErkJggg=="
        let imageSize = try #require(Data(base64Encoded: png)).count
        let value: [String: Any] = ["id":"a1", "threadId":"b1", "labelIds":["INBOX"], "internalDate":"1793815200000", "payload":["mimeType":"multipart/related", "parts":[
            ["mimeType":"text/plain", "body":["size":5, "data":Data("Hallo".utf8).base64EncodedString()]],
            ["mimeType":"text/html", "body":["size":30, "data":Data("<p>Hallo</p><img src='cid:logo'>".utf8).base64EncodedString()]],
            ["mimeType":"image/png", "headers":[["name":"Content-ID", "value":"<logo>"]], "body":["size":imageSize, "attachmentId":"inline_logo"]],
            ["mimeType":"image/png", "headers":[["name":"Content-ID", "value":"<unused>"]], "body":["size":imageSize, "attachmentId":"never_fetch"]]
        ]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        let transport = Transport([.init(status: 200, body: json), .init(status: 200, body: "{\"size\":\(imageSize),\"data\":\"\(png)\"}"), .init(status: 200, body: json)])
        let client = GmailClient(configuration: try configuration(AccountID()), tokens: Tokens(), transport: transport)
        let html = try await client.body(id: "a1", preferHTML: true, maximumBytes: 2 * 1024 * 1024)
        #expect(html.format == .html && Set(html.inlineImages.keys) == ["logo"])
        let plain = try await client.body(id: "a1", preferHTML: false, maximumBytes: 2 * 1024 * 1024)
        #expect(plain.format == .plainText && plain.text == "Hallo" && plain.inlineImages.isEmpty)
        let paths = await transport.paths
        #expect(paths.count == 3 && paths[1].contains("messages/a1/attachments/inline_logo"))
        #expect(!paths.contains { $0.contains("never_fetch") })
        #expect(await transport.methods.allSatisfy { $0 == "GET" })
    }
    @Test func ambiguousSendIsDurableAndDoesNotRepeatAfterRestart() async throws {
        let workspace = Workspace(); defer { workspace.cleanup() }
        let repo = try workspace.repository(), account = try makeAccount()
        try await repo.saveGmailAccount(account, configuration: configuration(account.id), folders: folders(account.id))
        var draft = LocalDraft(accountID: account.id, sender: account.address.value)
        draft.to = "recipient@example.invalid"; draft.body = "only synthetic content"
        draft = try await repo.saveDraft(draft, expectedRevision: 0)
        let api = FakeGmail(account.id); await api.configure(sendError: .uncertain)
        let sender = GmailSubmission(repository: repo, index: repo) { _ in api }
        let receipt = try await sender.send(id: draft.id, account: account.id, expectedRevision: draft.revision, attachments: [])
        #expect(receipt.status == .uncertain && receipt.internetMessageID != nil)
        await #expect(throws: ComposeFailure.conflict) { try await sender.send(id: receipt.id, account: account.id, expectedRevision: receipt.revision, attachments: []) }
        _ = try await sender.reconcile(id: receipt.id, account: account.id)
        #expect(await api.sends == 1)
        try await repo.close()
        let reopened = try workspace.repository()
        #expect(try await reopened.draft(id: draft.id, account: account.id).status == .uncertain)
        try await reopened.close()
    }
    @Test func ownDraftDetectsChangesAtGoogleBeforeOverwritingAndBccIsIncludedOnlyForGmail() async throws {
        let workspace = Workspace(); defer { workspace.cleanup() }
        let repo = try workspace.repository(), account = try makeAccount()
        try await repo.saveGmailAccount(account, configuration: configuration(account.id), folders: folders(account.id))
        var draft = LocalDraft(accountID: account.id, sender: account.address.value)
        draft.to = "recipient@example.invalid"; draft.bcc = "blind@example.invalid"; draft.body = "synthetic"
        draft = try await repo.saveDraft(draft, expectedRevision: 0)
        let api = FakeGmail(account.id), service = GmailSubmission(repository: repo, index: repo) { _ in api }
        draft = try await service.saveAtGoogle(id: draft.id, account: account.id, expectedRevision: draft.revision, attachments: [])
        #expect(try SwiftMailMIMEEncoder.prepare(draft, attachments: [], includeBcc: true).rawMessage.contains("Bcc: blind@example.invalid"))
        #expect(try !SwiftMailMIMEEncoder.prepare(draft, attachments: []).rawMessage.contains("blind@example.invalid"))
        await api.configure(version: "changed")
        let saved = draft
        await #expect(throws: ComposeFailure.conflict) { try await service.saveAtGoogle(id: saved.id, account: account.id, expectedRevision: saved.revision, attachments: []) }
        #expect(await api.saves == 1)
        try await repo.close()
    }
    @Test func mutationRequiresReadbackAndUnconfirmedWritesAreNotRepeated() async throws {
        let workspace = Workspace(); defer { workspace.cleanup() }
        let repo = try workspace.repository(), account = try makeAccount()
        try await repo.saveGmailAccount(account, configuration: configuration(account.id), folders: folders(account.id))
        let api = FakeGmail(account.id), service = GmailService(index: repo) { _ in api }
        try await service.synchronize(account: account)
        let scope = AccessScope(accountIDs: [account.id]), id = try GmailIdentity.message(account: account.id, id: "a1")
        let unread = try await repo.message(id: id, in: scope)
        let profileReads = await api.profileReads
        let history = try await repo.gmailCheckpoint(account: account.id).historyID
        try await service.perform(.read(true), message: unread, account: account, scope: scope)
        #expect(await api.profileReads == profileReads)
        #expect(try await repo.gmailCheckpoint(account: account.id).historyID == history)
        let read = try await repo.message(id: id, in: scope)
        #expect(!read.isUnread && read.folderIDs == unread.folderIDs)
        #expect(try await !repo.gmailPendingAction(account: account.id))
        await api.configure(ignoreWrites: true)
        await #expect(throws: GmailFailure.pendingAction) { try await service.perform(.read(false), message: read, account: account, scope: scope) }
        #expect(try await repo.gmailPendingAction(account: account.id))
        await #expect(throws: GmailFailure.pendingAction) { try await service.perform(.flagged(true), message: read, account: account, scope: scope) }
        try await service.synchronize(account: account)
        #expect(await api.modifications == 2)
        #expect(try await !repo.message(id: id, in: scope).isUnread)
        #expect(try await service.verify(.read(true), message: read, account: account, scope: scope))
        #expect(try await !service.verify(.read(false), message: read, account: account, scope: scope))
        #expect(await api.modifications == 2)
        try await repo.close()
    }
    @Test func staleReadStateCannotOverwriteAnExternalChange() async throws {
        let workspace = Workspace(); defer { workspace.cleanup() }
        let repo = try workspace.repository(), account = try makeAccount()
        try await repo.saveGmailAccount(account, configuration: configuration(account.id), folders: folders(account.id))
        let api = FakeGmail(account.id), service = GmailService(index: repo) { _ in api }
        try await service.synchronize(account: account)
        let scope = AccessScope(accountIDs: [account.id]), id = try GmailIdentity.message(account: account.id, id: "a1")
        let stale = try await repo.message(id: id, in: scope)
        await api.modify(id: "a1", adding: [], removing: ["UNREAD"])
        await #expect(throws: MailFailure.providerFailure) { try await service.perform(.read(true), message: stale, account: account, scope: scope) }
        #expect(await api.modifications == 1)
        #expect(try await !repo.gmailPendingAction(account: account.id))
        try await repo.close()
    }
    @Test func coverageResetRebuildsOnlyMetadataAndPreservesOwnDraft() async throws {
        let workspace = Workspace(); defer { workspace.cleanup() }
        let repo = try workspace.repository(), account = try makeAccount()
        try await repo.saveGmailAccount(account, configuration: configuration(account.id), folders: folders(account.id))
        let api = FakeGmail(account.id), service = GmailService(index: repo) { _ in api }
        try await service.synchronize(account: account, label: "Label_test")
        var draft = LocalDraft(accountID: account.id, sender: account.address.value)
        draft.body = "own synthetic draft"
        draft = try await repo.saveDraft(draft, expectedRevision: 0)
        try await repo.resetGmailCoverage(account: account.id)
        let checkpoint = try await repo.gmailCheckpoint(account: account.id)
        #expect(checkpoint.labels == ["INBOX"] && checkpoint.historyID == nil && checkpoint.knownIDs == ["a1"])
        await api.configure(ids: ["a2"])
        try await service.synchronize(account: account)
        #expect(try await repo.gmailCheckpoint(account: account.id).knownIDs == ["a2"])
        #expect(try await repo.draft(id: draft.id, account: account.id).body == draft.body)
        try await repo.close()
    }
    @Test func draftRecoveryUsesOnlyMessageIDHeadersAndRejectsOtherMessages() async throws {
        let transport = Transport([
            .init(status: 200, body: #"{"drafts":[{"id":"r1","message":{"id":"a1"}},{"id":"r2","message":{"id":"a2"}}]}"#),
            .init(status: 200, body: #"{"id":"a1","payload":{"headers":[{"name":"Message-ID","value":"<own@example.invalid>"}]}}"#),
            .init(status: 200, body: #"{"id":"a2","payload":{"headers":[{"name":"Message-ID","value":"<other@example.invalid>"}]}}"#)
        ])
        let client = GmailClient(configuration: try configuration(AccountID()), tokens: Tokens(), transport: transport)
        #expect(try await client.findDraft(internetMessageID: "<own@example.invalid>") == GmailDraftReceipt(id: "r1", messageID: "a1"))
        let paths = await transport.paths
        let query = URLComponents(string: paths[0])?.queryItems?.first { $0.name == "q" }?.value
        #expect(query == "rfc822msgid:own@example.invalid")
        #expect(paths.dropFirst().allSatisfy { $0.contains("format=metadata") && !$0.contains("body") })
    }
    private func makeAccount() throws -> MailAccount { MailAccount(id: try AccountID(), name: "Synthetic Gmail", address: try EmailAddress("reader@example.invalid"), provider: .gmail, status: .connected) }
    private func configuration(_ account: AccountID, _ permission: GmailPermission = .manageMail) throws -> GmailConfiguration { try GmailConfiguration(accountID: account, clientID: publicClient, permission: permission) }
}

private actor DownloadCapture {
    var bytes = Data()
    var largest = 0
    func append(_ data: Data) { bytes.append(data); largest = max(largest, data.count) }
}
extension GmailTests {
    @Test func attachmentEndpointUsesReadOnlyGETAndValidatesDecodedSize() async throws {
        let account = try AccountID(), bytes = Data(repeating: 120, count: 140_000)
        let json: [String: Any] = ["id": "a1", "threadId": "b1", "labelIds": ["INBOX"], "internalDate": "1793815200000",
            "payload": ["mimeType": "multipart/mixed", "parts": [["partId": "1", "mimeType": "application/pdf", "filename": "../../test.pdf", "body": ["size": bytes.count, "attachmentId": "remote_A-1"]]]]]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        let wire = try JSONDecoder().decode(GmailMessage.self, from: Data(text.utf8))
        let message = try GmailMapping.message(wire, account: account, folders: folders(account)).0
        let attachment = try #require(message.attachments.first)
        let body = String(decoding: try JSONSerialization.data(withJSONObject: ["size": bytes.count, "data": bytes.base64URL]), as: UTF8.self)
        let transport = Transport([.init(status: 200, body: text), .init(status: 200, body: body)])
        let api = GmailClient(configuration: try configuration(account, .readOnly), tokens: Tokens(), transport: transport)
        let capture = DownloadCapture()
        try await api.download(AttachmentRequest(message: message, attachment: attachment, scope: AccessScope(accountIDs: [account])),
            sink: { await capture.append($0) }, progress: { _, _ in })
        #expect(await capture.bytes == bytes)
        #expect(await capture.largest <= AttachmentRequest.chunkSize)
        #expect(await transport.methods == ["GET", "GET"])
        #expect(await transport.paths.last?.contains("/messages/a1/attachments/remote_A-1") == true)
        let wrong = Transport([.init(status: 200, body: text), .init(status: 200, body: "{\"size\":140000,\"data\":\"eA\"}")])
        let bad = GmailClient(configuration: try configuration(account, .readOnly), tokens: Tokens(), transport: wrong)
        await #expect(throws: AttachmentFailure.invalidData) {
            try await bad.download(AttachmentRequest(message: message, attachment: attachment, scope: AccessScope(accountIDs: [account])), sink: { _ in }, progress: { _, _ in })
        }
    }
    @Test func inlineAttachmentRequiresExplicitRequestAndExternalIDsAreRejected() async throws {
        let account = try AccountID()
        let json = #"{"id":"a1","threadId":"b1","labelIds":["INBOX"],"internalDate":"1793815200000","payload":{"mimeType":"multipart/mixed","parts":[{"partId":"1","mimeType":"image/png","headers":[{"name":"content-id","value":"<demo>"}],"body":{"size":3,"data":"YWJj"}}]}}"#
        let wire = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
        let message = try GmailMapping.message(wire, account: account, folders: folders(account)).0
        let attachment = try #require(message.attachments.first), capture = DownloadCapture()
        let transport = Transport([.init(status: 200, body: json), .init(status: 200, body: json)])
        let api = GmailClient(configuration: try configuration(account, .readOnly), tokens: Tokens(), transport: transport)
        let request = try AttachmentRequest(message: message, attachment: attachment, scope: AccessScope(accountIDs: [account]))
        try await api.download(request, sink: { await capture.append($0) }, progress: { _, _ in })
        #expect(await capture.bytes == Data("abc".utf8))
        let forbidden = json.replacingOccurrences(of: "\"data\":\"YWJj\"", with: "\"attachmentId\":\"https://example.invalid/steal\"")
        let invalidTransport = Transport([.init(status: 200, body: forbidden)])
        let invalidAPI = GmailClient(configuration: try configuration(account, .readOnly), tokens: Tokens(), transport: invalidTransport)
        await #expect(throws: AttachmentFailure.invalidData) { try await invalidAPI.download(request, sink: { _ in }, progress: { _, _ in }) }
        #expect(await invalidTransport.paths.count == 1)
    }
}

private actor PagedGmail: GmailAPI, GmailPagedReadAPI {
    nonisolated let accountID: AccountID
    var failPage = true
    var cursors: [String?] = []
    var changed = false
    var metadataCount = 0
    var changedCatalog = false
    var failChangedMetadata = false
    var createLabelDuringHistory = false
    init(_ id: AccountID) { accountID = id }
    func resume() { failPage = false }
    func change() { changed = true }
    func changeLabels(failMetadata: Bool = false, duringHistory: Bool = false) {
        changed = true; failChangedMetadata = failMetadata
        if duringHistory { createLabelDuringHistory = true } else { changedCatalog = true }
    }
    func profile() -> GmailProfile { GmailProfile(email: "reader@example.invalid", historyID: "42") }
    func folders() throws -> [MailFolder] {
        try (["INBOX", "TRASH", "SPAM"] + (1...7).map { "Label_\($0)" } + [changedCatalog ? "Label_9" : "Label_8"]).map {
            try MailFolder(id: GmailIdentity.folder(account: accountID, label: $0), accountID: accountID, providerID: $0, name: $0, role: $0 == "INBOX" ? .inbox : .custom)
        }
    }
    func allMessageIDs(cursor: String?) throws -> GmailMessagePage {
        cursors.append(cursor)
        let start = cursor.flatMap(Int.init) ?? 0
        if start == 100 && failPage { throw MailFailure.offline }
        let end = min(start + 100, 245)
        return GmailMessagePage(ids: ((start + 1)...end).map(String.init), nextCursor: end < 245 ? String(end) : nil)
    }
    func messageIDs(label: String, limit: Int, query: String?) throws -> [String] { throw MailFailure.unsupported }
    func history(since: String) -> GmailHistory {
        if createLabelDuringHistory { changedCatalog = true; createLabelDuringHistory = false }
        return GmailHistory(changedIDs: changed ? ["245", "246"] : [], historyID: changed ? "44" : "43")
    }
    func metadata(id: String, folders: [MailFolder]) throws -> (MailMessage, String) {
        metadataCount += 1
        if changed && failChangedMetadata { throw MailFailure.offline }
        if changed && id == "245" { throw MailFailure.notFound }
        return try GmailMapping.message(wire(id, labels: ["INBOX", "SPAM", changedCatalog ? "Label_9" : "Label_8"]), account: accountID, folders: folders)
    }
    func body(id: String, preferHTML: Bool, maximumBytes: Int) throws -> MailBody { throw MailFailure.unsupported }
    func draftVersion(id: String) throws -> GmailDraftReceipt { throw MailFailure.unsupported }
    func findDraft(internetMessageID: String) -> GmailDraftReceipt? { nil }
    func modify(id: String, adding: [String], removing: [String]) throws { throw MailFailure.unsupported }
    func send(raw: Data, draftID: String?) throws -> String { throw MailFailure.unsupported }
    func saveDraft(raw: Data, draftID: String?) throws -> GmailDraftReceipt { throw MailFailure.unsupported }
}
struct FullGmailTests {
    private func configuration(_ account: AccountID) throws -> GmailConfiguration {
        try GmailConfiguration(accountID: account, clientID: publicClient, permission: .readOnly)
    }
    @Test func labelCatalogUpdatesBeforeMessageFailureAndPreservesMailAndCheckpoint() async throws {
        let test = Workspace(); defer { test.cleanup() }
        let repo = try test.repository(), id = try AccountID(), api = PagedGmail(id)
        let account = MailAccount(id: id, name: "Gmail", address: try EmailAddress("reader@example.invalid"), provider: .gmail, status: .connected)
        try await repo.saveGmailAccount(account, configuration: configuration(id), folders: api.folders())
        let service = GmailService(index: repo) { _ in api }
        await api.resume(); try await service.synchronize(account: account)
        let removed = try GmailIdentity.folder(account: id, label: "Label_8")
        let kept = try GmailIdentity.folder(account: id, label: "Label_1")
        try await repo.saveFolderOrder([removed, kept], account: id)
        await api.changeLabels(failMetadata: true)
        await #expect(throws: MailFailure.offline) { try await service.synchronize(account: account) }
        let current = try await repo.folders(in: AccessScope(accountIDs: [id]))
        #expect(!current.contains { $0.id == removed })
        #expect(current.contains { $0.providerID == "Label_9" })
        #expect(try await repo.folderOrder(account: id) == [kept])
        #expect(try await repo.summary().messageCount == 245)
        #expect(try await repo.fullGmailHistory(account: id) == "43")
        let message = try await repo.message(id: GmailIdentity.message(account: id, id: "244"), in: AccessScope(accountIDs: [id]))
        #expect(!message.folderIDs.contains(removed))
        await api.changeLabels()
        try await service.synchronize(account: account)
        #expect(try await repo.fullGmailHistory(account: id) == "44")
        try await repo.close()
    }
    @Test func labelCreatedDuringHistoryDiscoveryIsMappedBeforeAdvancingCursor() async throws {
        let test = Workspace(); defer { test.cleanup() }
        let repo = try test.repository(), id = try AccountID(), api = PagedGmail(id)
        let account = MailAccount(id: id, name: "Gmail", address: try EmailAddress("reader@example.invalid"), provider: .gmail, status: .connected)
        try await repo.saveGmailAccount(account, configuration: configuration(id), folders: api.folders())
        let service = GmailService(index: repo) { _ in api }
        await api.resume(); try await service.synchronize(account: account)
        await api.changeLabels(duringHistory: true)
        try await service.synchronize(account: account)
        let message = try await repo.message(id: GmailIdentity.message(account: id, id: "246"), in: AccessScope(accountIDs: [id]))
        #expect(message.folderIDs.contains(try GmailIdentity.folder(account: id, label: "Label_9")))
        #expect(try await repo.fullGmailHistory(account: id) == "44")
        try await repo.close()
    }
    @Test func bulkHistoryBeyondOldLimitDoesNotForceFullScanAndDeletedLabelsNeedNoFetch() async throws {
        let id = try AccountID()
        var replies: [Transport.Reply] = []
        for page in 0..<12 {
            let events: [[String: Any]] = (0..<500).map { number in
                let key = "m\(page * 500 + number)"
                return ["messages": [["id": key]], "labelsRemoved": [["message": ["id": key], "labelIds": ["Label_deleted"]]]]
            }
            var body: [String: Any] = ["historyId": "99", "history": events]
            if page < 11 { body["nextPageToken"] = "page\(page + 1)" }
            replies.append(.init(status: 200, body: String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)))
        }
        let retainedTransport = Transport(replies)
        let retained = GmailClient(configuration: try configuration(id), tokens: Tokens(), transport: retainedTransport)
        let all = try await retained.history(since: "42", existingLabelIDs: ["INBOX", "Label_deleted"], progress: { _, _ in })
        #expect(all.changedIDs.count == 6000 && all.historyID == "99")
        let removedTransport = Transport(replies)
        let removed = GmailClient(configuration: try configuration(AccountID()), tokens: Tokens(), transport: removedTransport)
        let reduced = try await removed.history(since: "42", existingLabelIDs: ["INBOX"], progress: { _, _ in })
        #expect(reduced.changedIDs.isEmpty && reduced.historyID == "99")
        #expect(await removedTransport.paths.count == 12)
        #expect(await removedTransport.methods.allSatisfy { $0 == "GET" })
    }
    @Test func typedHistoryRetainsReadChangesAndGenericFallback() async throws {
        let body = #"{"historyId":"43","history":[{"messages":[{"id":"a"},{"id":"b"},{"id":"c"},{"id":"d"}],"labelsRemoved":[{"message":{"id":"a"},"labelIds":["Label_deleted"]},{"message":{"id":"b"},"labelIds":["UNREAD"]},{"message":{"id":"c"}}]}]}"#
        let api = GmailClient(configuration: try configuration(AccountID()), tokens: Tokens(), transport: Transport([.init(status: 200, body: body)]))
        let result = try await api.history(since: "42", existingLabelIDs: ["INBOX", "UNREAD"], progress: { _, _ in })
        #expect(result.changedIDs == ["b", "c", "d"])
    }
    @Test func completeMailboxResumesIncludesMoreThanFiveLabelsAndUsesHistoryThereafter() async throws {
        let test = Workspace(); defer { test.cleanup() }
        var repo = try test.repository()
        let id = try AccountID(), api = PagedGmail(id)
        let account = MailAccount(id: id, name: "Full Gmail", address: try EmailAddress("reader@example.invalid"), provider: .gmail, status: .connected)
        try await repo.saveGmailAccount(account, configuration: GmailConfiguration(accountID: id, clientID: publicClient, permission: .readOnly), folders: api.folders())
        var service = GmailService(index: repo) { _ in api }
        await #expect(throws: MailFailure.offline) { try await service.synchronize(account: account) }
        #expect(try await repo.summary().messageCount == 100)
        #expect(try await repo.fullGmailHistory(account: id) == nil)
        try await repo.close(); repo = try test.repository()
        service = GmailService(index: repo) { _ in api }; await api.resume()
        try await service.synchronize(account: account)
        #expect(try await repo.summary().messageCount == 245)
        #expect(try await repo.folders(in: AccessScope(accountIDs: [id])).count == 11)
        #expect(await api.cursors == [nil, "100", "100", "200"])
        let count = await api.metadataCount
        let obsoleteScan = try await repo.fullMailScan(account: id, scope: "gmail", anchor: "43")
        await api.change(); try await service.synchronize(account: account)
        #expect(await api.metadataCount == count + 2)
        #expect(try await repo.gmailCheckpoint(account: id).knownIDs.contains("246"))
        #expect(try await !repo.gmailCheckpoint(account: id).knownIDs.contains("245"))
        #expect(try await repo.fullGmailHistory(account: id) == "44")
        let freshScan = try await repo.fullMailScan(account: id, scope: "gmail", anchor: "44")
        #expect(freshScan.generation != obsoleteScan.generation, "A successful history pass retires an unnecessary partial rescan")
        try await repo.resetFullMailScan(account: id, scope: "gmail")
        try await repo.close()
    }
    @Test func gmailPagingHasNoLabelDateOrSpamRestriction() async throws {
        let id = try AccountID(), transport = Transport([.init(status: 200, body: "{\"messages\":[{\"id\":\"a1\"}],\"nextPageToken\":\"next\"}"), .init(status: 200, body: "{}")])
        let client = GmailClient(configuration: try GmailConfiguration(accountID: id, clientID: publicClient, permission: .readOnly), tokens: Tokens(), transport: transport)
        let first = try await client.allMessageIDs(cursor: nil)
        let second = try await client.allMessageIDs(cursor: first.nextCursor)
        #expect(first.ids == ["a1"] && second.ids.isEmpty && second.nextCursor == nil)
        let urls = await transport.paths
        #expect(urls.allSatisfy { $0.contains("includeSpamTrash=true") && !$0.contains("labelIds") && !$0.contains("q=") })
        #expect(urls[1].contains("pageToken=next"))
    }
}
