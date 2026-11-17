import Foundation
import MailDomain

/// No scheduler or automatic retry. Every call originates from an explicit user
/// action, persists intent first, and treats process death as ambiguous acceptance.
public actor SubmissionService {
    private let repository: any DraftRepository
    private let credentials: any CredentialStore
    private let smtp: SMTPFactory
    private let sent: SentCopyFactory
    private var active = Set<AccountID>()
    public init(repository: any DraftRepository, credentials: any CredentialStore, smtp: @escaping SMTPFactory, sent: @escaping SentCopyFactory) {
        self.repository = repository; self.credentials = credentials; self.smtp = smtp; self.sent = sent
    }
    public func configure(_ profile: SMTPProfile, password: String?, reuseIncoming: Bool) async throws {
        guard active.insert(profile.accountID).inserted else { throw ComposeFailure.locked }
        defer { active.remove(profile.accountID) }
        try profile.validate()
        let secret: String
        if reuseIncoming { secret = try await credential(profile.accountID, purpose: .incomingPassword) }
        else if let password, !password.isEmpty { secret = password }
        else {
            guard let old = try await repository.smtpProfile(account: profile.accountID),
                  old.host == profile.host, old.port == profile.port, old.security == profile.security, old.username == profile.username else { throw ComposeFailure.missingCredential }
            secret = try await credential(profile.accountID, purpose: .outgoingPassword)
        }
        let session = smtp(profile, secret)
        do {
            try await session.connect()
            await session.disconnect()
            // Settings contain no secret. Never probe a changed host with an old
            // SMTP credential unless the user deliberately chose to reuse it.
            try await credentials.save(Data(secret.utf8), for: CredentialReference(accountID: profile.accountID, purpose: .outgoingPassword))
            try await repository.saveSMTPProfile(profile)
        } catch { await session.disconnect(); throw error }
    }
    public func send(id: UUID, account: AccountID, expectedRevision: Int, attachments: [OutgoingAttachment], imap: IMAPConfiguration,
                     authorize: @escaping @Sendable () async throws -> Void = {}) async throws -> LocalDraft {
        guard imap.accountID == account else { throw ComposeFailure.accountMismatch }
        guard active.insert(account).inserted else { throw ComposeFailure.locked }
        defer { active.remove(account) }
        var draft = try await repository.draft(id: id, account: account)
        guard draft.status.editable, draft.revision == expectedRevision else { throw ComposeFailure.locked }
        guard let profile = try await repository.smtpProfile(account: account) else { throw ComposeFailure.missingConfiguration }
        try profile.validate(); try draft.validateSubmission()
        guard attachments.map(\.reference) == draft.attachments else { throw ComposeFailure.attachmentChanged }
        try await authorize()
        let session = smtp(profile, try await credential(account, purpose: .outgoingPassword))
        let operation = UUID()
        draft.operationID = operation
        draft.internetMessageID = "<\(operation.uuidString.lowercased())@\(draft.sender.split(separator: "@").last!)>"
        let prepared: PreparedSubmission
        do {
            try await session.connect()
            prepared = try await session.prepare(draft, attachments: attachments)
            try await authorize()
            try Task.checkCancellation()
            draft.status = .sending; draft.appendAttempted = false
            draft = try await repository.saveDraft(draft, expectedRevision: draft.revision)
        } catch { await session.disconnect(); throw error }
        // Recheck after the durable CAS as well. A revoked/cancelled request at
        // this point is proven not dispatched; SMTP submit has not been called.
        do { try await authorize(); try Task.checkCancellation() }
        catch {
            draft.status = .failed
            _ = try? await repository.saveDraft(draft, expectedRevision: draft.revision)
            await session.disconnect(); throw error
        }
        do {
            try await session.submit(prepared)
        } catch {
            // Adapter maps proven failures to rejected/connection; everything
            // unclassified after dispatch must remain uncertain.
            draft.status = (error as? ComposeFailure) == .rejected ? .failed : .uncertain
            let saved = try? await repository.saveDraft(draft, expectedRevision: draft.revision)
            await session.disconnect()
            if let saved { return saved }
            throw ComposeFailure.uncertain
        }
        await session.disconnect()
        draft.status = .accepted
        // A failed durable write leaves 'sending'; recovery will be conservative.
        draft = try await repository.saveDraft(draft, expectedRevision: draft.revision)
        return await finishSent(draft, profile: profile, imap: imap, raw: prepared.rawMessage)
    }
    public func reconcile(id: UUID, account: AccountID, imap: IMAPConfiguration) async throws -> LocalDraft {
        guard imap.accountID == account, active.insert(account).inserted else { throw ComposeFailure.locked }
        defer { active.remove(account) }
        let draft = try await repository.draft(id: id, account: account)
        guard [.uncertain, .accepted].contains(draft.status), let profile = try await repository.smtpProfile(account: account) else { throw ComposeFailure.locked }
        // Read-only reconciliation. An absent copy never proves non-acceptance.
        return await finishSent(draft, profile: profile, imap: imap, raw: nil)
    }
    /// Explicit recovery after acceptance but before any APPEND attempt. It can
    /// create a missing Sent copy only; it has no SMTP submission call.
    public func completeSentCopy(id: UUID, account: AccountID, imap: IMAPConfiguration, attachments: [OutgoingAttachment]) async throws -> LocalDraft {
        guard imap.accountID == account, active.insert(account).inserted else { throw ComposeFailure.locked }
        defer { active.remove(account) }
        let draft = try await repository.draft(id: id, account: account)
        guard draft.status == .accepted, !draft.appendAttempted,
              let profile = try await repository.smtpProfile(account: account), profile.sentPolicy == .appendToFolder else { throw ComposeFailure.locked }
        // MIME generation needs no network connection or SMTP credentials.
        let encoder = smtp(profile, "")
        let prepared = try await encoder.prepare(draft, attachments: attachments)
        return await finishSent(draft, profile: profile, imap: imap, raw: prepared.rawMessage)
    }
    private func finishSent(_ input: LocalDraft, profile: SMTPProfile, imap: IMAPConfiguration, raw: String?) async -> LocalDraft {
        var draft = input
        guard let messageID = draft.internetMessageID else { return draft }
        var session: (any SentCopySession)?
        do {
            let connection = sent(imap, try await credential(draft.accountID, purpose: .incomingPassword)); session = connection
            try await connection.connect()
            var exists = try await connection.contains(messageID: messageID, folder: profile.sentFolder)
            if !exists, draft.status == .accepted, profile.sentPolicy == .appendToFolder, !draft.appendAttempted, let raw {
                draft.appendAttempted = true
                draft = try await repository.saveDraft(draft, expectedRevision: draft.revision)
                try await connection.append(raw, folder: profile.sentFolder)
                exists = try await connection.contains(messageID: messageID, folder: profile.sentFolder)
            }
            if exists {
                draft.status = .sent; draft.purgeContent()
                draft = try await repository.saveDraft(draft, expectedRevision: draft.revision)
            }
            await connection.disconnect()
        } catch { await session?.disconnect() }
        return draft
    }
    private func credential(_ account: AccountID, purpose: CredentialReference.Purpose) async throws -> String {
        guard var bytes = try await credentials.read(CredentialReference(accountID: account, purpose: purpose)) else { throw ComposeFailure.missingCredential }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        guard let value = String(data: bytes, encoding: .utf8), !value.isEmpty else { throw ComposeFailure.missingCredential }
        return value
    }
}
