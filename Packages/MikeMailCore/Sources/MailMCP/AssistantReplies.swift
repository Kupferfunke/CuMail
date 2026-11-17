import Foundation
import CryptoKit
import MailDomain
import MailApplication

public enum AssistantReplyReadiness: String, Sendable {
    case awaitingUserConfirmation = "awaiting_confirmation_in_mac_app"
    case demo = "demo_cannot_send"
    case smtpMissing = "smtp_setup_required_in_mac_app"
    case gmailReadOnly = "gmail_send_permission_required_in_mac_app"
}

/// Own local messages/replies and native review, with separate gateway grants.
/// No credentials, arbitrary drafts or automatic send queue. Direct sending is
/// delegated only after explicit intent, separate permission and exact binding.
public actor AssistantReplies {
    public typealias Authorization = @Sendable () async throws -> Void
    public typealias Review = @Sendable (LocalDraft, @escaping Authorization) async throws -> AssistantReplyReadiness
    public typealias DirectSend = @Sendable (LocalDraft, @escaping Authorization) async throws -> LocalDraft
    public typealias DirectAuthorization = @Sendable (LocalDraft) async throws -> Void
    private let service: InboxService
    private let repository: any DraftRepository
    private let ownAddresses: @Sendable () async -> Set<String>
    private let review: Review
    private let directSend: DirectSend?
    private var creating = Set<UUID>()
    private var sending = Set<UUID>()
    public var supportsDirectSend: Bool { directSend != nil }

    public init(service: InboxService, repository: any DraftRepository,
                ownAddresses: @escaping @Sendable () async -> Set<String>, review: @escaping Review, directSend: DirectSend? = nil) {
        self.service = service; self.repository = repository; self.ownAddresses = ownAddresses; self.review = review
        self.directSend = directSend
    }

    public func prepare(source: MessageID, requestID: UUID, body: String, replyAll: Bool,
                        scope: AccessScope, authorize: @escaping Authorization) async throws -> LocalDraft {
        try Self.validateBody(body)
        guard creating.insert(requestID).inserted else { throw ComposeFailure.locked }
        defer { creating.remove(requestID) }
        let message = try await service.getEmail(source, scope: scope)
        let accounts = try await service.accounts(scope: scope)
        guard scope.permits(message), let account = accounts.first(where: { $0.id == message.accountID }),
              account.provider != .microsoft else { throw MailFailure.permissionDenied }
        let payload = try JSONEncoder().encode([source.description, replyAll ? "reply_all" : "reply", body])
        let origin = AssistantReplyOrigin(messageID: source,
            requestDigest: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        // Existing requests survive process restarts and never overwrite human edits.
        let existing = try await repository.drafts(account: message.accountID).first { $0.id == requestID }
        try await authorize()
        if let existing {
            guard existing.assistantOrigin == origin else { throw ComposeFailure.conflict }
            return existing
        }
        guard account.status == .demo || message.threadingHeadersLoaded else { throw ComposeFailure.unavailable }
        var draft = try DraftBuilder.response(to: message, kind: replyAll ? .replyAll : .reply,
            sender: account.address.value, ownAddresses: await ownAddresses(), quote: "", id: requestID)
        draft.body = body; draft.assistantOrigin = origin
        draft.useSignature(try await repository.signatureLibrary(account: account.id).defaultSignature)
        // The account signature is snapshotted; no arbitrary recipient, Bcc or attachment is accepted.
        try draft.validateSubmission()
        _ = try await service.getEmail(source, scope: scope)
        try await authorize()
        return try await repository.saveDraft(draft, expectedRevision: 0)
    }

    public func prepareEmail(accountID: AccountID, requestID: UUID, to: [String], cc: [String] = [], bcc: [String] = [],
                             subject: String, body: String, scope: AccessScope,
                             authorize: @escaping Authorization) async throws -> LocalDraft {
        try Self.validateBody(body)
        guard !to.isEmpty, to.count + cc.count + bcc.count <= 100,
              !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, subject.utf8.count <= 512,
              !subject.unicodeScalars.contains(where: { (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }) else { throw MailFailure.invalidInput }
        try ComposeValidation.header(subject)
        for address in to + cc + bcc { try ComposeValidation.address(address) }
        guard creating.insert(requestID).inserted else { throw ComposeFailure.locked }
        defer { creating.remove(requestID) }
        let account = try await composeAccount(accountID, scope: scope)
        let payload = try JSONEncoder().encode([["new_email", accountID.description, subject, body], to, cc, bcc])
        let origin = AssistantDraftOrigin(accountID: accountID,
            requestDigest: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        let existing = try await repository.drafts(account: accountID).first { $0.id == requestID }
        try await authorize()
        if let existing {
            guard existing.assistantOrigin == origin else { throw ComposeFailure.conflict }
            return existing
        }
        var draft = LocalDraft(id: requestID, accountID: accountID, sender: account.address.value)
        draft.to = to.joined(separator: ", "); draft.cc = cc.joined(separator: ", "); draft.bcc = bcc.joined(separator: ", ")
        draft.subject = subject; draft.body = body; draft.assistantOrigin = origin
        draft.useSignature(try await repository.signatureLibrary(account: accountID).defaultSignature)
        try draft.validateSubmission()
        _ = try await composeAccount(accountID, scope: scope)
        try await authorize()
        return try await repository.saveDraft(draft, expectedRevision: 0)
    }

    public func getEmailDraft(accountID: AccountID, draftID: UUID, scope: AccessScope,
                              authorize: @escaping Authorization) async throws -> LocalDraft {
        _ = try await composeAccount(accountID, scope: scope)
        let draft = try await repository.draft(id: draftID, account: accountID)
        guard draft.assistantOrigin?.accountID == accountID, draft.assistantOrigin?.messageID == nil else { throw MailFailure.notFound }
        try await authorize()
        return draft
    }

    public func requestEmailSend(accountID: AccountID, draftID: UUID, expectedRevision: Int, scope: AccessScope,
                                 authorize: @escaping Authorization) async throws -> (LocalDraft, AssistantReplyReadiness?) {
        let draft = try await getEmailDraft(accountID: accountID, draftID: draftID, scope: scope, authorize: authorize)
        return try await requestReview(draft, expectedRevision: expectedRevision, authorize: authorize)
    }

    public func sendNow(accountID: AccountID, draftID: UUID, expectedRevision: Int, confirmationToken: String,
                        userRequestedSend: Bool, scope: AccessScope, authorize: @escaping DirectAuthorization) async throws -> LocalDraft {
        guard userRequestedSend else { throw MailFailure.permissionDenied }
        guard let directSend else { throw MailFailure.unsupported }
        guard sending.insert(draftID).inserted else { throw ComposeFailure.locked }
        defer { sending.remove(draftID) }
        let draft = try await repository.draft(id: draftID, account: accountID)
        try await validateDirectSource(draft, scope: scope)
        try await authorize(draft)
        // A replay reports the durable result. It never dispatches a second time.
        guard draft.status.editable else { return draft }
        guard draft.revision == expectedRevision, try draft.sendConfirmationToken() == confirmationToken else { throw ComposeFailure.conflict }
        guard draft.attachments.isEmpty else { throw ComposeFailure.attachmentUnavailable }
        try Self.validateBody(draft.body)
        try draft.validateSubmission()
        let reauthorize: Authorization = { [self] in
            try await validateDirectSource(draft, scope: scope)
            try await authorize(draft)
        }
        try await reauthorize()
        return try await directSend(draft, reauthorize)
    }

    private func validateDirectSource(_ draft: LocalDraft, scope: AccessScope) async throws {
        let account = try await composeAccount(draft.accountID, scope: scope)
        guard account.status != .demo, let origin = draft.assistantOrigin else { throw MailFailure.permissionDenied }
        if let source = origin.messageID {
            let message = try await service.getEmail(source, scope: scope)
            guard message.accountID == account.id, scope.permits(message) else { throw MailFailure.permissionDenied }
        } else {
            guard origin.accountID == account.id else { throw MailFailure.permissionDenied }
        }
    }

    private func composeAccount(_ id: AccountID, scope: AccessScope) async throws -> MailAccount {
        guard scope.accountIDs.contains(id),
              let account = try await service.accounts(scope: scope).first(where: { $0.id == id }),
              account.provider != .microsoft else { throw MailFailure.permissionDenied }
        return account
    }

    private static func validateBody(_ body: String) throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 6000,
              !body.unicodeScalars.contains(where: {
                  (CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t") ||
                  (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
              }) else { throw MailFailure.invalidInput }
    }

    public func get(source: MessageID, draftID: UUID, scope: AccessScope,
                    authorize: @escaping Authorization) async throws -> LocalDraft {
        let message = try await service.getEmail(source, scope: scope)
        guard scope.permits(message) else { throw MailFailure.permissionDenied }
        let draft = try await repository.draft(id: draftID, account: message.accountID)
        guard draft.assistantOrigin?.messageID == source else { throw MailFailure.notFound }
        try await authorize()
        return draft
    }

    public func requestSend(source: MessageID, draftID: UUID, expectedRevision: Int, scope: AccessScope,
                            authorize: @escaping Authorization) async throws -> (LocalDraft, AssistantReplyReadiness?) {
        let draft = try await get(source: source, draftID: draftID, scope: scope, authorize: authorize)
        return try await requestReview(draft, expectedRevision: expectedRevision, authorize: authorize)
    }

    private func requestReview(_ draft: LocalDraft, expectedRevision: Int,
                               authorize: @escaping Authorization) async throws -> (LocalDraft, AssistantReplyReadiness?) {
        // An accepted, uncertain or completed request is only reported, never retried.
        guard draft.status.editable else { return (draft, nil) }
        guard draft.revision == expectedRevision else { throw ComposeFailure.conflict }
        try draft.validateSubmission()
        try await authorize()
        let readiness = try await review(draft, authorize)
        return (draft, readiness)
    }
}
