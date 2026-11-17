import Foundation
import GRDB
import MailDomain
import MailApplication

enum IndexRecords {
    static func account(_ row: Row) throws -> MailAccount {
        guard let provider = ProviderKind(rawValue: row["provider"]), let status = AccountStatus(rawValue: row["status"])
        else { throw LocalStoreFailure.wrongKeyOrCorrupt }
        return MailAccount(id: try AccountID(string: row["id"]), name: row["name"], address: try EmailAddress(row["address"]), provider: provider, status: status)
    }
    static func folder(_ row: Row) throws -> MailFolder {
        guard let role = FolderRole(rawValue: row["role"]) else { throw LocalStoreFailure.wrongKeyOrCorrupt }
        return try MailFolder(id: FolderID(string: row["id"]), accountID: AccountID(string: row["account_id"]),
                              providerID: row["provider_id"], name: row["name"], role: role)
    }
    static func message(_ row: Row, db: Database) throws -> MailMessage {
        let id = try MessageID(string: row["id"])
        let account = try AccountID(string: row["account_id"])
        guard let key = try Row.fetchOne(db, sql: "SELECT * FROM provider_message_keys WHERE message_id=? AND account_id=?", arguments: [id.description, account.description])
        else { throw LocalStoreFailure.wrongKeyOrCorrupt }
        let locator: ProviderLocator
        switch key["kind"] as String {
        case "gmail": locator = .gmail(id: key["api_id"])
        case "microsoft": locator = .graph(immutableID: key["api_id"])
        case "imap":
            let validity: Int64 = key["uid_validity"]; let uid: Int64 = key["uid"]
            guard let checkedValidity = UInt32(exactly: validity), let checkedUID = UInt32(exactly: uid) else { throw LocalStoreFailure.wrongKeyOrCorrupt }
            locator = .imap(mailbox: key["mailbox"], uidValidity: checkedValidity, uid: checkedUID)
        default: throw LocalStoreFailure.wrongKeyOrCorrupt
        }
        let recipientRows = try Row.fetchAll(db, sql: "SELECT * FROM message_recipients WHERE message_id=? AND account_id=? AND kind<>'bcc' ORDER BY ordinal", arguments: [id.description, account.description])
        let recipients = try recipientRows.map { try MailPerson(name: $0["name"], address: EmailAddress($0["address"])) }
        let cc = try recipientRows.filter { $0["kind"] as String == "cc" }.map { try MailPerson(name: $0["name"], address: EmailAddress($0["address"])) }
        let folders = try String.fetchAll(db, sql: "SELECT folder_id FROM message_locations WHERE message_id=? AND account_id=?", arguments: [id.description, account.description])
            .map { try FolderID(string: $0) }
        let attachments = try Row.fetchAll(db, sql: "SELECT * FROM attachments WHERE message_id=? AND account_id=? ORDER BY id", arguments: [id.description, account.description])
            .map { try AttachmentMetadata(id: AttachmentID(string: $0["id"]), messageID: id, accountID: account,
                                          filename: $0["filename"], mimeType: $0["mime_type"], byteCount: $0["byte_count"], isInline: $0["inline"],
                                          providerPartID: $0["provider_part_id"], contentID: $0["content_id"]) }
        let rawThread: String? = row["thread_id"]
        return try MailMessage(id: id, accountID: account, locator: locator,
            threadID: rawThread.map { try ThreadID(string: $0) }, folderIDs: Set(folders),
            internetMessageID: row["internet_message_id"], subject: row["subject"],
            sender: MailPerson(name: row["sender_name"], address: EmailAddress(row["sender_address"])),
            recipients: recipients, receivedAt: Date(timeIntervalSince1970: Double(row["received_us"] as Int64) / 1_000_000),
            isUnread: row["unread"], isFlagged: row["flagged"], preview: nil, attachments: attachments,
            inReplyTo: row["in_reply_to"], references: try JSONDecoder().decode([String].self, from: Data((row["references_json"] as String).utf8)),
            threadingHeadersLoaded: row["threading_headers_loaded"], ccRecipients: cc,
            replyTo: try JSONDecoder().decode([MailPerson].self, from: Data((row["reply_to_json"] as String).utf8)))
    }
    static func settings(_ db: Database, account: AccountID) throws -> AccountSettings {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT s.*,a.name FROM account_settings s JOIN accounts a ON a.id=s.account_id
            WHERE s.account_id=? AND a.is_deleting=0
            """, arguments: [account.description]) else { throw MailFailure.notFound }
        return try AccountSettings(accountID: account, displayName: row["name"], textIndexEnabled: row["text_index_enabled"],
                                   messageTextLimit: row["message_text_limit"], accountTextBudget: row["account_text_budget"], serverActionsEnabled: row["server_actions_enabled"],
                                   fullTextIndexEnabled: row["full_text_index_enabled"], markReadAfterSeconds: row["mark_read_seconds"])
    }
    static func microseconds(_ date: Date) throws -> Int64 {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, (-62_135_596_800...253_402_300_799).contains(seconds) else { throw LocalStoreFailure.invalidInput }
        return Int64((seconds * 1_000_000).rounded())
    }
    static func refreshSearch(_ db: Database, message: String) throws {
        try db.execute(sql: """
            INSERT INTO search_content(message_id,account_id,subject,sender,recipients,attachments,extract)
                SELECT m.id,m.account_id,m.subject,m.sender_name||' '||m.sender_address,
                    COALESCE((SELECT group_concat(r.name||' '||r.address,' ') FROM message_recipients r WHERE r.message_id=m.id),''),
                    COALESCE((SELECT group_concat(a.filename,' ') FROM attachments a WHERE a.message_id=m.id),''),
                    COALESCE((SELECT t.text FROM message_text t WHERE t.message_id=m.id),'')
                FROM messages m WHERE m.id=?
            ON CONFLICT(message_id) DO UPDATE SET subject=excluded.subject,sender=excluded.sender,
                recipients=excluded.recipients,attachments=excluded.attachments,extract=excluded.extract
            """, arguments: [message])
    }
}
