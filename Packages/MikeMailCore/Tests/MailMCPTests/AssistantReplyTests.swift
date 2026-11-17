import Foundation
import Testing
import MCP
import MailDomain
import MailApplication
@testable import MailDemo
import MailPersistence
@testable import MailMCP

private actor ReplyReviewProbe {
    var requests = 0
    var paused = false
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() { paused = true }
    func release() { continuation?.resume(); continuation = nil }
    func review(_ draft: LocalDraft, authorize: @escaping AssistantReplies.Authorization) async throws -> AssistantReplyReadiness {
        started = true
        if paused { await withCheckedContinuation { continuation = $0 } }
        try await authorize()
        requests += 1
        return .demo
    }
}

private actor DirectSendProbe {
    var dispatches = 0
    var started = false
    var paused = false
    var uncertain = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() { paused = true }
    func release() { continuation?.resume(); continuation = nil }
    func makeUncertain() { uncertain = true }
    func send(_ input: LocalDraft, repository: any DraftRepository, authorize: @escaping AssistantReplies.Authorization) async throws -> LocalDraft {
        started = true
        if paused { await withCheckedContinuation { continuation = $0 } }
        try await authorize()
        var draft = input; draft.status = .sending; draft.operationID = UUID()
        draft.internetMessageID = "<synthetic-direct@example.invalid>"
        draft = try await repository.saveDraft(draft, expectedRevision: draft.revision)
        try await authorize()
        dispatches += 1
        draft.status = uncertain ? .uncertain : .accepted
        return try await repository.saveDraft(draft, expectedRevision: draft.revision)
    }
}

private struct ReplyHarness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MMH-replies-\(UUID())")
    let data: DemoDataset
    let repository: EncryptedMailRepository
    let gateway: AssistantGateway
    let probe: ReplyReviewProbe
    let directProbe: DirectSendProbe
    let replies: AssistantReplies
    let source: MailMessage
    var grant: AssistantGrant
    init(connected: Bool = false) async throws {
        let base = try SyntheticFixtures.make()
        let dataset = connected ? DemoDataset(snapshot: try MailSnapshot(accounts: base.snapshot.accounts.map {
            MailAccount(id: $0.id, name: $0.name, address: $0.address, provider: $0.provider, status: .connected)
        }, folders: base.snapshot.folders, threads: base.snapshot.threads, messages: base.snapshot.messages), contents: base.contents) : base
        data = dataset; source = dataset.snapshot.messages[0]
        let repo = try EncryptedMailRepository(paths: WorkspacePaths(root: root, cache: root.appendingPathComponent("Cache")), key: Data(repeating: 42, count: 32))
        repository = repo; try await repo.seedIfNeeded(dataset.snapshot)
        let service = InboxService(repository: repo), probe = ReplyReviewProbe(); self.probe = probe
        let directProbe = DirectSendProbe(); self.directProbe = directProbe
        let replies = AssistantReplies(service: service, repository: repo,
            ownAddresses: { Set(dataset.snapshot.accounts.map(\.address.value)) },
            review: { draft, authorize in try await probe.review(draft, authorize: authorize) },
            directSend: { draft, authorize in try await directProbe.send(draft, repository: repo, authorize: authorize) })
        self.replies = replies
        gateway = AssistantGateway(service: service, replies: replies) { _, _ in "synthetic text" }
        var grant = AssistantGrant(); grant.enabled = true; grant.accountIDs = [source.accountID]
        grant.folderIDs = source.folderIDs; grant.replyAccountIDs = [source.accountID]; grant.composeAccountIDs = [source.accountID]
        grant.directSendAccountIDs = [source.accountID]; self.grant = grant
        await gateway.setGrant(grant)
    }
    func prepare(_ id: UUID = UUID(), body: String = "Danke für die Nachricht.\nFreundliche Grüsse\nMike") async -> CallTool.Result {
        await gateway.call("prepare_reply", arguments: ["email_id": .string(source.id.description), "request_id": .string(id.uuidString), "body": .string(body)])
    }
    func get(_ id: UUID) async -> CallTool.Result {
        await gateway.call("get_reply", arguments: ["email_id": .string(source.id.description), "draft_id": .string(id.uuidString)])
    }
    func request(_ id: UUID, revision: Int) async -> CallTool.Result {
        await gateway.call("request_reply_send", arguments: ["email_id": .string(source.id.description), "draft_id": .string(id.uuidString), "expected_revision": .int(revision)])
    }
    func emailArguments(_ id: UUID) -> [String: Value] {
        ["account": .string(source.accountID.description), "request_id": .string(id.uuidString),
         "to": .array([.string("recipient@example.invalid")]), "subject": .string("Synthetic new message"), "body": .string("This is a local test, never sent.")]
    }
    func prepareEmail(_ id: UUID) async -> CallTool.Result { await gateway.call("prepare_email", arguments: emailArguments(id)) }
    func getEmail(_ id: UUID) async -> CallTool.Result {
        await gateway.call("get_email_draft", arguments: ["account": .string(source.accountID.description), "draft_id": .string(id.uuidString)])
    }
    func requestEmail(_ id: UUID, revision: Int) async -> CallTool.Result {
        await gateway.call("request_email_send", arguments: ["account": .string(source.accountID.description), "draft_id": .string(id.uuidString), "expected_revision": .int(revision)])
    }
    func directArguments(_ draft: LocalDraft) throws -> [String: Value] {
        ["account": .string(draft.accountID.description), "draft_id": .string(draft.id.uuidString),
         "expected_revision": .int(draft.revision), "confirmation_token": .string(try draft.sendConfirmationToken()), "user_requested_send": .bool(true)]
    }
    func close() async throws { try await repository.close(); try FileManager.default.removeItem(at: root) }
}

struct AssistantReplyTests {
    @Test func oldGrantAndOldDraftDecodeWithoutImplicitWritePermission() throws {
        let old = Data(#"{"enabled":true,"accountIDs":[],"folderIDs":[],"allowText":true}"#.utf8)
        #expect(try JSONDecoder().decode(AssistantGrant.self, from: old).replyAccountIDs.isEmpty)
        #expect(try JSONDecoder().decode(AssistantGrant.self, from: old).composeAccountIDs.isEmpty)
        #expect(try JSONDecoder().decode(AssistantGrant.self, from: old).directSendAccountIDs.isEmpty)
        let draft = LocalDraft(accountID: try AccountID(), sender: "synthetic@example.invalid")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        object.removeValue(forKey: "assistantOrigin")
        #expect(try JSONDecoder().decode(LocalDraft.self, from: JSONSerialization.data(withJSONObject: object)).assistantOrigin == nil)
    }
    @Test func separateGrantScopeAndPersonalDraftIsolation() async throws {
        let h = try await ReplyHarness()
        var readonly = h.grant; readonly.replyAccountIDs = []; await h.gateway.setGrant(readonly)
        #expect(await h.prepare().isError == true)
        await h.gateway.setGrant(h.grant)
        let foreign = try #require(h.data.snapshot.messages.first { $0.accountID != h.source.accountID })
        #expect(await h.gateway.call("prepare_reply", arguments: ["email_id": .string(foreign.id.description), "request_id": .string(UUID().uuidString), "body": .string("No")]).isError == true)
        let account = try #require(h.data.snapshot.accounts.first { $0.id == h.source.accountID })
        let privateDraft = try await h.repository.saveDraft(LocalDraft(accountID: account.id, sender: account.address.value), expectedRevision: 0)
        #expect(await h.get(privateDraft.id).isError == true)
        #expect(await h.probe.requests == 0)
        try await h.close()
    }
    @Test func assistantReplySnapshotsOnlyItsOwnAccountSignatureAndProjectsText() async throws {
        let h = try await ReplyHarness(), id = UUID()
        let signature = try MailSignature(html: "<b>Mike</b><br>CuMail")
        try await h.repository.saveSignature(signature, account: h.source.accountID)
        let created = await h.prepare(id)
        #expect(created.isError != true)
        #expect(created.structuredContent?.objectValue?["has_html_signature"] == .bool(true))
        #expect(created.structuredContent?.objectValue?["signature_text"] == .string(signature.plainText))
        try await h.repository.saveSignature(MailSignature(html: "Changed"), account: h.source.accountID)
        #expect(await h.prepare(id).isError != true)
        #expect(try await h.repository.draft(id: id, account: h.source.accountID).signature == signature)
        try await h.close()
    }
    @Test func retriesPreserveHumanEditsAndNativeReviewNeverSubmits() async throws {
        let h = try await ReplyHarness(), id = UUID()
        let created = await h.prepare(id)
        #expect(created.isError != true)
        var draft = try await h.repository.draft(id: id, account: h.source.accountID)
        #expect(draft.to == h.source.sender.address.value && draft.bcc.isEmpty && draft.attachments.isEmpty)
        #expect(!draft.body.contains("Antwort auf Nachricht"))
        draft.body = "Human edit"; draft = try await h.repository.saveDraft(draft, expectedRevision: draft.revision)
        let retry = await h.prepare(id)
        #expect(retry.structuredContent?.objectValue?["body"] == .string("Human edit"))
        #expect(try await h.repository.drafts(account: draft.accountID).count == 1)
        #expect(await h.prepare(id, body: "Different request using same id").isError == true)
        #expect(await h.request(id, revision: 1).isError == true)
        let review = await h.request(id, revision: draft.revision)
        #expect(review.structuredContent?.objectValue?["review"] == .string("demo_cannot_send"))
        #expect(review.structuredContent?.objectValue?["review_window_opened"] == .bool(true))
        #expect(await h.probe.requests == 1)
        #expect(try await h.repository.draft(id: id, account: draft.accountID).status == .editing)
        #expect(try await h.repository.draft(id: id, account: draft.accountID).operationID == nil)
        try await h.close()
    }
    @Test func restartRetainsRequestIdentityAndUncertainSendCannotReopenReview() async throws {
        let h = try await ReplyHarness(), id = UUID()
        #expect(await h.prepare(id).isError != true)
        var draft = try await h.repository.draft(id: id, account: h.source.accountID)
        draft.status = .sending; draft.operationID = UUID(); draft.internetMessageID = "<synthetic@unit.invalid>"
        _ = try await h.repository.saveDraft(draft, expectedRevision: draft.revision)
        try await h.repository.close()
        let reopened = try EncryptedMailRepository(paths: WorkspacePaths(root: h.root, cache: h.root.appendingPathComponent("Cache")), key: Data(repeating: 42, count: 32))
        try await reopened.recoverInterruptedSubmissions()
        let service = InboxService(repository: reopened)
        let replies = AssistantReplies(service: service, repository: reopened, ownAddresses: { [] }, review: { _, _ in Issue.record("Uncertain send was offered again"); return .demo })
        let original = try await replies.prepare(source: h.source.id, requestID: id, body: "Danke für die Nachricht.\nFreundliche Grüsse\nMike", replyAll: false, scope: h.grant.scope, authorize: {})
        #expect(original.status == .uncertain && original.id == id)
        let result = try await replies.requestSend(source: h.source.id, draftID: id, expectedRevision: original.revision, scope: h.grant.scope, authorize: {})
        #expect(result.0.status == .uncertain && result.1 == nil)
        try await reopened.close(); try FileManager.default.removeItem(at: h.root)
    }
    @Test func revokeDuringReviewPreventsOpeningAndDiscardsResult() async throws {
        let h = try await ReplyHarness(), id = UUID()
        #expect(await h.prepare(id).isError != true)
        await h.probe.pause()
        let task = Task { await h.request(id, revision: 1) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await !h.probe.started, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await h.probe.started)
        await h.gateway.setGrant(AssistantGrant()); await h.probe.release()
        #expect(await task.value.isError == true)
        #expect(await h.probe.requests == 0)
        #expect(await h.get(id).isError == true)
        try await h.close()
    }
    @Test func invalidContentAndInjectedRecipientsNeverCreateDrafts() async throws {
        let h = try await ReplyHarness()
        for body in [" ", "bad\u{0000}text", "bad\u{202E}text", String(repeating: "x", count: 6001)] {
            #expect(await h.prepare(body: body).isError == true)
        }
        #expect(await h.gateway.call("prepare_reply", arguments: ["email_id": .string(h.source.id.description), "request_id": .string(UUID().uuidString), "body": .string("safe"), "to": .string("attacker@example.invalid")]).isError == true)
        #expect(try await h.repository.drafts(account: h.source.accountID).isEmpty)
        try await h.close()
    }
    @Test func originCannotBeForgedOntoAnExistingPersonalDraft() async throws {
        let h = try await ReplyHarness()
        let account = try #require(h.data.snapshot.accounts.first { $0.id == h.source.accountID })
        var draft = try await h.repository.saveDraft(LocalDraft(accountID: account.id, sender: account.address.value), expectedRevision: 0)
        draft.assistantOrigin = AssistantReplyOrigin(messageID: h.source.id, requestDigest: String(repeating: "a", count: 64))
        await #expect(throws: ComposeFailure.locked) { try await h.repository.saveDraft(draft, expectedRevision: draft.revision) }
        try await h.close()
    }
}

struct AssistantNewEmailTests {
    @Test func legacyReplyOriginDecodesAndNewOriginCannotCrossAccounts() throws {
        let source = try MessageID(), account = try AccountID()
        // IDs are encoded by their domain type, so use the original reply shape.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AssistantReplyOrigin(messageID: source, requestDigest: String(repeating: "a", count: 64)))) as? [String: Any])
        object.removeValue(forKey: "accountID")
        let decoded = try JSONDecoder().decode(AssistantDraftOrigin.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.messageID == source && decoded.accountID == nil)
        var draft = LocalDraft(accountID: account, sender: "synthetic@example.invalid")
        draft.assistantOrigin = AssistantDraftOrigin(accountID: try AccountID(), requestDigest: String(repeating: "a", count: 64))
        #expect(throws: ComposeFailure.invalidHeader) { try draft.validateStorage() }
    }

    @Test func replyPermissionDoesNotGrantNewMessagesAndPrivateDraftsStayPrivate() async throws {
        let h = try await ReplyHarness(), id = UUID()
        var grant = h.grant; grant.composeAccountIDs = []; await h.gateway.setGrant(grant)
        #expect(await h.prepareEmail(id).isError == true)
        #expect(await h.gateway.call("mail_status", arguments: [:]).structuredContent?.objectValue?["compose_account_ids"] == .array([]))
        await h.gateway.setGrant(h.grant)
        let foreign = try #require(h.data.snapshot.accounts.first { $0.id != h.source.accountID })
        var args = h.emailArguments(id); args["account"] = .string(foreign.id.description)
        #expect(await h.gateway.call("prepare_email", arguments: args).isError == true)
        let account = try #require(h.data.snapshot.accounts.first { $0.id == h.source.accountID })
        let personal = try await h.repository.saveDraft(LocalDraft(accountID: account.id, sender: account.address.value), expectedRevision: 0)
        #expect(await h.getEmail(personal.id).isError == true)
        let reply = UUID(); #expect(await h.prepare(reply).isError != true)
        #expect(await h.getEmail(reply).isError == true)
        #expect(await h.prepareEmail(id).isError != true)
        #expect(await h.get(id).isError == true)
        #expect(await h.probe.requests == 0)
        try await h.close()
    }

    @Test func explicitRecipientsFixedSenderDefaultSignatureAndNoImplicitThread() async throws {
        let h = try await ReplyHarness(), id = UUID()
        let signature = try MailSignature(html: "<b>Selected account signature</b>")
        try await h.repository.saveSignature(signature, account: h.source.accountID)
        var args = h.emailArguments(id)
        args["cc"] = .array([.string("copy@example.invalid")]); args["bcc"] = .array([.string("blind@example.invalid")])
        let result = await h.gateway.call("prepare_email", arguments: args)
        #expect(result.isError != true)
        #expect(result.structuredContent?.objectValue?["kind"] == .string("new_email"))
        #expect(result.structuredContent?.objectValue?["email_id"] == .null)
        let draft = try await h.repository.draft(id: id, account: h.source.accountID)
        #expect(draft.sender == h.data.snapshot.accounts.first { $0.id == draft.accountID }?.address.value)
        #expect(draft.to == "recipient@example.invalid" && draft.cc == "copy@example.invalid" && draft.bcc == "blind@example.invalid")
        #expect(draft.signature == signature && draft.inReplyTo == nil && draft.references.isEmpty && draft.attachments.isEmpty)
        #expect(draft.assistantOrigin?.accountID == draft.accountID)
        try await h.repository.saveSignature(MailSignature(html: "Changed template"), account: h.source.accountID)
        #expect(await h.gateway.call("prepare_email", arguments: args).isError != true)
        #expect(try await h.repository.draft(id: id, account: draft.accountID).signature == signature)
        try await h.close()
    }

    @Test func retryPreservesHumanEditsAndReviewRequiresExactRevisionWithoutSending() async throws {
        let h = try await ReplyHarness(), id = UUID()
        #expect(await h.prepareEmail(id).isError != true)
        var draft = try await h.repository.draft(id: id, account: h.source.accountID)
        draft.body = "Human edit"; draft.to = "changed@example.invalid"
        draft = try await h.repository.saveDraft(draft, expectedRevision: draft.revision)
        #expect(await h.prepareEmail(id).structuredContent?.objectValue?["body"] == .string("Human edit"))
        var args = h.emailArguments(id); args["subject"] = .string("Different intent")
        #expect(await h.gateway.call("prepare_email", arguments: args).isError == true)
        #expect(await h.requestEmail(id, revision: 1).isError == true)
        let review = await h.requestEmail(id, revision: draft.revision)
        #expect(review.structuredContent?.objectValue?["review_window_opened"] == .bool(true))
        #expect(review.structuredContent?.objectValue?["to"] == .string("changed@example.invalid"))
        #expect(await h.probe.requests == 1)
        #expect(try await h.repository.draft(id: id, account: draft.accountID).status == .editing)
        #expect(try await h.repository.drafts(account: draft.accountID).count == 1)
        try await h.close()
    }

    @Test func newMessageIdentitySurvivesRestartAndUncertainSubmissionCannotRepeat() async throws {
        let h = try await ReplyHarness(), id = UUID()
        #expect(await h.prepareEmail(id).isError != true)
        var draft = try await h.repository.draft(id: id, account: h.source.accountID)
        draft.status = .sending; draft.operationID = UUID(); draft.internetMessageID = "<synthetic-new@unit.invalid>"
        _ = try await h.repository.saveDraft(draft, expectedRevision: draft.revision)
        try await h.repository.close()
        let repo = try EncryptedMailRepository(paths: WorkspacePaths(root: h.root, cache: h.root.appendingPathComponent("Cache")), key: Data(repeating: 42, count: 32))
        try await repo.recoverInterruptedSubmissions()
        let replies = AssistantReplies(service: InboxService(repository: repo), repository: repo, ownAddresses: { [] }, review: { _, _ in Issue.record("Must not repeat uncertain send"); return .demo })
        let original = try await replies.prepareEmail(accountID: draft.accountID, requestID: id, to: ["recipient@example.invalid"], subject: "Synthetic new message", body: "This is a local test, never sent.", scope: h.grant.scope, authorize: {})
        #expect(original.status == .uncertain && original.id == id)
        let result = try await replies.requestEmailSend(accountID: draft.accountID, draftID: id, expectedRevision: original.revision, scope: h.grant.scope, authorize: {})
        #expect(result.0.status == .uncertain && result.1 == nil)
        try await repo.close(); try FileManager.default.removeItem(at: h.root)
    }

    @Test func revokeNewMessageGrantWhileOpeningReviewPreventsDisclosureAndReview() async throws {
        let h = try await ReplyHarness(), id = UUID()
        #expect(await h.prepareEmail(id).isError != true)
        await h.probe.pause()
        let task = Task { await h.requestEmail(id, revision: 1) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await !h.probe.started, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await h.probe.started)
        var grant = h.grant; grant.composeAccountIDs = []; await h.gateway.setGrant(grant); await h.probe.release()
        #expect(await task.value.isError == true)
        #expect(await h.getEmail(id).isError == true)
        #expect(await h.probe.requests == 0)
        try await h.close()
    }

    @Test func malformedOrSmuggledNewMessageArgumentsCannotPersist() async throws {
        let h = try await ReplyHarness()
        let alterations: [[String: Value]] = [
            ["to": .array([])], ["to": .array([.string("ok@example.invalid\r\nBcc: hidden@example.invalid")])],
            ["sender": .string("forged@example.invalid")], ["subject": .string("bad\u{202E}subject")],
            ["to": .array([.string("Name <person@example.invalid>")])], ["attachments": .array([])]
        ]
        for fields in alterations {
            let result = await h.gateway.call("prepare_email", arguments: h.emailArguments(UUID()).merging(fields) { _, new in new })
            #expect(result.isError == true)
            if case .text(let text, _, _) = result.content.first { #expect(!text.contains("rate_limited")) }
        }
        #expect(try await h.repository.drafts(account: h.source.accountID).isEmpty)
        try await h.close()
    }

    @Test func serviceRejectsEmptyOversizedOrInjectedContentAndRevokedSave() async throws {
        let h = try await ReplyHarness()
        for body in [" ", "bad\u{0000}text", "bad\u{202E}text", String(repeating: "x", count: 6001)] {
            await #expect(throws: MailFailure.invalidInput) {
                try await h.replies.prepareEmail(accountID: h.source.accountID, requestID: UUID(), to: ["recipient@example.invalid"], subject: "Test", body: body, scope: h.grant.scope, authorize: {})
            }
        }
        await #expect(throws: MailFailure.invalidInput) {
            try await h.replies.prepareEmail(accountID: h.source.accountID, requestID: UUID(), to: Array(repeating: "recipient@example.invalid", count: 101), subject: "Test", body: "Body", scope: h.grant.scope, authorize: {})
        }
        await #expect(throws: MailFailure.permissionDenied) {
            try await h.replies.prepareEmail(accountID: h.source.accountID, requestID: UUID(), to: ["recipient@example.invalid"], subject: "Test", body: "Body", scope: h.grant.scope, authorize: { throw MailFailure.permissionDenied })
        }
        #expect(try await h.repository.drafts(account: h.source.accountID).isEmpty)
        try await h.close()
    }
}

struct AssistantDirectSendTests {
    @Test func preparationAndNativeReviewNeverBecomeImmediateSend() async throws {
        let h = try await ReplyHarness(connected: true), id = UUID()
        let prepared = await h.prepareEmail(id)
        #expect(prepared.isError != true)
        #expect(prepared.structuredContent?.objectValue?["confirmation_token"]?.stringValue?.count == 64)
        #expect(await h.requestEmail(id, revision: 1).isError != true)
        #expect(await h.directProbe.dispatches == 0)
        let draft = try await h.repository.draft(id: id, account: h.source.accountID)
        var args = try h.directArguments(draft); args.removeValue(forKey: "user_requested_send")
        #expect(await h.gateway.call("send_email_now", arguments: args).isError == true)
        args["user_requested_send"] = .bool(false)
        #expect(await h.gateway.call("send_email_now", arguments: args).isError == true)
        var grant = h.grant; grant.directSendAccountIDs = []; await h.gateway.setGrant(grant)
        #expect(await h.gateway.call("send_email_now", arguments: try h.directArguments(draft)).isError == true)
        #expect(await h.directProbe.dispatches == 0)
        #expect(try await h.repository.draft(id: id, account: h.source.accountID).status == .editing)
        try await h.close()
    }

    @Test func explicitImmediateSendIsBoundToExactVersionAndReplayOnlyReportsReceipt() async throws {
        let h = try await ReplyHarness(connected: true), id = UUID()
        #expect(await h.prepareEmail(id).isError != true)
        var draft = try await h.repository.draft(id: id, account: h.source.accountID)
        let original = try h.directArguments(draft)
        var wrong = original; wrong["confirmation_token"] = .string(String(repeating: "0", count: 64))
        #expect(await h.gateway.call("send_email_now", arguments: wrong).isError == true)
        draft.to = "changed@example.invalid"; draft.useSignature(NamedMailSignature(name: "Changed", content: try MailSignature(html: "Changed signature")))
        draft = try await h.repository.saveDraft(draft, expectedRevision: draft.revision)
        #expect(await h.gateway.call("send_email_now", arguments: original).isError == true)
        let args = try h.directArguments(draft)
        let result = await h.gateway.call("send_email_now", arguments: args)
        #expect(result.isError != true)
        #expect(result.structuredContent?.objectValue?["status"] == .string("accepted"))
        #expect(result.structuredContent?.objectValue?["direct_send_requested"] == .bool(true))
        #expect(result.structuredContent?.objectValue?["confirmation_token"] == .null)
        #expect(await h.probe.requests == 0)
        #expect(await h.gateway.call("send_email_now", arguments: args).structuredContent?.objectValue?["status"] == .string("accepted"))
        #expect(await h.directProbe.dispatches == 1)
        try await h.close()
    }

    @Test func draftTokenIncludesAllContentEvenBeforeRevisionChanges() throws {
        var draft = LocalDraft(accountID: try AccountID(), sender: "synthetic@example.invalid")
        draft.to = "recipient@example.invalid"; draft.body = "Original"
        let token = try draft.sendConfirmationToken()
        #expect(try JSONDecoder().decode(LocalDraft.self, from: JSONEncoder().encode(draft)).sendConfirmationToken() == token)
        for path in [\LocalDraft.to, \.cc, \.bcc, \.subject, \.body] {
            var changed = draft; changed[keyPath: path] += "changed"
            #expect(try changed.sendConfirmationToken() != token)
        }
        draft.signature = try MailSignature(html: "Changed signature")
        #expect(try draft.sendConfirmationToken() != token)
    }

    @Test func exactOriginPermissionAndReplyFolderScopeAreRequired() async throws {
        let h = try await ReplyHarness(connected: true)
        let account = try #require(h.data.snapshot.accounts.first { $0.id == h.source.accountID })
        var draft = LocalDraft(accountID: account.id, sender: account.address.value)
        draft.to = "synthetic@example.invalid"; draft.body = "Explicit synthetic reply"
        draft.assistantOrigin = AssistantReplyOrigin(messageID: h.source.id, requestDigest: String(repeating: "a", count: 64))
        draft = try await h.repository.saveDraft(draft, expectedRevision: 0)
        let args = try h.directArguments(draft)
        var grant = h.grant; grant.replyAccountIDs = []; await h.gateway.setGrant(grant)
        #expect(await h.gateway.call("send_email_now", arguments: args).isError == true)
        grant = h.grant
        grant.folderIDs = Set(h.data.snapshot.folders.filter { $0.accountID == account.id && !h.source.folderIDs.contains($0.id) }.map(\.id))
        #expect(!grant.folderIDs.isEmpty); await h.gateway.setGrant(grant)
        #expect(await h.gateway.call("send_email_now", arguments: args).isError == true)
        grant = h.grant; grant.composeAccountIDs = []; await h.gateway.setGrant(grant)
        #expect(await h.gateway.call("send_email_now", arguments: args).structuredContent?.objectValue?["status"] == .string("accepted"))
        #expect(await h.directProbe.dispatches == 1)
        try await h.close()
    }

    @Test func concurrentRequestAndRevocationCannotDispatchTwiceOrAfterRevocation() async throws {
        let h = try await ReplyHarness(connected: true), id = UUID()
        #expect(await h.prepareEmail(id).isError != true)
        let draft = try await h.repository.draft(id: id, account: h.source.accountID), args = try h.directArguments(draft)
        await h.directProbe.pause()
        let pending = Task { await h.gateway.call("send_email_now", arguments: args) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await !h.directProbe.started, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await h.directProbe.started)
        #expect(await h.gateway.call("send_email_now", arguments: args).isError == true)
        var grant = h.grant; grant.directSendAccountIDs = []; await h.gateway.setGrant(grant)
        await h.directProbe.release()
        #expect(await pending.value.isError == true)
        #expect(await h.directProbe.dispatches == 0)
        try await h.close()
    }

    @Test func uncertainDirectSendSurvivesRestartWithoutDispatchingAgain() async throws {
        let h = try await ReplyHarness(connected: true), id = UUID()
        #expect(await h.prepareEmail(id).isError != true)
        let draft = try await h.repository.draft(id: id, account: h.source.accountID), args = try h.directArguments(draft)
        await h.directProbe.makeUncertain()
        #expect(await h.gateway.call("send_email_now", arguments: args).structuredContent?.objectValue?["status"] == .string("uncertain"))
        #expect(await h.directProbe.dispatches == 1)
        try await h.repository.close()
        let repo = try EncryptedMailRepository(paths: WorkspacePaths(root: h.root, cache: h.root.appendingPathComponent("Cache")), key: Data(repeating: 42, count: 32))
        let service = InboxService(repository: repo)
        let replies = AssistantReplies(service: service, repository: repo, ownAddresses: { [] }, review: { _, _ in .demo }, directSend: { draft, _ in Issue.record("Repeated uncertain send"); return draft })
        let gateway = AssistantGateway(service: service, replies: replies) { _, _ in "synthetic" }
        await gateway.setGrant(h.grant)
        #expect(await gateway.call("send_email_now", arguments: args).structuredContent?.objectValue?["status"] == .string("uncertain"))
        try await repo.close(); try FileManager.default.removeItem(at: h.root)
    }

    @Test func demoAndPersonalDraftsNeverUseImmediateSender() async throws {
        let demo = try await ReplyHarness(), id = UUID()
        #expect(await demo.prepareEmail(id).isError != true)
        let draft = try await demo.repository.draft(id: id, account: demo.source.accountID)
        #expect(await demo.gateway.call("send_email_now", arguments: try demo.directArguments(draft)).isError == true)
        #expect(await demo.gateway.call("mail_status", arguments: [:]).structuredContent?.objectValue?["direct_send_account_ids"] == .array([]))
        #expect(await demo.directProbe.dispatches == 0); try await demo.close()
        let h = try await ReplyHarness(connected: true)
        let account = try #require(h.data.snapshot.accounts.first { $0.id == h.source.accountID })
        var personal = LocalDraft(accountID: account.id, sender: account.address.value)
        personal.to = "synthetic@example.invalid"; personal.body = "Private draft"
        personal = try await h.repository.saveDraft(personal, expectedRevision: 0)
        #expect(await h.gateway.call("send_email_now", arguments: try h.directArguments(personal)).isError == true)
        #expect(await h.directProbe.dispatches == 0); try await h.close()
    }
}
