import Foundation
import GRDB
import MailDomain
import MailApplication
import MailSecurity

extension EncryptedMailRepository {
    public func upsert(_ snapshot: MailSnapshot, checkpoint: LocalSyncCheckpoint? = nil) throws {
        do {
            try database.write { db in
                try IndexWriter.upsert(snapshot, db: db, checkpoint: checkpoint)
            }
            try protectFiles()
        } catch let error as DatabaseError {
            if error.resultCode == .SQLITE_CONSTRAINT { throw LocalStoreFailure.invalidInput }
            throw LocalStoreFailure.unavailable
        }
    }
    public func seedIfNeeded(_ snapshot: MailSnapshot) throws {
        try database.write { db in
            guard try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key='synthetic_seeded'") == nil else { return }
            try IndexWriter.upsert(snapshot, db: db)
            try db.execute(sql: "INSERT INTO app_state(key,value) VALUES('synthetic_seeded','1')")
        }
        try protectFiles()
    }
    public func settings(for account: AccountID) throws -> AccountSettings {
        try database.read { try IndexRecords.settings($0, account: account) }
    }
    public func saveSettings(_ settings: AccountSettings) throws {
        try settings.validate()
        try database.write { db in
            _ = try IndexRecords.settings(db, account: settings.accountID)
            try db.execute(sql: "UPDATE accounts SET name=? WHERE id=?", arguments: [settings.displayName, settings.accountID.description])
            try db.execute(sql: "UPDATE account_settings SET text_index_enabled=?,message_text_limit=?,account_text_budget=?,server_actions_enabled=?,full_text_index_enabled=?,mark_read_seconds=? WHERE account_id=?",
                           arguments: [settings.textIndexEnabled, settings.messageTextLimit, settings.accountTextBudget, settings.serverActionsEnabled, settings.fullTextIndexEnabled, settings.markReadAfterSeconds, settings.accountID.description])
            if !settings.textIndexEnabled {
                try db.execute(sql: "DELETE FROM text_index_attempts WHERE account_id=?", arguments: [settings.accountID.description])
                try db.execute(sql: "DELETE FROM message_text WHERE account_id=?", arguments: [settings.accountID.description])
            } else {
                try db.execute(sql: "DELETE FROM message_text WHERE account_id=? AND utf8_bytes>?", arguments: [settings.accountID.description, settings.messageTextLimit])
                var bytes = try Int.fetchOne(db, sql: "SELECT COALESCE(sum(utf8_bytes),0) FROM message_text WHERE account_id=?", arguments: [settings.accountID.description]) ?? 0
                let oldest = try Row.fetchAll(db, sql: "SELECT message_id,utf8_bytes FROM message_text WHERE account_id=? ORDER BY indexed_at,message_id", arguments: [settings.accountID.description])
                for row in oldest where bytes > settings.accountTextBudget {
                    try db.execute(sql: "DELETE FROM message_text WHERE message_id=? AND account_id=?", arguments: [row["message_id"] as String, settings.accountID.description])
                    bytes -= row["utf8_bytes"] as Int
                }
            }
            try markCleanup(db)
        }
        try finishMaintenance()
        RedactedLog.record(.settingsSaved)
    }

    /// Sanitized/plain text from an explicit display or an enabled background text scan.
    public func storeExtract(_ text: String, for message: MessageID, account: AccountID, indexedAt: Date = Date(), source: TextExtractionSource = .plainText) throws {
        guard text.utf8.count <= 10 * 1024 * 1024, !text.contains("\0"), indexedAt.timeIntervalSince1970.isFinite else { throw LocalStoreFailure.invalidInput }
        try database.write { db in
            let settings = try IndexRecords.settings(db, account: account)
            guard settings.textIndexEnabled else { throw LocalStoreFailure.textIndexDisabled }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE id=? AND account_id=?)", arguments: [message.description, account.description]) == true
            else { throw MailFailure.notFound }
            let original = Data(text.utf8)
            var bytes = Data(original.prefix(settings.messageTextLimit))
            while String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
            let bounded = String(data: bytes, encoding: .utf8)!
            let others = try Int.fetchOne(db, sql: "SELECT COALESCE(sum(utf8_bytes),0) FROM message_text WHERE account_id=? AND message_id<>?", arguments: [account.description, message.description]) ?? 0
            guard bytes.count <= settings.accountTextBudget - others else { throw LocalStoreFailure.budgetExceeded }
            try db.execute(sql: """
                INSERT INTO message_text(message_id,account_id,text,source,extraction_version,indexed_at,utf8_bytes,original_bytes,truncated,input_format)
                VALUES(?,?,?,'plainTextOnOpen',?,?, ?,?,?,?) ON CONFLICT(message_id) DO UPDATE SET
                text=excluded.text,indexed_at=excluded.indexed_at,utf8_bytes=excluded.utf8_bytes,original_bytes=excluded.original_bytes,
                truncated=excluded.truncated,input_format=excluded.input_format,extraction_version=excluded.extraction_version
                """, arguments: [message.description, account.description, bounded, source == .sanitizedHTML ? 2 : 1,
                                 indexedAt.timeIntervalSince1970, bytes.count, original.count, bytes.count < original.count, source.rawValue])
            try db.execute(sql: "DELETE FROM text_index_attempts WHERE message_id=? AND account_id=?", arguments: [message.description, account.description])
            try IndexRecords.refreshSearch(db, message: message.description)
        }
        try protectFiles()
    }
    public func extractedText(for message: MessageID, account: AccountID) throws -> String? {
        try storedExtract(for: message, account: account)?.text
    }
    public func storedExtract(for message: MessageID, account: AccountID) throws -> StoredTextExtract? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT t.* FROM message_text t JOIN accounts a ON a.id=t.account_id
                WHERE t.message_id=? AND t.account_id=? AND a.is_deleting=0
                """, arguments: [message.description, account.description]) else { return nil }
            return StoredTextExtract(text: row["text"], source: TextExtractionSource(rawValue: row["input_format"]) ?? .legacyUnknown,
                version: row["extraction_version"], indexedAt: Date(timeIntervalSince1970: row["indexed_at"]),
                byteCount: row["utf8_bytes"], originalByteCount: row["original_bytes"], truncated: row["truncated"])
        }
    }
    public func clearExtracts(account: AccountID) throws {
        try database.write { db in
            _ = try IndexRecords.settings(db, account: account)
            try db.execute(sql: "DELETE FROM message_text WHERE account_id=?", arguments: [account.description])
            try db.execute(sql: "DELETE FROM text_index_attempts WHERE account_id=?", arguments: [account.description])
            try db.execute(sql: "UPDATE account_settings SET full_text_index_enabled=0 WHERE account_id=?", arguments: [account.description])
            try markCleanup(db)
        }
        try finishMaintenance()
    }
    public func syncCursor(account: AccountID, folder: FolderID) throws -> String? {
        try database.read {
            try String.fetchOne($0, sql: "SELECT s.cursor FROM sync_states s JOIN accounts a ON a.id=s.account_id WHERE s.account_id=? AND s.folder_id=? AND a.is_deleting=0",
                                arguments: [account.description, folder.description])
        }
    }

    /// Removes only explicitly synthetic accounts. Real accounts and drafts are untouched.
    public func removeDevelopmentFixtures() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM accounts WHERE status='demo'")
            if db.changesCount > 0 { try markCleanup(db) }
        }
        try finishMaintenance()
    }

    func markAccountForRemoval(_ account: AccountID) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE accounts SET is_deleting=1 WHERE id=?", arguments: [account.description])
            try markCleanup(db)
        }
    }
    func pendingAccountRemovals() throws -> [AccountID] {
        try database.read { try String.fetchAll($0, sql: "SELECT id FROM accounts WHERE is_deleting=1").map { try AccountID(string: $0) } }
    }
    func markAllAccountsForRemoval() throws {
        try database.write { db in
            try db.execute(sql: "UPDATE accounts SET is_deleting=1")
            try markCleanup(db)
        }
    }
    func allAccountIDsIncludingPending() throws -> [AccountID] {
        try database.read { try String.fetchAll($0, sql: "SELECT id FROM accounts ORDER BY id").map { try AccountID(string: $0) } }
    }
    func finishAccountRemoval(_ account: AccountID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM accounts WHERE id=? AND is_deleting=1", arguments: [account.description])
            try markCleanup(db)
        }
        try finishMaintenance()
    }
    func replaceMetadata(with snapshot: MailSnapshot) throws {
        try database.write { db in
            // Retain account preferences and credentials. The caller supplies only still-existing accounts.
            try db.execute(sql: """
                DELETE FROM messages; DELETE FROM threads; DELETE FROM sync_states;
                DELETE FROM desktop_notification_state; DELETE FROM full_mail_scans;
                DELETE FROM folders WHERE account_id NOT IN (SELECT account_id FROM imap_profiles UNION SELECT account_id FROM gmail_profiles);
                UPDATE gmail_profiles SET history_id=NULL,pending_action=0,full_metadata=0;
                """)
            try IndexWriter.upsert(snapshot, db: db)
            try db.execute(sql: "INSERT INTO app_state(key,value) VALUES('synthetic_seeded','1') ON CONFLICT(key) DO UPDATE SET value='1'")
            try markCleanup(db)
        }
        try finishMaintenance()
    }
    func restoreSyntheticData(_ snapshot: MailSnapshot) throws {
        try database.write { db in
            try IndexWriter.upsert(snapshot, db: db)
            try db.execute(sql: "INSERT INTO app_state(key,value) VALUES('synthetic_seeded','1') ON CONFLICT(key) DO UPDATE SET value='1'")
            try markCleanup(db)
        }
        try finishMaintenance()
    }
    private nonisolated func markCleanup(_ db: Database) throws {
        try db.execute(sql: "INSERT INTO app_state(key,value) VALUES('cleanup_pending','1') ON CONFLICT(key) DO UPDATE SET value='1'")
    }
    func finishMaintenance() throws {
        let pending = try database.read { try String.fetchOne($0, sql: "SELECT value FROM app_state WHERE key='cleanup_pending'") != nil }
        guard pending else { return }
        do {
            try IndexDatabase.purgeMigrationBackups(paths)
            try database.writeWithoutTransaction { db in
                try db.execute(sql: "INSERT INTO search_index(search_index) VALUES('optimize'); VACUUM;")
                _ = try Row.fetchAll(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
            try database.write { try $0.execute(sql: "DELETE FROM app_state WHERE key='cleanup_pending'") }
            try database.writeWithoutTransaction { _ = try Row.fetchAll($0, sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
            try protectFiles()
        } catch { throw LocalStoreFailure.cleanupPending }
    }
    func protectFiles() throws {
        for file in PrivateFiles.databaseFiles(paths.database) { try PrivateFiles.protect(file) }
    }
    public func summary(temporaryBytes: Int64 = 0) throws -> LocalIndexSummary {
        let diskBytes = PrivateFiles.databaseFiles(paths.database).reduce(Int64(0)) { $0 + PrivateFiles.size($1) }
        return try database.read { db in
            let accounts = try Int.fetchOne(db, sql: "SELECT count(*) FROM accounts WHERE is_deleting=0") ?? 0
            let messages = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages m JOIN accounts a ON a.id=m.account_id WHERE a.is_deleting=0") ?? 0
            let texts = try Row.fetchOne(db, sql: "SELECT count(*) n,COALESCE(sum(utf8_bytes),0) bytes FROM message_text t JOIN accounts a ON a.id=t.account_id WHERE a.is_deleting=0")!
            return LocalIndexSummary(accountCount: accounts, messageCount: messages, indexedTextCount: texts["n"],
                extractBytes: texts["bytes"], databaseBytes: diskBytes, temporaryBytes: temporaryBytes,
                schemaVersion: try IndexSchema.verify(db), cipherVersion: try String.fetchOne(db, sql: "PRAGMA cipher_version") ?? "unknown")
        }
    }
}
