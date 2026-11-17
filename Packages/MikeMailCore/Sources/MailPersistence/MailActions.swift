import Foundation
import GRDB
import MailApplication
import MailDomain

extension EncryptedMailRepository: MailActionStore {
    public func queuedMailActions(accounts: Set<AccountID>) throws -> [MailActionReceipt] {
        guard !accounts.isEmpty else { return [] }
        return try database.read { db in
            let placeholders = Array(repeating: "?", count: accounts.count).joined(separator: ",")
            return try Data.fetchAll(db, sql: "SELECT payload FROM mail_action_receipts WHERE account_id IN (\(placeholders)) ORDER BY updated_at", arguments: StatementArguments(accounts.map(\.description)))
                .map { try JSONDecoder().decode(MailActionReceipt.self, from: $0) }
                .filter { $0.isQueued && $0.queueDismissed != true && (!$0.finished || $0.needsAttention) }
        }
    }
    public func mailAction(id: UUID, account: AccountID) throws -> MailActionReceipt? {
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM mail_action_receipts WHERE id=? AND account_id=?", arguments: [id.uuidString, account.description]) else { return nil }
            return try JSONDecoder().decode(MailActionReceipt.self, from: data)
        }
    }
    public func saveMailAction(_ receipt: MailActionReceipt) throws {
        let data = try JSONEncoder().encode(receipt)
        try database.write { db in
            // UUIDs are global: a conflicting account/request can never replace an existing receipt.
            if let old = try Data.fetchOne(db, sql: "SELECT payload FROM mail_action_receipts WHERE id=?", arguments: [receipt.id.uuidString]) {
                guard try JSONDecoder().decode(MailActionReceipt.self, from: old).request == receipt.request else { throw MailFailure.invalidInput }
            }
            try db.execute(sql: """
                INSERT INTO mail_action_receipts(id,account_id,payload,updated_at) VALUES(?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,updated_at=excluded.updated_at
                """, arguments: [receipt.id.uuidString, receipt.request.accountID.description, data, Date().timeIntervalSince1970])
        }
        try protectFiles()
    }
}
