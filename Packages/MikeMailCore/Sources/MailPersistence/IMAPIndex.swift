import Foundation
import GRDB
import MailDomain
import MailApplication

extension EncryptedMailRepository: IMAPIndex {
    /// Local UI's owned accounts. External callers must still supply an explicit AccessScope.
    public func activeAccountIDs() throws -> Set<AccountID> {
        try database.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM accounts WHERE is_deleting=0").map { try AccountID(string: $0) })
        }
    }
    public func imapConfigurations() throws -> [IMAPConfiguration] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT p.* FROM imap_profiles p JOIN accounts a ON a.id=p.account_id WHERE a.is_deleting=0").map {
                guard let security = IMAPSecurity(rawValue: $0["tls"]) else { throw LocalStoreFailure.wrongKeyOrCorrupt }
                return try IMAPConfiguration(accountID: AccountID(string: $0["account_id"]), host: $0["host"],
                    port: $0["port"], security: security, username: $0["username"])
            }
        }
    }
    public func addIMAPAccount(_ account: MailAccount, configuration: IMAPConfiguration, folders: [MailFolder]) throws {
        guard account.provider == .imap, account.status == .connected, account.id == configuration.accountID,
              folders.count <= 500, folders.allSatisfy({ $0.accountID == account.id }) else { throw MailFailure.invalidInput }
        let snapshot = try MailSnapshot(accounts: [account], folders: folders, threads: [], messages: [])
        try database.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM accounts WHERE id=?)", arguments: [account.id.description]) == false else { throw MailFailure.invalidInput }
            try IndexWriter.upsert(snapshot, db: db)
            try db.execute(sql: "INSERT INTO imap_profiles(account_id,host,port,tls,username) VALUES(?,?,?,?,?)",
                arguments: [account.id.description, configuration.host, configuration.port, configuration.security.rawValue, configuration.username])
        }
        try protectFiles()
    }
    public func updateIMAPFolders(account: AccountID, folders: [MailFolder]) throws {
        guard folders.count <= 500, folders.allSatisfy({ $0.accountID == account }) else { throw MailFailure.invalidInput }
        try database.write { db in
            let local = try Self.imapAccount(db, id: account)
            let snapshot = try MailSnapshot(accounts: [local], folders: folders, threads: [], messages: [])
            let retained = Set(folders.map(\.id))
            let old = try Row.fetchAll(db, sql: "SELECT * FROM folders WHERE account_id=?", arguments: [account.description])
            for row in old {
                let folder = try IndexRecords.folder(row)
                if !retained.contains(folder.id) {
                    try db.execute(sql: "DELETE FROM messages WHERE id IN (SELECT message_id FROM provider_message_keys WHERE account_id=? AND mailbox=?)",
                        arguments: [account.description, folder.providerID])
                    try db.execute(sql: "DELETE FROM folders WHERE id=? AND account_id=?", arguments: [folder.id.description, account.description])
                }
            }
            try IndexWriter.upsert(snapshot, db: db)
            try db.execute(sql: "INSERT INTO app_state(key,value) VALUES('cleanup_pending','1') ON CONFLICT(key) DO UPDATE SET value='1'")
        }
        try finishMaintenance()
        try protectFiles()
    }
    public func imapCheckpoint(account: AccountID, folder: FolderID) throws -> IMAPCheckpoint? {
        try database.read { db in
            _ = try Self.imapAccount(db, id: account)
            guard let row = try Row.fetchOne(db, sql: "SELECT uid_validity FROM sync_states WHERE account_id=? AND folder_id=?",
                                            arguments: [account.description, folder.description]),
                  let raw: Int64 = row["uid_validity"], let validity = UInt32(exactly: raw), validity > 0 else { return nil }
            let uids = try Int64.fetchAll(db, sql: """
                SELECT k.uid FROM provider_message_keys k JOIN message_locations l ON l.message_id=k.message_id AND l.account_id=k.account_id
                JOIN messages m ON m.id=k.message_id AND m.account_id=k.account_id
                WHERE k.account_id=? AND l.folder_id=? AND k.uid_validity=? AND m.threading_headers_loaded=1
                """, arguments: [account.description, folder.description, Int64(validity)])
            return IMAPCheckpoint(uidValidity: validity, knownUIDs: Set(uids.compactMap(UInt32.init(exactly:))))
        }
    }
    public func applyIMAPBatch(_ batch: IMAPFolderBatch, account: MailAccount, folder: MailFolder) throws {
        guard folder.accountID == account.id,
              folder.id == (try IMAPIdentity.folder(account: account.id, mailbox: folder.providerID)) else { throw MailFailure.invalidInput }
        let snapshot = try MailSnapshot(accounts: [account], folders: [folder], threads: [], messages: batch.newMessages)
        let wanted = Set(batch.flags.map(\.uid))
        var incoming: Set<UInt32> = []
        for message in batch.newMessages {
            guard message.accountID == account.id, message.folderIDs == [folder.id], message.threadID == nil,
                  case .imap(let mailbox, let validity, let uid) = message.locator,
                  mailbox == folder.providerID, validity == batch.uidValidity, wanted.contains(uid),
                  incoming.insert(uid).inserted,
                  message.id == (try IMAPIdentity.message(account: account.id, mailbox: mailbox, validity: validity, uid: uid))
            else { throw MailFailure.invalidInput }
        }
        try database.write { db in
            _ = try Self.imapAccount(db, id: account.id)
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM folders WHERE id=? AND account_id=? AND provider_id=?)",
                arguments: [folder.id.description, account.id.description, folder.providerID]) == true else { throw MailFailure.notFound }
            let existing = try Row.fetchAll(db, sql: "SELECT k.message_id,k.uid,k.uid_validity,m.threading_headers_loaded FROM provider_message_keys k JOIN messages m ON m.id=k.message_id AND m.account_id=k.account_id WHERE k.account_id=? AND k.mailbox=?",
                arguments: [account.id.description, folder.providerID])
            var retained: Set<UInt32> = []
            var removed = false
            for row in existing {
                let uid = UInt32(row["uid"] as Int64)
                if row["uid_validity"] as Int64 == Int64(batch.uidValidity), wanted.contains(uid) {
                    if row["threading_headers_loaded"] as Bool { retained.insert(uid) }
                } else {
                    try db.execute(sql: "DELETE FROM messages WHERE id=? AND account_id=?", arguments: [row["message_id"] as String, account.id.description])
                    removed = true
                }
            }
            // Missing, duplicate or stale metadata must not advance the checkpoint.
            guard incoming == wanted.subtracting(retained) else { throw IMAPFailure.invalidResponse }
            try IndexWriter.upsert(snapshot, db: db)
            try rebuildIMAPThreads(account: account.id, db: db)
            for flags in batch.flags {
                try db.execute(sql: """
                    UPDATE messages SET unread=?,flagged=? WHERE account_id=? AND id IN
                    (SELECT message_id FROM provider_message_keys WHERE account_id=? AND mailbox=? AND uid_validity=? AND uid=?)
                    """, arguments: [flags.unread, flags.flagged, account.id.description, account.id.description,
                                     folder.providerID, Int64(batch.uidValidity), Int64(flags.uid)])
            }
            try db.execute(sql: """
                INSERT INTO sync_states(account_id,folder_id,uid_validity,last_success,coverage,server_count,indexed_count)
                VALUES(?,?,?,?,'latest200Metadata',?,?) ON CONFLICT(account_id,folder_id) DO UPDATE SET
                uid_validity=excluded.uid_validity,last_success=excluded.last_success,coverage=excluded.coverage,
                server_count=excluded.server_count,indexed_count=excluded.indexed_count,cursor=NULL,mod_seq=NULL
                """, arguments: [account.id.description, folder.id.description, Int64(batch.uidValidity),
                                 Date().timeIntervalSince1970, batch.totalOnServer, batch.flags.count])
            try db.execute(sql: "UPDATE accounts SET status='connected' WHERE id=?", arguments: [account.id.description])
            if removed { try db.execute(sql: "INSERT INTO app_state(key,value) VALUES('cleanup_pending','1') ON CONFLICT(key) DO UPDATE SET value='1'") }
        }
        try finishMaintenance()
        try protectFiles()
    }
    public func setConnectionStatus(_ status: AccountStatus, account: AccountID) throws {
        guard status != .demo else { throw MailFailure.invalidInput }
        try database.write { db in
            _ = try Self.imapAccount(db, id: account)
            try db.execute(sql: "UPDATE accounts SET status=? WHERE id=?", arguments: [status.rawValue, account.description])
        }
    }
    public func imapSummaries() throws -> [IMAPSyncSummary] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.* FROM sync_states s JOIN imap_profiles p ON p.account_id=s.account_id
                JOIN accounts a ON a.id=s.account_id WHERE a.is_deleting=0 AND s.indexed_count IS NOT NULL
                """).map {
                    IMAPSyncSummary(folderID: try FolderID(string: $0["folder_id"]), indexedCount: $0["indexed_count"],
                                    totalOnServer: $0["server_count"], lastSuccess: Date(timeIntervalSince1970: $0["last_success"]))
                }
        }
    }
    private static func imapAccount(_ db: Database, id: AccountID) throws -> MailAccount {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT a.* FROM accounts a JOIN imap_profiles p ON p.account_id=a.id WHERE a.id=? AND a.is_deleting=0
            """, arguments: [id.description]) else { throw MailFailure.notFound }
        return try IndexRecords.account(row)
    }
}
