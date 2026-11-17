import Foundation
import GRDB
import MailDomain
import MailApplication

extension EncryptedMailRepository: GmailDraftRepository {
    public func gmailDraftBinding(id: UUID, account: AccountID) throws -> GmailDraftBinding? {
        try database.read { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM local_drafts WHERE id=? AND account_id=?)", arguments: [id.uuidString, account.description]) == true else { throw MailFailure.notFound }
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM gmail_draft_bindings WHERE draft_id=? AND account_id=?", arguments: [id.uuidString, account.description]) else { return nil }
            let receipt: GmailDraftReceipt?
            if let remote: String = row["provider_id"], let version: String = row["provider_message_id"] { receipt = GmailDraftReceipt(id: remote, messageID: version) } else { receipt = nil }
            return GmailDraftBinding(receipt: receipt, revision: row["revision"], pending: row["pending"])
        }
    }
    public func setGmailDraftBinding(_ binding: GmailDraftBinding, id: UUID, account: AccountID) throws {
        if let receipt = binding.receipt {
            guard GmailIdentity.validID(receipt.id), GmailIdentity.validID(receipt.messageID) else { throw MailFailure.invalidInput }
        }
        try database.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM local_drafts d JOIN gmail_profiles p ON p.account_id=d.account_id WHERE d.id=? AND d.account_id=? AND d.revision=?)", arguments: [id.uuidString, account.description, binding.revision]) == true else { throw ComposeFailure.conflict }
            try db.execute(sql: """
                INSERT INTO gmail_draft_bindings(draft_id,account_id,provider_id,provider_message_id,revision,pending) VALUES(?,?,?,?,?,?)
                ON CONFLICT(draft_id) DO UPDATE SET provider_id=excluded.provider_id,provider_message_id=excluded.provider_message_id,revision=excluded.revision,pending=excluded.pending
                """, arguments: [id.uuidString, account.description, binding.receipt?.id, binding.receipt?.messageID, binding.revision, binding.pending])
        }
    }
}
