import Foundation
import GRDB
import MailDomain
import MailApplication

public struct LocalSyncCheckpoint: Sendable {
    public let accountID: AccountID
    public let folderID: FolderID
    public let cursor: String
    public let updatedAt: Date
    public init(accountID: AccountID, folderID: FolderID, cursor: String, updatedAt: Date) throws {
        guard cursor.utf8.count <= 65536, updatedAt.timeIntervalSince1970.isFinite else { throw LocalStoreFailure.invalidInput }
        self.accountID = accountID; self.folderID = folderID; self.cursor = cursor; self.updatedAt = updatedAt
    }
}

enum IndexWriter {
    static func upsert(_ snapshot: MailSnapshot, db: Database, checkpoint: LocalSyncCheckpoint? = nil, includeReadingMetadata: Bool = true) throws {
        guard snapshot.messages.count <= 1000 else { throw LocalStoreFailure.invalidInput }
        for account in snapshot.accounts {
            _ = try AccountSettings(accountID: account.id, displayName: account.name)
            if let existing = try Row.fetchOne(db, sql: "SELECT provider,is_deleting FROM accounts WHERE id=?", arguments: [account.id.description]) {
                guard existing["provider"] as String == account.provider.rawValue, !(existing["is_deleting"] as Bool) else { throw LocalStoreFailure.invalidInput }
            }
            try db.execute(sql: "INSERT INTO accounts(id,provider,name,address,status) VALUES(?,?,?,?,?) ON CONFLICT(id) DO NOTHING",
                arguments: [account.id.description, account.provider.rawValue, account.name, account.address.value, account.status.rawValue])
            try db.execute(sql: "INSERT INTO account_settings(account_id) VALUES(?) ON CONFLICT(account_id) DO NOTHING", arguments: [account.id.description])
            try db.execute(sql: "INSERT INTO identities(id,account_id,address,name,verified) VALUES(?,?,?,?,0) ON CONFLICT(id) DO NOTHING",
                arguments: [account.id.description, account.id.description, account.address.value, account.name])
        }
        for folder in snapshot.folders {
            try sameAccount(db, table: "folders", id: folder.id.description, account: folder.accountID)
            try db.execute(sql: """
                INSERT INTO folders(id,account_id,provider_id,name,role) VALUES(?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET provider_id=excluded.provider_id,name=excluded.name,role=excluded.role
                """, arguments: [folder.id.description, folder.accountID.description, folder.providerID, folder.name, folder.role.rawValue])
        }
        for thread in snapshot.threads {
            try sameAccount(db, table: "threads", id: thread.id.description, account: thread.accountID)
            try db.execute(sql: "INSERT INTO threads(id,account_id,subject) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET subject=excluded.subject",
                           arguments: [thread.id.description, thread.accountID.description, thread.subject])
        }
        let supportsComposition = (try? db.columns(in: "messages").contains { $0.name == "reply_to_json" }) == true
        let supportsRecipientHistory = try db.tableExists("recipient_usage")
        for message in snapshot.messages {
            guard message.subject.utf8.count <= 64 * 1024, message.recipients.count <= 1000,
                  message.attachments.count <= 1000 else { throw LocalStoreFailure.invalidInput }
            try sameAccount(db, table: "messages", id: message.id.description, account: message.accountID)
            let identity: StatementArguments = [message.id.description, message.accountID.description]
            try db.execute(sql: """
                INSERT INTO messages(id,account_id,thread_id,internet_message_id,subject,sender_name,sender_address,received_us,unread,flagged)
                VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                thread_id=excluded.thread_id,internet_message_id=excluded.internet_message_id,subject=excluded.subject,
                sender_name=excluded.sender_name,sender_address=excluded.sender_address,received_us=excluded.received_us,
                unread=excluded.unread,flagged=excluded.flagged
                """, arguments: [message.id.description, message.accountID.description, message.threadID?.description,
                                 message.internetMessageID, message.subject, message.sender.name, message.sender.address.value,
                                 try IndexRecords.microseconds(message.receivedAt), message.isUnread, message.isFlagged])
            // Historical migration fixtures can explicitly write the pre-v4 column set.
            if includeReadingMetadata {
                let referencesJSON = String(decoding: try JSONEncoder().encode(message.references), as: UTF8.self)
                try db.execute(sql: "UPDATE messages SET in_reply_to=?,references_json=?,threading_headers_loaded=? WHERE id=? AND account_id=?",
                               arguments: [message.inReplyTo, referencesJSON, message.threadingHeadersLoaded, message.id.description, message.accountID.description])
            }
            if supportsComposition {
                try db.execute(sql: "UPDATE messages SET reply_to_json=? WHERE id=? AND account_id=?",
                    arguments: [String(decoding: try JSONEncoder().encode(message.replyTo), as: UTF8.self), message.id.description, message.accountID.description])
            }
            if let old = try Row.fetchOne(db, sql: "SELECT * FROM provider_message_keys WHERE message_id=?", arguments: [message.id.description]) {
                let sameIdentity: Bool
                switch message.locator {
                case .imap(let mailbox, let validity, let uid):
                    sameIdentity = old["kind"] as String == "imap" && old["mailbox"] as String? == mailbox
                        && old["uid_validity"] as Int64? == Int64(validity) && old["uid"] as Int64? == Int64(uid)
                case .gmail(let id), .graph(let id):
                    sameIdentity = old["kind"] as String == message.locator.kind.rawValue && old["api_id"] as String? == id
                }
                guard sameIdentity else { throw LocalStoreFailure.invalidInput }
            }
            // A stable provider identity refers to the same content. Metadata refresh must retain an approved extract.
            for table in ["provider_message_keys", "message_recipients", "message_locations", "attachments"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE message_id=? AND account_id=?", arguments: identity)
            }
            var apiID: String?; var mailbox: String?; var validity: Int64?; var uid: Int64?
            switch message.locator {
            case .gmail(let value), .graph(let value): apiID = value
            case .imap(let box, let v, let u): mailbox = box; validity = Int64(v); uid = Int64(u)
            }
            try db.execute(sql: "INSERT INTO provider_message_keys(message_id,account_id,kind,api_id,mailbox,uid_validity,uid) VALUES(?,?,?,?,?,?,?)",
                arguments: [message.id.description, message.accountID.description, message.locator.kind.rawValue, apiID, mailbox, validity, uid])
            for (index, person) in message.recipients.enumerated() {
                try db.execute(sql: "INSERT INTO message_recipients(message_id,account_id,ordinal,kind,name,address) VALUES(?,?,?,?,?,?)",
                               arguments: [message.id.description, message.accountID.description, index, message.ccRecipients.contains(person) ? "cc" : "to", person.name, person.address.value])
            }
            for folder in message.folderIDs {
                try db.execute(sql: "INSERT INTO message_locations(message_id,account_id,folder_id) VALUES(?,?,?)",
                               arguments: [message.id.description, message.accountID.description, folder.description])
            }
            for attachment in message.attachments {
                try db.execute(sql: "INSERT INTO attachments(id,message_id,account_id,filename,mime_type,byte_count,inline,provider_part_id,content_id) VALUES(?,?,?,?,?,?,?,?,?)",
                    arguments: [attachment.id.description, message.id.description, message.accountID.description,
                                attachment.filename, attachment.mimeType, attachment.byteCount, attachment.isInline, attachment.providerPartID, attachment.contentID])
            }
            try IndexRecords.refreshSearch(db, message: message.id.description)
            if supportsRecipientHistory { try RecipientUsage.recordIndexedMessage(message.id.description, db: db) }
        }
        if let checkpoint {
            guard snapshot.folders.contains(where: { $0.id == checkpoint.folderID && $0.accountID == checkpoint.accountID }) else { throw LocalStoreFailure.invalidInput }
            try db.execute(sql: """
                INSERT INTO sync_states(account_id,folder_id,cursor,last_success) VALUES(?,?,?,?)
                ON CONFLICT(account_id,folder_id) DO UPDATE SET cursor=excluded.cursor,last_success=excluded.last_success
                """, arguments: [checkpoint.accountID.description, checkpoint.folderID.description, checkpoint.cursor, checkpoint.updatedAt.timeIntervalSince1970])
        }
    }

    private static func sameAccount(_ db: Database, table: String, id: String, account: AccountID) throws {
        if let existing = try String.fetchOne(db, sql: "SELECT account_id FROM \(table) WHERE id=?", arguments: [id]), existing != account.description {
            throw DomainError.crossAccountReference
        }
    }
}
