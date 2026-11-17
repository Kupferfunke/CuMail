import Foundation
import MailDomain
import MailApplication
import MailIMAP

public actor GmailSubmission {
    private let repository: any GmailDraftRepository
    private let index: any GmailIndex
    private let factory: GmailFactory
    private var active: Set<AccountID> = []
    public init(repository: any GmailDraftRepository, index: any GmailIndex, factory: @escaping GmailFactory) {
        self.repository = repository; self.index = index; self.factory = factory
    }
    public func review(account: AccountID) async throws {
        _ = try await configuration(account)
    }
    public func saveAtGoogle(id: UUID, account: AccountID, expectedRevision: Int, attachments: [OutgoingAttachment]) async throws -> LocalDraft {
        guard active.insert(account).inserted else { throw ComposeFailure.locked }
        defer { active.remove(account) }
        let config = try await configuration(account), api = factory(config)
        var draft = try await repository.draft(id: id, account: account)
        guard draft.status.editable, draft.revision == expectedRevision else { throw ComposeFailure.conflict }
        try await verifySender(draft, api: api)
        draft = try await assignIdentity(draft)
        let binding = try await resolvedBinding(draft, api: api)
        let raw = try SwiftMailMIMEEncoder.prepare(draft, attachments: attachments, includeBcc: true, requireRecipients: false).rawMessage
        try await repository.setGmailDraftBinding(GmailDraftBinding(receipt: binding?.receipt, revision: draft.revision, pending: true), id: id, account: account)
        // This request is sent once. An interrupted create/update remains pending until read-back.
        let receipt = try await api.saveDraft(raw: Data(raw.utf8), draftID: binding?.receipt?.id)
        try await repository.setGmailDraftBinding(GmailDraftBinding(receipt: receipt, revision: draft.revision, pending: false), id: id, account: account)
        return draft
    }
    public func send(id: UUID, account: AccountID, expectedRevision: Int, attachments: [OutgoingAttachment],
                     authorize: @escaping @Sendable () async throws -> Void = {}) async throws -> LocalDraft {
        guard active.insert(account).inserted else { throw ComposeFailure.locked }
        defer { active.remove(account) }
        let api = factory(try await configuration(account))
        var draft = try await repository.draft(id: id, account: account)
        guard draft.status.editable, draft.revision == expectedRevision else { throw ComposeFailure.conflict }
        try draft.validateSubmission(); try await authorize(); try await verifySender(draft, api: api)
        draft = try await assignIdentity(draft)
        let binding = try await resolvedBinding(draft, api: api)
        let raw = try SwiftMailMIMEEncoder.prepare(draft, attachments: attachments, includeBcc: true).rawMessage
        try await authorize()
        try Task.checkCancellation()
        draft.operationID = UUID(); draft.status = .sending; draft.appendAttempted = true
        draft = try await repository.saveDraft(draft, expectedRevision: draft.revision)
        do { try await authorize(); try Task.checkCancellation() }
        catch {
            draft.status = .failed
            _ = try? await repository.saveDraft(draft, expectedRevision: draft.revision)
            throw error
        }
        do { _ = try await api.send(raw: Data(raw.utf8), draftID: binding?.receipt?.id) }
        catch {
            draft.status = (error as? ComposeFailure) == .rejected ? .failed : .uncertain
            return try await repository.saveDraft(draft, expectedRevision: draft.revision)
        }
        draft.status = .accepted
        draft = try await repository.saveDraft(draft, expectedRevision: draft.revision)
        return try await confirmSent(draft, api: api)
    }
    public func reconcile(id: UUID, account: AccountID) async throws -> LocalDraft {
        guard active.insert(account).inserted else { throw ComposeFailure.locked }
        defer { active.remove(account) }
        let draft = try await repository.draft(id: id, account: account)
        guard [.uncertain, .accepted].contains(draft.status) else { throw ComposeFailure.locked }
        let api = factory(try await configuration(account))
        try await verifySender(draft, api: api)
        return try await confirmSent(draft, api: api)
    }
    private func configuration(_ account: AccountID) async throws -> GmailConfiguration {
        guard let config = try await index.gmailConfigurations().first(where: { $0.accountID == account }) else { throw ComposeFailure.missingConfiguration }
        guard config.permission == .manageMail else { throw GmailFailure.insufficientScope }
        return config
    }
    private func verifySender(_ draft: LocalDraft, api: any GmailAPI) async throws {
        guard try await api.profile().email.caseInsensitiveCompare(draft.sender) == .orderedSame else { throw ComposeFailure.accountMismatch }
    }
    private func assignIdentity(_ input: LocalDraft) async throws -> LocalDraft {
        var draft = input
        if draft.internetMessageID == nil {
            draft.internetMessageID = "<\(draft.id.uuidString.lowercased())@mikemailhub.local>"
            draft = try await repository.saveDraft(draft, expectedRevision: draft.revision)
        }
        return draft
    }
    private func resolvedBinding(_ draft: LocalDraft, api: any GmailAPI) async throws -> GmailDraftBinding? {
        guard let binding = try await repository.gmailDraftBinding(id: draft.id, account: draft.accountID) else { return nil }
        if binding.pending {
            guard let internetID = draft.internetMessageID, let receipt = try await api.findDraft(internetMessageID: internetID) else { throw GmailFailure.pendingAction }
            // Never silently retry an ambiguous write. Read-back unlocks an explicit later action only.
            try await repository.setGmailDraftBinding(GmailDraftBinding(receipt: receipt, revision: draft.revision, pending: false), id: draft.id, account: draft.accountID)
            throw GmailFailure.pendingAction
        }
        if let receipt = binding.receipt {
            guard try await api.draftVersion(id: receipt.id) == receipt else { throw ComposeFailure.conflict }
        }
        return binding
    }
    private func confirmSent(_ input: LocalDraft, api: any GmailAPI) async throws -> LocalDraft {
        guard let internetID = input.internetMessageID else { throw ComposeFailure.invalidHeader }
        var draft = input
        do {
            let queryID = internetID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            let ids = try await api.messageIDs(label: "SENT", limit: 20, query: "rfc822msgid:" + queryID)
            let folders = try await api.folders()
            for id in ids {
                let (message, _) = try await api.metadata(id: id, folders: folders)
                if message.internetMessageID == internetID, message.sender.address.value.caseInsensitiveCompare(draft.sender) == .orderedSame {
                    draft.status = .sent; draft.purgeContent()
                    return try await repository.saveDraft(draft, expectedRevision: draft.revision)
                }
            }
        } catch { return draft }
        return draft
    }
}
