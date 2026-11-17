import Foundation
import GRDB
import MailDomain
import MailApplication

extension EncryptedMailRepository {
    /// Snapshot and claim are atomic with each other; failed provider sync never calls this.
    public func consumeInboxNotifications(account: AccountID, now: Date = Date()) throws -> InboxNotificationDelta? {
        let result = try database.write { db -> InboxNotificationDelta? in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM accounts WHERE id=? AND is_deleting=0)", arguments: [account.description]) == true
            else { throw MailFailure.notFound }
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.* FROM messages m WHERE m.account_id=? AND EXISTS(
                    SELECT 1 FROM message_locations l JOIN folders f ON f.id=l.folder_id AND f.account_id=l.account_id
                    WHERE l.message_id=m.id AND l.account_id=m.account_id AND f.role='inbox')
                ORDER BY m.received_us DESC,m.id LIMIT 1001
                """, arguments: [account.description])
            guard rows.count <= 1000 else { throw LocalStoreFailure.budgetExceeded }
            let messages = try rows.map { try IndexRecords.message($0, db: db) }
            let provider = try String.fetchOne(db, sql: "SELECT provider FROM accounts WHERE id=?", arguments: [account.description])
            let epoch: String
            if provider == "imap" {
                let folders = try Row.fetchAll(db, sql: """
                    SELECT f.id,s.uid_validity FROM folders f LEFT JOIN sync_states s ON s.folder_id=f.id AND s.account_id=f.account_id
                    WHERE f.account_id=? AND f.role='inbox' ORDER BY f.id
                    """, arguments: [account.description])
                epoch = "imap:" + folders.map { row in
                    let id: String = row["id"], validity: Int64? = row["uid_validity"]
                    return id + ":" + (validity.map(String.init) ?? "uninitialized")
                }.joined(separator: ",")
            } else if provider == "gmail" {
                let imported = try Bool.fetchOne(db, sql: "SELECT history_id IS NOT NULL FROM gmail_profiles WHERE account_id=?", arguments: [account.description]) ?? false
                epoch = imported ? "gmail:ready" : "gmail:uninitialized"
            } else { epoch = "synthetic" }
            guard epoch.utf8.count <= 8192 else { throw LocalStoreFailure.budgetExceeded }
            let saved = try Row.fetchOne(db, sql: "SELECT epoch,payload FROM desktop_notification_state WHERE account_id=?", arguments: [account.description])
            let payload: Data? = saved?["payload"]
            let previousEpoch: String? = saved?["epoch"]
            var ledger = try (previousEpoch == epoch ? payload : nil).map { try JSONDecoder().decode(InboxNotificationLedger.self, from: $0) } ?? InboxNotificationLedger(now: now)
            let delta = try ledger.consume(messages, now: now)
            let updated = try JSONEncoder().encode(ledger)
            guard updated.count <= 262144 else { throw LocalStoreFailure.budgetExceeded }
            try db.execute(sql: "INSERT INTO desktop_notification_state(account_id,epoch,payload) VALUES(?,?,?) ON CONFLICT(account_id) DO UPDATE SET epoch=excluded.epoch,payload=excluded.payload", arguments: [account.description, epoch, updated])
            return delta
        }
        try protectFiles()
        return result
    }
}
