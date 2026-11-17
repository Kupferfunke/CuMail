import Foundation
import GRDB
import MailDomain
import MailApplication

extension EncryptedMailRepository: FullMailIndex {
    public func fullMailScan(account: AccountID, scope: String, anchor: String?) throws -> FullMailScan {
        guard scope == "gmail" || (try? FolderID(string: scope)) != nil else { throw MailFailure.invalidInput }
        return try database.write { db in
            try Self.requireRealAccount(account, db: db)
            // Old pagination tokens may have expired. Keep all indexed mail while restarting.
            try db.execute(sql: "DELETE FROM full_mail_scans WHERE account_id=? AND scope=? AND started_at<?",
                           arguments: [account.description, scope, Date().addingTimeInterval(-86400).timeIntervalSince1970])
            try db.execute(sql: "INSERT OR IGNORE INTO full_mail_scans(account_id,scope,generation,anchor,started_at) VALUES(?,?,?,?,?)",
                           arguments: [account.description, scope, UUID().uuidString, anchor, Date().timeIntervalSince1970])
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM full_mail_scans WHERE account_id=? AND scope=?", arguments: [account.description, scope]) else { throw MailFailure.notFound }
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM full_mail_seen WHERE account_id=? AND scope=?", arguments: [account.description, scope]) ?? 0
            return FullMailScan(accountID: account, scope: scope, generation: row["generation"], cursor: row["cursor"], anchor: row["anchor"], indexedCount: count)
        }
    }
    public func resetFullMailScan(account: AccountID, scope: String) throws {
        try database.write { db in
            try Self.requireRealAccount(account, db: db)
            try db.execute(sql: "DELETE FROM full_mail_scans WHERE account_id=? AND scope=?", arguments: [account.description, scope])
        }
    }
    public func applyFullMailPage(_ scan: FullMailScan, account: MailAccount, folders: [MailFolder],
                                 messages: [MailMessage], providerThreads: [ThreadID: String],
                                 nextCursor: String?, uidValidity: UInt32?, serverCount: Int?, flags: [IMAPFlags]? = nil) throws -> Int {
        guard scan.accountID == account.id, (nextCursor?.utf8.count ?? 0) <= 4096,
              nextCursor == nil || nextCursor != scan.cursor, messages.count <= 100,
              serverCount.map({ $0 >= 0 }) ?? true else { throw MailFailure.invalidInput }
        let isGmail = scan.scope == "gmail"
        guard isGmail ? account.provider == .gmail : account.provider == .imap else { throw MailFailure.permissionDenied }
        if !isGmail {
            guard let folder = folders.first, folders.count == 1, folder.id.description == scan.scope,
                  let validity = uidValidity, validity > 0,
                  messages.allSatisfy({ message in
                      guard case .imap(let mailbox, let value, _) = message.locator else { return false }
                      return mailbox == folder.providerID && value == validity && message.folderIDs == [folder.id]
                  }) else { throw MailFailure.invalidInput }
        }
        let snapshot = try Self.fullSnapshot(account: account, folders: folders, messages: messages, providerThreads: providerThreads)
        let count = try database.write { db in
            try Self.requireRealAccount(account.id, db: db)
            guard let state = try Row.fetchOne(db, sql: "SELECT generation,cursor FROM full_mail_scans WHERE account_id=? AND scope=?", arguments: [account.id.description, scan.scope]),
                  state["generation"] as String == scan.generation, (state["cursor"] as String?) == scan.cursor else { throw SearchFailure.invalidCursor }
            try Self.upsertFull(snapshot, providerThreads: providerThreads, db: db)
            for message in messages {
                try db.execute(sql: "INSERT OR IGNORE INTO full_mail_seen(account_id,scope,message_id) VALUES(?,?,?)", arguments: [account.id.description, scan.scope, message.id.description])
            }
            if let flags {
                guard !isGmail, flags.count <= 100, Set(flags.map(\.uid)).count == flags.count,
                      let validity = uidValidity else { throw IMAPFailure.invalidResponse }
                for flag in flags {
                    let id = try IMAPIdentity.message(account: account.id, mailbox: folders[0].providerID, validity: validity, uid: flag.uid)
                    guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE id=? AND account_id=?)", arguments: [id.description, account.id.description]) == true else { throw IMAPFailure.invalidResponse }
                    try db.execute(sql: "UPDATE messages SET unread=?,flagged=? WHERE id=? AND account_id=?", arguments: [flag.unread, flag.flagged, id.description, account.id.description])
                    try db.execute(sql: "INSERT OR IGNORE INTO full_mail_seen(account_id,scope,message_id) VALUES(?,?,?)", arguments: [account.id.description, scan.scope, id.description])
                }
            }
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM full_mail_seen WHERE account_id=? AND scope=?", arguments: [account.id.description, scan.scope]) ?? 0
            if let nextCursor {
                try db.execute(sql: "UPDATE full_mail_scans SET cursor=? WHERE account_id=? AND scope=?", arguments: [nextCursor, account.id.description, scan.scope])
            } else {
                // Only a completed scan is authoritative for deletions. A failed or cancelled
                // page leaves old mail and its text available, with a resumable checkpoint.
                let scopeClause = isGmail ? "" : " AND id IN (SELECT message_id FROM provider_message_keys WHERE account_id=? AND mailbox=?)"
                var args: [DatabaseValue] = [account.id.description.databaseValue]
                if !isGmail { args += [account.id.description.databaseValue, folders[0].providerID.databaseValue] }
                args += [account.id.description.databaseValue, scan.scope.databaseValue]
                try db.execute(sql: "DELETE FROM messages WHERE account_id=?" + scopeClause + " AND id NOT IN (SELECT message_id FROM full_mail_seen WHERE account_id=? AND scope=?)", arguments: StatementArguments(args))
                if isGmail {
                    try Self.removeMissingGmailFolders(account: account.id, folders: folders, db: db)
                    try db.execute(sql: "UPDATE gmail_profiles SET full_metadata=1,history_id=?,pending_action=0,labels_json=? WHERE account_id=?",
                                   arguments: [scan.anchor, String(decoding: try JSONEncoder().encode(folders.map(\.providerID)), as: UTF8.self), account.id.description])
                } else { try rebuildIMAPThreads(account: account.id, db: db) }
                try Self.recordFullCoverage(account: account.id, folders: folders, validity: uidValidity, serverCount: serverCount, db: db)
                try db.execute(sql: "DELETE FROM full_mail_scans WHERE account_id=? AND scope=?", arguments: [account.id.description, scan.scope])
                try db.execute(sql: "UPDATE accounts SET status='connected' WHERE id=?", arguments: [account.id.description])
            }
            return count
        }
        try protectFiles()
        return count
    }
    public func fullGmailHistory(account: AccountID) throws -> String? {
        try database.read { db in
            try Self.requireRealAccount(account, db: db)
            return try String.fetchOne(db, sql: "SELECT history_id FROM gmail_profiles WHERE account_id=? AND full_metadata=1", arguments: [account.description])
        }
    }
    public func applyGmailChanges(account: MailAccount, folders: [MailFolder], messages: [MailMessage],
                                  providerThreads: [ThreadID: String], removedIDs: Set<String>, historyID: String?) throws {
        guard account.provider == .gmail, messages.count <= 100, removedIDs.count <= 100,
              removedIDs.allSatisfy(GmailIdentity.validID) else { throw MailFailure.invalidInput }
        let snapshot = try Self.fullSnapshot(account: account, folders: folders, messages: messages, providerThreads: providerThreads)
        try database.write { db in
            try Self.requireRealAccount(account.id, db: db)
            try Self.upsertFull(snapshot, providerThreads: providerThreads, db: db)
            for id in removedIDs {
                try db.execute(sql: "DELETE FROM messages WHERE account_id=? AND id IN (SELECT message_id FROM provider_message_keys WHERE account_id=? AND api_id=?)", arguments: [account.id.description, account.id.description, id])
            }
            if let historyID {
                try Self.removeMissingGmailFolders(account: account.id, folders: folders, db: db)
                try db.execute(sql: "UPDATE gmail_profiles SET history_id=?,full_metadata=1,pending_action=0 WHERE account_id=?", arguments: [historyID, account.id.description])
                try Self.recordFullCoverage(account: account.id, folders: folders, validity: nil, serverCount: nil, db: db)
                try db.execute(sql: "UPDATE accounts SET status='connected' WHERE id=?", arguments: [account.id.description])
            }
        }
        try protectFiles()
    }
    private static func requireRealAccount(_ account: AccountID, db: Database) throws {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM accounts WHERE id=? AND is_deleting=0 AND status<>'demo')", arguments: [account.description]) == true else { throw MailFailure.permissionDenied }
    }
    private static func fullSnapshot(account: MailAccount, folders: [MailFolder], messages: [MailMessage], providerThreads: [ThreadID: String]) throws -> MailSnapshot {
        guard folders.allSatisfy({ $0.accountID == account.id }), messages.allSatisfy({ $0.accountID == account.id }) else { throw MailFailure.permissionDenied }
        for message in messages {
            switch message.locator {
            case .imap(let mailbox, let validity, let uid):
                guard account.provider == .imap, message.id == (try IMAPIdentity.message(account: account.id, mailbox: mailbox, validity: validity, uid: uid)) else { throw MailFailure.invalidInput }
            case .gmail(let id):
                guard account.provider == .gmail, message.id == (try GmailIdentity.message(account: account.id, id: id)),
                      message.threadID.map({ providerThreads[$0] != nil }) == true else { throw MailFailure.invalidInput }
            default: throw MailFailure.unsupported
            }
        }
        let threads = try providerThreads.map { local, remote -> MailThread in
            guard local == (try GmailIdentity.thread(account: account.id, id: remote)) else { throw MailFailure.invalidInput }
            return MailThread(id: local, accountID: account.id, subject: messages.first { $0.threadID == local }?.subject ?? "")
        }
        return try MailSnapshot(accounts: [account], folders: folders, threads: threads, messages: messages)
    }
    private static func upsertFull(_ snapshot: MailSnapshot, providerThreads: [ThreadID: String], db: Database) throws {
        try IndexWriter.upsert(snapshot, db: db)
        for (local, remote) in providerThreads {
            try db.execute(sql: "UPDATE threads SET provider_thread_id=?,derivation='provider' WHERE id=?", arguments: [remote, local.description])
        }
    }
    private static func removeMissingGmailFolders(account: AccountID, folders: [MailFolder], db: Database) throws {
        let retained = Set(folders.map { $0.id.description })
        for id in try String.fetchAll(db, sql: "SELECT id FROM folders WHERE account_id=?", arguments: [account.description]) where !retained.contains(id) {
            try db.execute(sql: "DELETE FROM folders WHERE id=? AND account_id=?", arguments: [id, account.description])
        }
    }
    private static func recordFullCoverage(account: AccountID, folders: [MailFolder], validity: UInt32?, serverCount: Int?, db: Database) throws {
        for folder in folders {
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM message_locations WHERE account_id=? AND folder_id=?", arguments: [account.description, folder.id.description]) ?? 0
            try db.execute(sql: """
                INSERT INTO sync_states(account_id,folder_id,uid_validity,last_success,coverage,server_count,indexed_count)
                VALUES(?,?,?,?,'fullMetadata',?,?) ON CONFLICT(account_id,folder_id) DO UPDATE SET
                uid_validity=excluded.uid_validity,last_success=excluded.last_success,coverage=excluded.coverage,
                server_count=excluded.server_count,indexed_count=excluded.indexed_count,cursor=NULL,mod_seq=NULL
                """, arguments: [account.description, folder.id.description, validity.map { Int64($0) }, Date().timeIntervalSince1970, serverCount ?? count, count])
        }
    }
}
