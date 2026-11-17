import Foundation
import GRDB
import MailDomain
import MailApplication

extension EncryptedMailRepository {
    /// Completed extracts are checkpoints. A failed fetch cannot advance or remove other messages.
    public func nextContentIndexMessage(account: AccountID, now: Date = Date()) throws -> MailMessage? {
        try database.read { db in
            let settings = try IndexRecords.settings(db, account: account)
            guard settings.textIndexEnabled, settings.fullTextIndexEnabled else { return nil }
            guard let row = try Row.fetchOne(db, sql: """
                SELECT m.* FROM messages m
                LEFT JOIN message_text t ON t.message_id=m.id AND t.account_id=m.account_id
                LEFT JOIN text_index_attempts x ON x.message_id=m.id AND x.account_id=m.account_id
                WHERE m.account_id=? AND t.message_id IS NULL
                    AND (x.message_id IS NULL OR x.retry_at<=?)
                ORDER BY CASE WHEN x.message_id IS NULL THEN 0 ELSE 1 END,m.received_us DESC,m.id LIMIT 1
                """, arguments: [account.description, now.timeIntervalSince1970]) else { return nil }
            return try IndexRecords.message(row, db: db)
        }
    }
    public func recordContentIndexIssue(_ issue: ContentIndexIssue, message: MessageID, account: AccountID, now: Date = Date()) throws {
        try database.write { db in
            guard try IndexRecords.settings(db, account: account).fullTextIndexEnabled else { return }
            let attempts = (try Int.fetchOne(db, sql: "SELECT attempts FROM text_index_attempts WHERE message_id=? AND account_id=?", arguments: [message.description, account.description]) ?? 0) + 1
            let retry: Double? = issue == .unavailable ? now.timeIntervalSince1970 + min(21600, 60 * pow(2, Double(min(attempts - 1, 9)))) : nil
            try db.execute(sql: """
                INSERT INTO text_index_attempts(message_id,account_id,attempts,retry_at,reason) VALUES(?,?,?,?,?)
                ON CONFLICT(message_id) DO UPDATE SET attempts=excluded.attempts,retry_at=excluded.retry_at,reason=excluded.reason
                """, arguments: [message.description, account.description, attempts, retry, issue.rawValue])
        }
    }
    public func retryContentIndex(account: AccountID) throws {
        try database.write { db in
            _ = try IndexRecords.settings(db, account: account)
            try db.execute(sql: "DELETE FROM text_index_attempts WHERE account_id=?", arguments: [account.description])
        }
    }
    public func contentIndexProgress(account: AccountID) throws -> ContentIndexProgress {
        try database.read { db in
            let settings = try IndexRecords.settings(db, account: account)
            let row = try Row.fetchOne(db, sql: """
                SELECT count(*) total,count(t.message_id) indexed_count,COALESCE(sum(t.truncated),0) truncated,
                    COALESCE(sum(t.utf8_bytes),0) bytes,
                    COALESCE(sum(CASE WHEN t.message_id IS NULL AND x.message_id IS NOT NULL AND x.retry_at IS NULL THEN 1 ELSE 0 END),0) skipped,
                    COALESCE(sum(CASE WHEN t.message_id IS NULL AND x.retry_at IS NOT NULL THEN 1 ELSE 0 END),0) retrying
                FROM messages m LEFT JOIN message_text t ON t.message_id=m.id AND t.account_id=m.account_id
                LEFT JOIN text_index_attempts x ON x.message_id=m.id AND x.account_id=m.account_id WHERE m.account_id=?
                """, arguments: [account.description])!
            return ContentIndexProgress(accountID: account, enabled: settings.fullTextIndexEnabled,
                total: row["total"], indexed: row["indexed_count"], truncated: row["truncated"], skipped: row["skipped"],
                retrying: row["retrying"], bytes: row["bytes"], budget: settings.accountTextBudget)
        }
    }
}
