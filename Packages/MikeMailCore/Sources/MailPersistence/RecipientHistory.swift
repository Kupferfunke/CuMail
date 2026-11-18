import Foundation
import GRDB
import MailApplication

enum RecipientUsage {
    static func recordIndexedMessage(_ id: String, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO recipient_usage(account_id,message_key,address,name,sent_at)
            SELECT m.account_id,CASE WHEN coalesce(m.internet_message_id,'')<>'' THEN 'mid:'||trim(m.internet_message_id) ELSE 'local:'||m.id END,
                lower(trim(r.address)),r.name,m.received_us/1000000.0
            FROM messages m JOIN accounts a ON a.id=m.account_id
            JOIN message_recipients r ON r.message_id=m.id AND r.account_id=m.account_id
            WHERE m.id=? AND a.is_deleting=0 AND lower(m.sender_address)=lower(a.address)
                AND EXISTS(SELECT 1 FROM message_locations l JOIN folders f ON f.id=l.folder_id AND f.account_id=l.account_id
                           WHERE l.message_id=m.id AND f.role='sent')
            ON CONFLICT(account_id,message_key,address) DO UPDATE SET
                name=CASE WHEN excluded.name<>'' THEN excluded.name ELSE recipient_usage.name END,
                sent_at=max(recipient_usage.sent_at,excluded.sent_at)
            """, arguments: [id])
    }
    static func recordAcceptedDraft(_ draft: LocalDraft, db: Database) throws {
        let key = draft.internetMessageID.map { "mid:" + $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "draft:" + draft.id.uuidString
        // Count each address once per accepted message, even across To/Cc/Bcc.
        let addresses = Set(try [draft.to, draft.cc, draft.bcc].flatMap { try ComposeValidation.addresses($0) }.map { $0.lowercased() })
        for address in addresses {
            try db.execute(sql: """
                INSERT INTO recipient_usage(account_id,message_key,address,name,sent_at) VALUES(?,?,?,'',?)
                ON CONFLICT(account_id,message_key,address) DO NOTHING
                """, arguments: [draft.accountID.description, key, address, draft.modifiedAt.timeIntervalSince1970])
        }
    }
}

extension EncryptedMailRepository: RecipientHistoryRepository {
    public func recipientHistory() throws -> [UsedRecipient] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT u.address, count(*) AS uses, max(u.sent_at) AS last_used,
                    coalesce((SELECT n.name FROM recipient_usage n JOIN accounts a ON a.id=n.account_id
                              WHERE n.address=u.address AND n.name<>'' AND a.is_deleting=0
                              ORDER BY n.sent_at DESC,n.name LIMIT 1),'') AS name
                FROM recipient_usage u JOIN accounts a ON a.id=u.account_id WHERE a.is_deleting=0
                GROUP BY u.address ORDER BY last_used DESC,uses DESC,u.address
                """).compactMap { row in
                    let address: String = row["address"], name: String = row["name"]
                    guard (try? ComposeValidation.address(address)) != nil else { return nil }
                    return UsedRecipient(address: address,
                        name: (try? ComposeValidation.header(name)) != nil ? String(name.prefix(200)) : "",
                        useCount: row["uses"], lastUsed: Date(timeIntervalSince1970: row["last_used"]))
                }
        }
    }
}
