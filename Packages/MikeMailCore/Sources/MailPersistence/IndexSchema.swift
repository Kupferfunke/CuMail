import Foundation
import CryptoKit
import GRDB
import MailApplication

enum IndexSchema {
    static let currentVersion = 14
    static let metadataSQL = """
        CREATE TABLE schema_checksums (
            version INTEGER PRIMARY KEY, digest TEXT NOT NULL, applied_at REAL NOT NULL);
        CREATE TABLE app_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE accounts (
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=36),
            provider TEXT NOT NULL CHECK(provider IN ('imap','gmail','microsoft')),
            name TEXT NOT NULL, address TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('demo','connected','offline','requiresAuthentication')),
            is_deleting INTEGER NOT NULL DEFAULT 0 CHECK(is_deleting IN (0,1)),
            UNIQUE(id, provider));
        CREATE TABLE identities (
            id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            address TEXT NOT NULL, name TEXT NOT NULL, verified INTEGER NOT NULL DEFAULT 0 CHECK(verified IN (0,1)),
            UNIQUE(account_id, address));
        CREATE TABLE folders (
            id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            provider_id TEXT NOT NULL, name TEXT NOT NULL, parent_id TEXT,
            role TEXT NOT NULL CHECK(role IN ('inbox','sent','drafts','archive','trash','custom')),
            UNIQUE(id, account_id), UNIQUE(account_id, provider_id),
            FOREIGN KEY(parent_id, account_id) REFERENCES folders(id, account_id));
        CREATE TABLE threads (
            id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            subject TEXT NOT NULL, provider_thread_id TEXT, derivation TEXT NOT NULL DEFAULT 'synthetic',
            UNIQUE(id, account_id));
        CREATE TABLE messages (
            id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            thread_id TEXT, internet_message_id TEXT, subject TEXT NOT NULL,
            sender_name TEXT NOT NULL, sender_address TEXT NOT NULL, received_us INTEGER NOT NULL,
            unread INTEGER NOT NULL CHECK(unread IN (0,1)), flagged INTEGER NOT NULL CHECK(flagged IN (0,1)),
            UNIQUE(id, account_id),
            FOREIGN KEY(thread_id, account_id) REFERENCES threads(id, account_id));
        CREATE INDEX messages_account_time ON messages(account_id, received_us DESC, id);
        CREATE INDEX messages_thread ON messages(account_id, thread_id);
        CREATE TABLE provider_message_keys (
            message_id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL, kind TEXT NOT NULL,
            api_id TEXT, mailbox TEXT, uid_validity INTEGER, uid INTEGER,
            FOREIGN KEY(message_id, account_id) REFERENCES messages(id, account_id) ON DELETE CASCADE,
            FOREIGN KEY(account_id, kind) REFERENCES accounts(id, provider),
            CHECK((kind IN ('gmail','microsoft') AND length(api_id)>0 AND mailbox IS NULL AND uid IS NULL AND uid_validity IS NULL)
                OR (kind='imap' AND api_id IS NULL AND length(mailbox)>0
                    AND uid_validity BETWEEN 1 AND 4294967295 AND uid BETWEEN 1 AND 4294967295)));
        CREATE UNIQUE INDEX provider_api_identity ON provider_message_keys(account_id, kind, api_id) WHERE api_id IS NOT NULL;
        CREATE UNIQUE INDEX provider_imap_identity ON provider_message_keys(account_id, mailbox, uid_validity, uid) WHERE mailbox IS NOT NULL;
        CREATE TABLE message_recipients (
            message_id TEXT NOT NULL, account_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN ('to','cc','bcc')), name TEXT NOT NULL, address TEXT NOT NULL,
            PRIMARY KEY(message_id, kind, ordinal),
            FOREIGN KEY(message_id, account_id) REFERENCES messages(id, account_id) ON DELETE CASCADE);
        CREATE TABLE message_locations (
            message_id TEXT NOT NULL, account_id TEXT NOT NULL, folder_id TEXT NOT NULL,
            PRIMARY KEY(message_id, folder_id),
            FOREIGN KEY(message_id, account_id) REFERENCES messages(id, account_id) ON DELETE CASCADE,
            FOREIGN KEY(folder_id, account_id) REFERENCES folders(id, account_id) ON DELETE CASCADE);
        CREATE INDEX locations_folder ON message_locations(account_id, folder_id, message_id);
        CREATE TABLE attachments (
            id TEXT PRIMARY KEY NOT NULL, message_id TEXT NOT NULL, account_id TEXT NOT NULL,
            provider_part_id TEXT, filename TEXT NOT NULL, mime_type TEXT NOT NULL,
            byte_count INTEGER NOT NULL CHECK(byte_count>=0), inline INTEGER NOT NULL CHECK(inline IN (0,1)), content_id TEXT,
            FOREIGN KEY(message_id, account_id) REFERENCES messages(id, account_id) ON DELETE CASCADE);
        CREATE TABLE sync_states (
            account_id TEXT NOT NULL, folder_id TEXT NOT NULL, cursor TEXT, uid_validity INTEGER, mod_seq TEXT,
            last_success REAL, coverage TEXT NOT NULL DEFAULT 'metadata',
            PRIMARY KEY(account_id, folder_id),
            FOREIGN KEY(folder_id, account_id) REFERENCES folders(id, account_id) ON DELETE CASCADE);
        """
    static let searchSQL = """
        CREATE TABLE account_settings (
            account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            text_index_enabled INTEGER NOT NULL DEFAULT 0 CHECK(text_index_enabled IN (0,1)),
            message_text_limit INTEGER NOT NULL DEFAULT 262144 CHECK(message_text_limit BETWEEN 1 AND 262144),
            account_text_budget INTEGER NOT NULL DEFAULT 262144000 CHECK(account_text_budget BETWEEN message_text_limit AND 262144000));
        INSERT INTO account_settings(account_id) SELECT id FROM accounts;
        CREATE TABLE message_text (
            message_id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL, text TEXT NOT NULL,
            source TEXT NOT NULL CHECK(source='plainTextOnOpen'), extraction_version INTEGER NOT NULL CHECK(extraction_version>0),
            indexed_at REAL NOT NULL, utf8_bytes INTEGER NOT NULL CHECK(utf8_bytes BETWEEN 0 AND 262144),
            original_bytes INTEGER NOT NULL CHECK(original_bytes>=utf8_bytes),
            truncated INTEGER NOT NULL CHECK(truncated IN (0,1)),
            FOREIGN KEY(message_id, account_id) REFERENCES messages(id, account_id) ON DELETE CASCADE,
            CHECK(length(CAST(text AS BLOB))=utf8_bytes));
        CREATE INDEX text_account ON message_text(account_id);
        CREATE TABLE search_content (
            rowid INTEGER PRIMARY KEY, message_id TEXT NOT NULL UNIQUE, account_id TEXT NOT NULL,
            subject TEXT NOT NULL, sender TEXT NOT NULL, recipients TEXT NOT NULL, attachments TEXT NOT NULL, extract TEXT NOT NULL DEFAULT '',
            FOREIGN KEY(message_id, account_id) REFERENCES messages(id, account_id) ON DELETE CASCADE);
        CREATE VIRTUAL TABLE search_index USING fts5(subject,sender,recipients,attachments,extract,
            content='search_content',content_rowid='rowid',tokenize='unicode61 remove_diacritics 2');
        INSERT INTO search_index(search_index,rank) VALUES('secure-delete',1);
        CREATE TRIGGER search_insert AFTER INSERT ON search_content BEGIN
            INSERT INTO search_index(rowid,subject,sender,recipients,attachments,extract)
                VALUES(new.rowid,new.subject,new.sender,new.recipients,new.attachments,new.extract);
        END;
        CREATE TRIGGER search_delete AFTER DELETE ON search_content BEGIN
            INSERT INTO search_index(search_index,rowid,subject,sender,recipients,attachments,extract)
                VALUES('delete',old.rowid,old.subject,old.sender,old.recipients,old.attachments,old.extract);
        END;
        CREATE TRIGGER search_update AFTER UPDATE ON search_content BEGIN
            INSERT INTO search_index(search_index,rowid,subject,sender,recipients,attachments,extract)
                VALUES('delete',old.rowid,old.subject,old.sender,old.recipients,old.attachments,old.extract);
            INSERT INTO search_index(rowid,subject,sender,recipients,attachments,extract)
                VALUES(new.rowid,new.subject,new.sender,new.recipients,new.attachments,new.extract);
        END;
        CREATE TRIGGER extract_delete AFTER DELETE ON message_text BEGIN
            UPDATE search_content SET extract='' WHERE message_id=old.message_id AND account_id=old.account_id;
        END;
        INSERT INTO search_content(message_id,account_id,subject,sender,recipients,attachments,extract)
            SELECT m.id,m.account_id,m.subject,m.sender_name||' '||m.sender_address,
                COALESCE((SELECT group_concat(r.name||' '||r.address,' ') FROM message_recipients r WHERE r.message_id=m.id),''),
                COALESCE((SELECT group_concat(a.filename,' ') FROM attachments a WHERE a.message_id=m.id),''),''
            FROM messages m;
        """

    static let imapSQL = """
        CREATE TABLE imap_profiles (
            account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            host TEXT NOT NULL, port INTEGER NOT NULL CHECK(port BETWEEN 1 AND 65535),
            tls TEXT NOT NULL CHECK(tls IN ('implicitTLS','startTLS')), username TEXT NOT NULL,
            UNIQUE(host,port,username));
        ALTER TABLE sync_states ADD COLUMN server_count INTEGER CHECK(server_count>=0);
        ALTER TABLE sync_states ADD COLUMN indexed_count INTEGER CHECK(indexed_count BETWEEN 0 AND 200);
        """

    static let readingSQL = """
        ALTER TABLE account_settings ADD COLUMN server_actions_enabled INTEGER NOT NULL DEFAULT 0 CHECK(server_actions_enabled IN (0,1));
        ALTER TABLE messages ADD COLUMN in_reply_to TEXT;
        ALTER TABLE messages ADD COLUMN references_json TEXT NOT NULL DEFAULT '[]';
        ALTER TABLE messages ADD COLUMN threading_headers_loaded INTEGER NOT NULL DEFAULT 0 CHECK(threading_headers_loaded IN (0,1));
        CREATE TABLE imap_thread_keys (
            account_id TEXT NOT NULL, message_key TEXT NOT NULL, thread_id TEXT NOT NULL,
            PRIMARY KEY(account_id,message_key),
            FOREIGN KEY(thread_id,account_id) REFERENCES threads(id,account_id) ON DELETE CASCADE);
        CREATE TABLE pending_mail_actions (
            id TEXT PRIMARY KEY NOT NULL,
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            source_folder TEXT NOT NULL, target_folder TEXT, created_at REAL NOT NULL,
            FOREIGN KEY(source_folder,account_id) REFERENCES folders(id,account_id) ON DELETE CASCADE,
            FOREIGN KEY(target_folder,account_id) REFERENCES folders(id,account_id) ON DELETE CASCADE);
        """

    static let searchDetailsSQL = """
        ALTER TABLE message_text ADD COLUMN input_format TEXT NOT NULL DEFAULT 'legacyUnknown'
            CHECK(input_format IN ('plainText','sanitizedHTML','legacyUnknown'));
        CREATE INDEX attachments_message ON attachments(message_id,account_id);
        CREATE INDEX messages_time ON messages(received_us DESC,id);
        CREATE INDEX messages_flags_time ON messages(unread,flagged,received_us DESC,id);
        """

    static let compositionSQL = """
        ALTER TABLE messages ADD COLUMN reply_to_json TEXT NOT NULL DEFAULT '[]';
        UPDATE messages SET threading_headers_loaded=0 WHERE account_id IN (SELECT account_id FROM imap_profiles);
        CREATE TABLE local_drafts (
            id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            revision INTEGER NOT NULL CHECK(revision>0), status TEXT NOT NULL,
            modified_at REAL NOT NULL, payload BLOB NOT NULL CHECK(length(payload)<=1048576));
        CREATE INDEX drafts_account ON local_drafts(account_id,modified_at DESC);
        CREATE TABLE smtp_profiles (
            account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            payload BLOB NOT NULL CHECK(length(payload)<=8192));
        """

    static let gmailSQL = """
        CREATE TABLE gmail_profiles (
            account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            client_id TEXT NOT NULL, permission TEXT NOT NULL CHECK(permission IN ('readOnly','manageMail')),
            history_id TEXT, labels_json TEXT NOT NULL DEFAULT '["INBOX"]',
            pending_action INTEGER NOT NULL DEFAULT 0 CHECK(pending_action IN (0,1)));
        CREATE TABLE gmail_draft_bindings (
            draft_id TEXT PRIMARY KEY NOT NULL REFERENCES local_drafts(id) ON DELETE CASCADE,
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            provider_id TEXT, provider_message_id TEXT, revision INTEGER NOT NULL, pending INTEGER NOT NULL CHECK(pending IN (0,1)));
        """

    static let graphSQL = """
        CREATE TABLE graph_profiles (
            account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            client_id TEXT NOT NULL, tenant TEXT NOT NULL, user_id TEXT NOT NULL,
            manage_mail INTEGER NOT NULL CHECK(manage_mail IN (0,1)), send_mail INTEGER NOT NULL CHECK(send_mail IN (0,1)),
            states_json TEXT NOT NULL DEFAULT '{}', pending_action INTEGER NOT NULL DEFAULT 0 CHECK(pending_action IN (0,1)));
        CREATE TABLE graph_draft_bindings (
            draft_id TEXT PRIMARY KEY NOT NULL REFERENCES local_drafts(id) ON DELETE CASCADE,
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            provider_id TEXT, change_key TEXT, internet_message_id TEXT,
            revision INTEGER NOT NULL, pending INTEGER NOT NULL CHECK(pending IN (0,1)));
        """

    // Keep v8's checksum for indexes opened by the withdrawn build. No Microsoft
    // provider remains. Reject unexpected nonempty provider tables rather than lose data.
    static let withdrawMicrosoftSQL = """
        DROP TABLE graph_draft_bindings;
        DROP TABLE graph_profiles;
        """

    static let desktopSQL = """
        CREATE TABLE desktop_notification_state (
            account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            epoch TEXT NOT NULL CHECK(length(epoch)<=8192),
            payload BLOB NOT NULL CHECK(length(payload)<=262144));
        """

    static let completeMailSQL = """
        CREATE TABLE complete_sync_states (
            account_id TEXT NOT NULL, folder_id TEXT NOT NULL, cursor TEXT, uid_validity INTEGER, mod_seq TEXT,
            last_success REAL, coverage TEXT NOT NULL DEFAULT 'metadata',
            server_count INTEGER CHECK(server_count>=0), indexed_count INTEGER CHECK(indexed_count>=0),
            PRIMARY KEY(account_id,folder_id),
            FOREIGN KEY(folder_id,account_id) REFERENCES folders(id,account_id) ON DELETE CASCADE);
        INSERT INTO complete_sync_states SELECT account_id,folder_id,cursor,uid_validity,mod_seq,last_success,coverage,server_count,indexed_count FROM sync_states;
        DROP TABLE sync_states;
        ALTER TABLE complete_sync_states RENAME TO sync_states;
        CREATE TABLE full_mail_scans (
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            scope TEXT NOT NULL, generation TEXT NOT NULL, cursor TEXT, anchor TEXT, started_at REAL NOT NULL,
            PRIMARY KEY(account_id,scope));
        CREATE TABLE full_mail_seen (
            account_id TEXT NOT NULL, scope TEXT NOT NULL, message_id TEXT NOT NULL,
            PRIMARY KEY(account_id,scope,message_id),
            FOREIGN KEY(account_id,scope) REFERENCES full_mail_scans(account_id,scope) ON DELETE CASCADE);
        ALTER TABLE gmail_profiles ADD COLUMN full_metadata INTEGER NOT NULL DEFAULT 0 CHECK(full_metadata IN (0,1));
        CREATE TABLE account_signatures (
            account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            payload BLOB NOT NULL CHECK(length(payload)<=131072));
        """

    static let everydayMailSQL = """
        ALTER TABLE account_settings ADD COLUMN full_text_index_enabled INTEGER NOT NULL DEFAULT 0 CHECK(full_text_index_enabled IN (0,1));
        ALTER TABLE account_settings ADD COLUMN mark_read_seconds INTEGER NOT NULL DEFAULT 0 CHECK(mark_read_seconds IN (0,2,5));
        CREATE TABLE text_index_attempts (
            message_id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL,
            attempts INTEGER NOT NULL CHECK(attempts>0), retry_at REAL,
            reason TEXT NOT NULL CHECK(reason IN ('unavailable','noText','tooLarge')),
            FOREIGN KEY(message_id,account_id) REFERENCES messages(id,account_id) ON DELETE CASCADE);
        CREATE INDEX text_attempts_account ON text_index_attempts(account_id,retry_at);
        CREATE TABLE mail_action_receipts (
            id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            payload BLOB NOT NULL CHECK(length(payload)<=262144), updated_at REAL NOT NULL);
        """

    static let personalMailSQL = """
        CREATE TABLE signature_choices (
            id TEXT PRIMARY KEY NOT NULL, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            name TEXT NOT NULL CHECK(length(name) BETWEEN 1 AND 80),
            payload BLOB NOT NULL CHECK(length(payload)<=131072),
            position INTEGER NOT NULL CHECK(position>=0),
            is_default INTEGER NOT NULL CHECK(is_default IN (0,1)));
        CREATE UNIQUE INDEX signature_default ON signature_choices(account_id) WHERE is_default=1;
        INSERT INTO signature_choices(id,account_id,name,payload,position,is_default)
            SELECT account_id,account_id,'Standard',payload,0,1 FROM account_signatures;
        DROP TABLE account_signatures;
        CREATE TABLE folder_order (
            account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            payload BLOB NOT NULL CHECK(length(payload)<=32768));
        """

    static let recipientHistorySQL = """
        CREATE TABLE recipient_usage (
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            message_key TEXT NOT NULL, address TEXT NOT NULL COLLATE NOCASE,
            name TEXT NOT NULL, sent_at REAL NOT NULL,
            PRIMARY KEY(account_id,message_key,address));
        CREATE INDEX recipient_usage_address ON recipient_usage(address,sent_at DESC);
        INSERT OR IGNORE INTO recipient_usage(account_id,message_key,address,name,sent_at)
            SELECT m.account_id,CASE WHEN coalesce(m.internet_message_id,'')<>'' THEN 'mid:'||trim(m.internet_message_id) ELSE 'local:'||m.id END,
                   lower(trim(r.address)),r.name,m.received_us/1000000.0
            FROM messages m JOIN accounts a ON a.id=m.account_id
            JOIN message_recipients r ON r.message_id=m.id AND r.account_id=m.account_id
            WHERE a.is_deleting=0 AND lower(m.sender_address)=lower(a.address)
                AND EXISTS(SELECT 1 FROM message_locations l JOIN folders f ON f.id=l.folder_id AND f.account_id=l.account_id
                           WHERE l.message_id=m.id AND f.role='sent');
        """

    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        for (version, sql) in [(1, metadataSQL), (2, searchSQL), (3, imapSQL), (4, readingSQL), (5, searchDetailsSQL), (6, compositionSQL), (7, gmailSQL), (8, graphSQL), (9, withdrawMicrosoftSQL), (10, desktopSQL), (11, completeMailSQL), (12, everydayMailSQL), (13, personalMailSQL), (14, recipientHistorySQL)] {
            migrator.registerMigration("v\(version)") { db in
                if version == 9 {
                    guard try Int.fetchOne(db, sql: "SELECT count(*) FROM graph_profiles") == 0,
                          try Int.fetchOne(db, sql: "SELECT count(*) FROM graph_draft_bindings") == 0
                    else { throw LocalStoreFailure.incompatibleSchema }
                }
                try db.execute(sql: sql)
                try db.execute(sql: "INSERT INTO schema_checksums(version,digest,applied_at) VALUES(?,?,?)",
                               arguments: [version, digest(sql), Date().timeIntervalSince1970])
            }
        }
        return migrator
    }
    static func digest(_ sql: String) -> String {
        SHA256.hash(data: Data(sql.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func verify(_ db: Database) throws -> Int {
        guard try db.tableExists("schema_checksums") else {
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") ?? 0
            guard count == 0 else { throw LocalStoreFailure.incompatibleSchema }
            return 0
        }
        let rows = try Row.fetchAll(db, sql: "SELECT version,digest FROM schema_checksums ORDER BY version")
        let definitions = [1: metadataSQL, 2: searchSQL, 3: imapSQL, 4: readingSQL, 5: searchDetailsSQL, 6: compositionSQL, 7: gmailSQL, 8: graphSQL, 9: withdrawMicrosoftSQL, 10: desktopSQL, 11: completeMailSQL, 12: everydayMailSQL, 13: personalMailSQL, 14: recipientHistorySQL]
        for (offset, row) in rows.enumerated() {
            let version: Int = row["version"]
            guard version == offset + 1, let sql = definitions[version], row["digest"] as String == digest(sql)
            else { throw LocalStoreFailure.incompatibleSchema }
        }
        return rows.count
    }
}
