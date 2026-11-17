import Foundation
import GRDB
import MailDomain
import MailApplication

extension EncryptedMailRepository: DraftRepository {
    private static func checkDraftAccount(_ db: Database, _ account: AccountID, sender: String? = nil) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT address FROM accounts WHERE id=? AND is_deleting=0", arguments: [account.description]) else { throw ComposeFailure.accountMismatch }
        if let sender, (row["address"] as String).caseInsensitiveCompare(sender) != .orderedSame { throw ComposeFailure.accountMismatch }
    }
    public func drafts(account: AccountID) throws -> [LocalDraft] {
        try database.read { db in
            try Self.checkDraftAccount(db, account)
            return try Data.fetchAll(db, sql: "SELECT payload FROM local_drafts WHERE account_id=? ORDER BY modified_at DESC LIMIT 100", arguments: [account.description])
                .map { try JSONDecoder().decode(LocalDraft.self, from: $0) }
        }
    }
    public func draft(id: UUID, account: AccountID) throws -> LocalDraft {
        try database.read { db in
            try Self.checkDraftAccount(db, account)
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM local_drafts WHERE id=? AND account_id=?", arguments: [id.uuidString, account.description]) else { throw ComposeFailure.unavailable }
            return try JSONDecoder().decode(LocalDraft.self, from: data)
        }
    }
    public func saveDraft(_ draft: LocalDraft, expectedRevision: Int) throws -> LocalDraft {
        try draft.validateStorage()
        return try database.write { db in
            try Self.checkDraftAccount(db, draft.accountID, sender: draft.sender)
            let existing = try Row.fetchOne(db, sql: "SELECT account_id,revision,payload FROM local_drafts WHERE id=?", arguments: [draft.id.uuidString])
            guard draft.revision == expectedRevision, (existing?["revision"] as Int? ?? 0) == expectedRevision,
                  existing == nil || existing?["account_id"] as String? == draft.accountID.description else { throw ComposeFailure.conflict }
            if let existing {
                let old = try JSONDecoder().decode(LocalDraft.self, from: existing["payload"] as Data)
                guard old.sender == draft.sender, old.assistantOrigin == draft.assistantOrigin,
                      old.sourceMessageID == draft.sourceMessageID,
                      Self.transitionAllowed(from: old.status, to: draft.status) else { throw ComposeFailure.locked }
                if !old.status.editable {
                    // Sending payloads are immutable; only state, receipt and purge may change.
                    guard draft.status == .sent || (old.to == draft.to && old.cc == draft.cc && old.bcc == draft.bcc && old.subject == draft.subject && old.body == draft.body && old.quotation == draft.quotation && old.signature == draft.signature && old.signatureID == draft.signatureID && old.signatureName == draft.signatureName && old.attachments == draft.attachments && old.internetMessageID == draft.internetMessageID && old.operationID == draft.operationID) else { throw ComposeFailure.locked }
                }
                if draft.status == .accepted || draft.status == .sent {
                    // The sent receipt purges recipients. Learn them atomically
                    // from the last full payload, only after provider acceptance.
                    try RecipientUsage.recordAcceptedDraft(old, db: db)
                }
            } else {
                guard draft.status == .editing, draft.operationID == nil else { throw ComposeFailure.locked }
            }
            var saved = draft; saved.revision += 1; saved.modifiedAt = Date()
            let payload = try JSONEncoder().encode(saved)
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM local_drafts WHERE id<>?", arguments: [draft.id.uuidString]) ?? 0
            let total = try Int.fetchOne(db, sql: "SELECT coalesce(sum(length(payload)),0) FROM local_drafts WHERE id<>?", arguments: [draft.id.uuidString]) ?? 0
            guard count < 100, payload.count <= 8_388_608, total + payload.count <= 10_485_760 else { throw ComposeFailure.tooLarge }
            try db.execute(sql: """
                INSERT INTO local_drafts(id,account_id,revision,status,modified_at,payload) VALUES(?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,status=excluded.status,modified_at=excluded.modified_at,payload=excluded.payload
                """, arguments: [saved.id.uuidString, saved.accountID.description, saved.revision, saved.status.rawValue, saved.modifiedAt.timeIntervalSince1970, payload])
            return saved
        }
    }
    private static func transitionAllowed(from old: DraftStatus, to new: DraftStatus) -> Bool {
        if old == new { return true }
        switch old {
        case .editing, .failed: return [.editing, .sending].contains(new)
        case .sending: return [.failed, .uncertain, .accepted].contains(new)
        case .accepted: return new == .sent
        case .uncertain: return new == .sent
        case .sent: return false
        }
    }
    public func discardDraft(id: UUID, account: AccountID, expectedRevision: Int) throws {
        try database.write { db in
            try Self.checkDraftAccount(db, account)
            guard let row = try Row.fetchOne(db, sql: "SELECT revision,status FROM local_drafts WHERE id=? AND account_id=?", arguments: [id.uuidString, account.description]), row["revision"] as Int == expectedRevision else { throw ComposeFailure.conflict }
            guard ["editing", "failed", "sent"].contains(row["status"] as String) else { throw ComposeFailure.locked }
            try db.execute(sql: "DELETE FROM local_drafts WHERE id=? AND account_id=?", arguments: [id.uuidString, account.description])
        }
    }
    public func recoverInterruptedSubmissions() throws {
        try database.write { db in
            for row in try Row.fetchAll(db, sql: "SELECT payload FROM local_drafts WHERE status='sending'") {
                var draft = try JSONDecoder().decode(LocalDraft.self, from: row["payload"] as Data)
                draft.status = .uncertain; draft.revision += 1
                try db.execute(sql: "UPDATE local_drafts SET status=?,revision=?,payload=? WHERE id=?", arguments: [draft.status.rawValue, draft.revision, try JSONEncoder().encode(draft), draft.id.uuidString])
            }
            // Only empty successful receipts expire; never silently remove unsent drafts.
            try db.execute(sql: "DELETE FROM local_drafts WHERE status='sent' AND modified_at<?", arguments: [Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970])
        }
    }
    public func smtpProfile(account: AccountID) throws -> SMTPProfile? {
        try database.read { db in
            try Self.checkDraftAccount(db, account)
            return try Data.fetchOne(db, sql: "SELECT payload FROM smtp_profiles WHERE account_id=?", arguments: [account.description])
                .map { try JSONDecoder().decode(SMTPProfile.self, from: $0) }
        }
    }
    public func saveSMTPProfile(_ profile: SMTPProfile) throws {
        try profile.validate()
        try database.write { db in
            try Self.checkDraftAccount(db, profile.accountID)
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM folders WHERE account_id=? AND provider_id=?)", arguments: [profile.accountID.description, profile.sentFolder]) == true else { throw ComposeFailure.accountMismatch }
            try db.execute(sql: "INSERT INTO smtp_profiles(account_id,payload) VALUES(?,?) ON CONFLICT(account_id) DO UPDATE SET payload=excluded.payload", arguments: [profile.accountID.description, try JSONEncoder().encode(profile)])
        }
    }
}
