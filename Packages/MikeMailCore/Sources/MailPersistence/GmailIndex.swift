import Foundation
import GRDB
import MailDomain
import MailApplication

extension EncryptedMailRepository: GmailIndex {
    public func reconcileGmailFolders(_ folders: [MailFolder], account: MailAccount) throws {
        guard account.provider == .gmail, !folders.isEmpty, folders.count <= 500,
              folders.contains(where: { $0.providerID == "INBOX" }),
              folders.allSatisfy({ $0.accountID == account.id && $0.id == (try? GmailIdentity.folder(account: account.id, label: $0.providerID)) })
        else { throw MailFailure.invalidInput }
        let snapshot = try MailSnapshot(accounts: [account], folders: folders, threads: [], messages: [])
        try database.write { db in
            _ = try Self.gmailProfile(db, account: account.id)
            try IndexWriter.upsert(snapshot, db: db)
            let retained = Set(folders.map { $0.id.description })
            for id in try String.fetchAll(db, sql: "SELECT id FROM folders WHERE account_id=?", arguments: [account.id.description]) where !retained.contains(id) {
                try db.execute(sql: "DELETE FROM folders WHERE id=? AND account_id=?", arguments: [id, account.id.description])
            }
            // Repair older indexes even when these messages have no new history
            // events. Only the misleading Drafts membership is removed; messages,
            // text and their Trash membership remain intact.
            try db.execute(sql: """
                DELETE FROM message_locations
                WHERE account_id=? AND folder_id IN
                    (SELECT id FROM folders WHERE account_id=? AND provider_id='DRAFT')
                AND message_id IN
                    (SELECT l.message_id FROM message_locations l JOIN folders f ON f.id=l.folder_id AND f.account_id=l.account_id
                     WHERE l.account_id=? AND f.provider_id='TRASH')
                """, arguments: [account.id.description, account.id.description, account.id.description])
            if let payload = try Data.fetchOne(db, sql: "SELECT payload FROM folder_order WHERE account_id=?", arguments: [account.id.description]) {
                let order = try JSONDecoder().decode([FolderID].self, from: payload).filter { retained.contains($0.description) }
                try db.execute(sql: "UPDATE folder_order SET payload=? WHERE account_id=?", arguments: [try JSONEncoder().encode(order), account.id.description])
            }
            // Coverage/checkpoints remain unchanged until message changes complete.
        }
        try protectFiles()
    }
    public func gmailConfigurations() throws -> [GmailConfiguration] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT p.* FROM gmail_profiles p JOIN accounts a ON a.id=p.account_id WHERE a.is_deleting=0").map {
                guard let permission = GmailPermission(rawValue: $0["permission"]) else { throw LocalStoreFailure.wrongKeyOrCorrupt }
                return try GmailConfiguration(accountID: AccountID(string: $0["account_id"]), clientID: $0["client_id"], permission: permission)
            }
        }
    }
    public func saveGmailAccount(_ account: MailAccount, configuration: GmailConfiguration, folders: [MailFolder]) throws {
        guard account.provider == .gmail, account.id == configuration.accountID, account.status == .connected,
              folders.count <= 500, folders.allSatisfy({ $0.accountID == account.id }) else { throw MailFailure.invalidInput }
        let snapshot = try MailSnapshot(accounts: [account], folders: folders, threads: [], messages: [])
        try database.write { db in
            if let old = try Row.fetchOne(db, sql: "SELECT * FROM accounts WHERE id=?", arguments: [account.id.description]) {
                guard old["provider"] as String == "gmail", (old["address"] as String).caseInsensitiveCompare(account.address.value) == .orderedSame else { throw MailFailure.permissionDenied }
            }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM accounts a JOIN gmail_profiles p ON p.account_id=a.id WHERE lower(a.address)=lower(?) AND a.id<>?)",
                                    arguments: [account.address.value, account.id.description]) == false else { throw MailFailure.invalidInput }
            try IndexWriter.upsert(snapshot, db: db)
            try db.execute(sql: """
                INSERT INTO gmail_profiles(account_id,client_id,permission) VALUES(?,?,?)
                ON CONFLICT(account_id) DO UPDATE SET client_id=excluded.client_id,permission=excluded.permission
                """, arguments: [account.id.description, configuration.clientID, configuration.permission.rawValue])
            try db.execute(sql: "UPDATE accounts SET status='connected' WHERE id=?", arguments: [account.id.description])
        }
        try protectFiles()
    }
    public func gmailCheckpoint(account: AccountID) throws -> GmailCheckpoint {
        try database.read { db in
            let row = try Self.gmailProfile(db, account: account)
            let labels = try JSONDecoder().decode(Set<String>.self, from: Data((row["labels_json"] as String).utf8))
            let ids = Set(try String.fetchAll(db, sql: "SELECT api_id FROM provider_message_keys WHERE account_id=? AND kind='gmail'", arguments: [account.description]))
            // A pending label mutation requires a full read-back of the bounded local coverage.
            return GmailCheckpoint(historyID: (row["pending_action"] as Bool) ? nil : row["history_id"], labels: labels, knownIDs: ids)
        }
    }
    public func applyGmailBatch(_ batch: GmailBatch, account: MailAccount) throws {
        var incoming: Set<String> = []
        let threads = try batch.providerThreads.map { local, provider -> MailThread in
            guard local == (try GmailIdentity.thread(account: account.id, id: provider)) else { throw MailFailure.invalidInput }
            return MailThread(id: local, accountID: account.id, subject: batch.messages.first { $0.threadID == local }?.subject ?? "")
        }
        for message in batch.messages {
            guard message.accountID == account.id, case .gmail(let id) = message.locator,
                  batch.wantedIDs.contains(id), incoming.insert(id).inserted,
                  message.id == (try GmailIdentity.message(account: account.id, id: id)),
                  message.threadID.map({ batch.providerThreads[$0] != nil }) == true else { throw MailFailure.invalidInput }
        }
        for folder in batch.folders {
            guard folder.accountID == account.id, folder.id == (try GmailIdentity.folder(account: account.id, label: folder.providerID)) else { throw MailFailure.invalidInput }
        }
        let snapshot = try MailSnapshot(accounts: [account], folders: batch.folders, threads: threads, messages: batch.messages)
        try database.write { db in
            _ = try Self.gmailProfile(db, account: account.id)
            let existing = try Row.fetchAll(db, sql: "SELECT message_id,api_id FROM provider_message_keys WHERE account_id=? AND kind='gmail'", arguments: [account.id.description])
            let known = Set(existing.map { $0["api_id"] as String })
            guard batch.wantedIDs.subtracting(known).isSubset(of: incoming) else { throw GmailFailure.invalidResponse }
            for row in existing where !batch.wantedIDs.contains(row["api_id"] as String) {
                try db.execute(sql: "DELETE FROM messages WHERE id=? AND account_id=?", arguments: [row["message_id"] as String, account.id.description])
            }
            try IndexWriter.upsert(snapshot, db: db)
            for (thread, provider) in batch.providerThreads {
                try db.execute(sql: "UPDATE threads SET provider_thread_id=?,derivation='provider' WHERE id=? AND account_id=?",
                               arguments: [provider, thread.description, account.id.description])
            }
            let retained = Set(batch.folders.map { $0.id.description })
            for id in try String.fetchAll(db, sql: "SELECT id FROM folders WHERE account_id=?", arguments: [account.id.description]) where !retained.contains(id) {
                try db.execute(sql: "DELETE FROM folders WHERE id=? AND account_id=?", arguments: [id, account.id.description])
            }
            try db.execute(sql: "UPDATE gmail_profiles SET history_id=?,labels_json=? WHERE account_id=?", arguments: [batch.historyID,
                String(decoding: try JSONEncoder().encode(batch.labels.sorted()), as: UTF8.self), account.id.description])
            try db.execute(sql: "DELETE FROM sync_states WHERE account_id=?", arguments: [account.id.description])
            for folder in batch.folders where batch.labels.contains(folder.providerID) {
                let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM message_locations WHERE account_id=? AND folder_id=?", arguments: [account.id.description, folder.id.description]) ?? 0
                // Label overlap can place >200 messages in a label; indexed_count is the bounded window, counts in UI come from relationships.
                try db.execute(sql: """
                    INSERT INTO sync_states(account_id,folder_id,cursor,last_success,coverage,indexed_count)
                    VALUES(?,?,?,?,'latest200GmailMetadata',?) ON CONFLICT(account_id,folder_id) DO UPDATE SET
                    cursor=excluded.cursor,last_success=excluded.last_success,coverage=excluded.coverage,indexed_count=excluded.indexed_count
                    """, arguments: [account.id.description, folder.id.description, batch.historyID, Date().timeIntervalSince1970, min(count, 200)])
            }
            try db.execute(sql: "UPDATE accounts SET status='connected' WHERE id=?", arguments: [account.id.description])
            try db.execute(sql: "DELETE FROM threads WHERE account_id=? AND id NOT IN (SELECT thread_id FROM messages WHERE thread_id IS NOT NULL)", arguments: [account.id.description])
            try db.execute(sql: "INSERT INTO app_state(key,value) VALUES('cleanup_pending','1') ON CONFLICT(key) DO UPDATE SET value='1'")
        }
        try finishMaintenance(); try protectFiles()
    }
    public func setGmailStatus(_ status: AccountStatus, account: AccountID) throws {
        guard status != .demo else { throw MailFailure.invalidInput }
        try database.write { db in
            _ = try Self.gmailProfile(db, account: account)
            try db.execute(sql: "UPDATE accounts SET status=? WHERE id=?", arguments: [status.rawValue, account.description])
        }
    }
    public func resetGmailCoverage(account: AccountID) throws {
        try database.write { db in
            _ = try Self.gmailProfile(db, account: account)
            try db.execute(sql: "UPDATE gmail_profiles SET full_metadata=0,history_id=NULL,labels_json='[\"INBOX\"]' WHERE account_id=?", arguments: [account.description])
        }
    }
    public func gmailPendingAction(account: AccountID) throws -> Bool {
        try database.read { try Self.gmailProfile($0, account: account)["pending_action"] }
    }
    public func setGmailPendingAction(_ pending: Bool, account: AccountID) throws {
        try database.write { db in
            _ = try Self.gmailProfile(db, account: account)
            try db.execute(sql: "UPDATE gmail_profiles SET pending_action=? WHERE account_id=?", arguments: [pending, account.description])
        }
    }
    private static func gmailProfile(_ db: Database, account: AccountID) throws -> Row {
        guard let row = try Row.fetchOne(db, sql: "SELECT p.* FROM gmail_profiles p JOIN accounts a ON a.id=p.account_id WHERE p.account_id=? AND a.is_deleting=0 AND a.provider='gmail'", arguments: [account.description]) else { throw MailFailure.notFound }
        return row
    }
}
