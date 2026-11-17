import Foundation
import GRDB
import MailDomain
import MailApplication

extension EncryptedMailRepository {
    /// UI exercises on bundled fiction only; this path can never mutate a connected account.
    public func performDemoMutation(_ mutation: MailMutation, message: MessageID, scope: AccessScope) throws {
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT m.* FROM messages m JOIN accounts a ON a.id=m.account_id WHERE m.id=? AND a.status='demo' AND a.is_deleting=0", arguments: [message.description]) else { throw MailFailure.permissionDenied }
            let current = try IndexRecords.message(row, db: db)
            guard scope.permits(current) else { throw MailFailure.permissionDenied }
            switch mutation {
            case .read(let read):
                try db.execute(sql: "UPDATE messages SET unread=? WHERE id=? AND account_id=?", arguments: [!read,message.description,current.accountID.description])
            case .flagged(let flag):
                try db.execute(sql: "UPDATE messages SET flagged=? WHERE id=? AND account_id=?", arguments: [flag,message.description,current.accountID.description])
            case .move(let folder):
                guard folder.accountID == current.accountID, scope.folderIDs?.contains(folder.id) ?? true,
                      try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM folders WHERE id=? AND account_id=?)", arguments: [folder.id.description,current.accountID.description]) == true else { throw MailFailure.permissionDenied }
                try db.execute(sql: "DELETE FROM message_locations WHERE message_id=? AND account_id=?", arguments: [message.description,current.accountID.description])
                try db.execute(sql: "INSERT INTO message_locations(message_id,account_id,folder_id) VALUES(?,?,?)", arguments: [message.description,current.accountID.description,folder.id.description])
            }
        }
    }
    func rebuildIMAPThreads(account: AccountID, db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT m.id,m.internet_message_id,m.in_reply_to,m.references_json,m.subject FROM messages m JOIN provider_message_keys k ON k.message_id=m.id AND k.account_id=m.account_id WHERE m.account_id=? AND k.kind='imap'", arguments: [account.description])
        let records = try rows.map {
            ThreadResolver.Record(message: try MessageID(string: $0["id"]), ownID: $0["internet_message_id"], replyTo: $0["in_reply_to"],
                                  references: try JSONDecoder().decode([String].self, from: Data(($0["references_json"] as String).utf8)))
        }
        let existingRows = try Row.fetchAll(db, sql: "SELECT message_key,thread_id FROM imap_thread_keys WHERE account_id=?", arguments: [account.description])
        let existing = try Dictionary(uniqueKeysWithValues: existingRows.map { ($0["message_key"] as String, try ThreadID(string: $0["thread_id"])) })
        let resolved = try ThreadResolver.resolve(records, account: account, existing: existing)
        for row in rows {
            let message = try MessageID(string: row["id"])
            guard let thread = resolved.messages[message] else { throw LocalStoreFailure.invalidInput }
            try db.execute(sql: "INSERT INTO threads(id,account_id,subject,derivation) VALUES(?,?,?,'imapReferences') ON CONFLICT(id) DO NOTHING",
                           arguments: [thread.description, account.description, row["subject"] as String])
            try db.execute(sql: "UPDATE messages SET thread_id=? WHERE id=? AND account_id=?", arguments: [thread.description, message.description, account.description])
        }
        try db.execute(sql: "DELETE FROM imap_thread_keys WHERE account_id=?", arguments: [account.description])
        for (key, thread) in resolved.keys {
            try db.execute(sql: "INSERT INTO imap_thread_keys(account_id,message_key,thread_id) VALUES(?,?,?)", arguments: [account.description,key,thread.description])
        }
        try db.execute(sql: "DELETE FROM threads WHERE account_id=? AND derivation='imapReferences' AND NOT EXISTS(SELECT 1 FROM messages m WHERE m.thread_id=threads.id AND m.account_id=threads.account_id)", arguments: [account.description])
    }
    public func pendingMailActions(account: AccountID) throws -> [PendingMailAction] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pending_mail_actions WHERE account_id=? ORDER BY created_at,id", arguments: [account.description]).map {
                guard let id = UUID(uuidString: $0["id"]) else { throw LocalStoreFailure.wrongKeyOrCorrupt }
                let target: String? = $0["target_folder"]
                return PendingMailAction(id: id, accountID: account, sourceFolder: try FolderID(string: $0["source_folder"]),
                                         targetFolder: try target.map { try FolderID(string: $0) })
            }
        }
    }
    public func beginMailAction(_ action: PendingMailAction, message: MailMessage) throws {
        guard action.accountID == message.accountID, message.folderIDs.contains(action.sourceFolder),
              action.targetFolder != action.sourceFolder, case .imap(let mailbox, let validity, let uid) = message.locator else { throw MailFailure.permissionDenied }
        try database.write { db in
            guard try IndexRecords.settings(db, account: action.accountID).serverActionsEnabled else { throw MailFailure.permissionDenied }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM messages m JOIN imap_profiles p ON p.account_id=m.account_id JOIN provider_message_keys k ON k.message_id=m.id AND k.account_id=m.account_id WHERE m.id=? AND m.account_id=? AND k.mailbox=? AND k.uid_validity=? AND k.uid=?)",
                arguments: [message.id.description,message.accountID.description,mailbox,Int64(validity),Int64(uid)]) == true else { throw MailFailure.notFound }
            guard try Int.fetchOne(db, sql: "SELECT count(*) FROM pending_mail_actions WHERE account_id=?", arguments: [action.accountID.description]) == 0 else { throw IMAPFailure.reconciliationRequired }
            try db.execute(sql: "INSERT INTO pending_mail_actions(id,account_id,source_folder,target_folder,created_at) VALUES(?,?,?,?,?)",
                           arguments: [action.id.uuidString, action.accountID.description, action.sourceFolder.description, action.targetFolder?.description, Date().timeIntervalSince1970])
        }
        try protectFiles()
    }
    public func finishMailAction(_ id: UUID, account: AccountID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM pending_mail_actions WHERE id=? AND account_id=?", arguments: [id.uuidString,account.description])
        }
    }
}
