import Foundation
import CryptoKit
import GRDB
import MailDomain
import MailApplication
import MailSecurity

public actor EncryptedMailRepository: MailMetadataRepository {
    let database: DatabaseQueue
    let paths: WorkspacePaths
    public init(paths: WorkspacePaths, key: Data) throws {
        self.paths = paths
        self.database = try IndexDatabase.open(paths: paths, key: key)
    }
    public func close() throws { try database.close() }

    public func accounts(in scope: AccessScope) throws -> [MailAccount] {
        try validate(scope)
        guard !scope.accountIDs.isEmpty else { return [] }
        return try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM accounts WHERE is_deleting=0 AND id IN (\(placeholders(scope.accountIDs.count))) ORDER BY name,id",
                             arguments: StatementArguments(scope.accountIDs.map(\.description)))
                .map(IndexRecords.account)
        }
    }
    public func folders(in scope: AccessScope) throws -> [MailFolder] {
        try validate(scope)
        guard !scope.accountIDs.isEmpty, scope.folderIDs?.isEmpty != true else { return [] }
        var condition = "f.account_id IN (\(placeholders(scope.accountIDs.count)))"
        var values = scope.accountIDs.map { $0.description.databaseValue }
        if let folders = scope.folderIDs {
            condition += " AND f.id IN (\(placeholders(folders.count)))"
            values += folders.map { $0.description.databaseValue }
        }
        let clause = condition; let arguments = StatementArguments(values)
        return try database.read { db in
            try Row.fetchAll(db, sql: "SELECT f.* FROM folders f JOIN accounts a ON a.id=f.account_id WHERE a.is_deleting=0 AND \(clause) ORDER BY f.name,f.id", arguments: arguments)
                .map(IndexRecords.folder)
        }
    }
    public func messages(filter: MessageFilter, page: PageRequest, in scope: AccessScope) throws -> MessagePage {
        try query(filter: filter, page: page, scope: scope, thread: nil)
    }
    public func thread(id: ThreadID, page: PageRequest, in scope: AccessScope) throws -> MessagePage {
        try validate(scope)
        guard !scope.accountIDs.isEmpty else { throw MailFailure.notFound }
        let allowed = try database.read {
            try Bool.fetchOne($0, sql: """
                SELECT EXISTS(SELECT 1 FROM threads t JOIN accounts a ON a.id=t.account_id
                WHERE a.is_deleting=0 AND t.id=? AND t.account_id IN (\(placeholders(scope.accountIDs.count))))
                """, arguments: StatementArguments([id.description] + scope.accountIDs.map(\.description))) == true
        }
        guard allowed else { throw MailFailure.notFound }
        return try query(filter: MessageFilter(), page: page, scope: scope, thread: id)
    }
    public func message(id: MessageID, in scope: AccessScope) throws -> MailMessage {
        try validate(scope)
        let (clause, values) = scopeClause(scope)
        return try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT m.* FROM messages m JOIN accounts a ON a.id=m.account_id WHERE \(clause) AND m.id=?",
                                            arguments: StatementArguments(values + [id.description.databaseValue])) else { throw MailFailure.notFound }
            return try IndexRecords.message(row, db: db)
        }
    }

    private func query(filter: MessageFilter, page: PageRequest, scope: AccessScope, thread: ThreadID?) throws -> MessagePage {
        try validate(scope); try Task.checkCancellation()
        let query = try filter.searchQuery()
        let selectedAccounts = try accounts(in: scope).filter { account in
            filter.accountID.map { $0 == account.id } ?? true
        }
        var (clause, values) = scopeClause(scope)
        if let account = filter.accountID { clause += " AND m.account_id=?"; values.append(account.description.databaseValue) }
        let accountIDs = Set(selectedAccounts.filter(query.matchesAccount).map(\.id))
        if query.account != nil {
            clause += accountIDs.isEmpty ? " AND 0" : " AND m.account_id IN (\(placeholders(accountIDs.count)))"
            values += accountIDs.map { $0.description.databaseValue }
        }
        let selectedFolders = try folders(in: scope).filter { folder in
            accountIDs.contains(folder.accountID) && (filter.folderID.map { $0 == folder.id } ?? true)
                && (filter.role.map { $0 == folder.role } ?? true) && query.matchesFolder(folder)
        }
        if filter.folderID != nil || filter.role != nil || query.folder != nil {
            let ids = selectedFolders.map(\.id)
            clause += ids.isEmpty ? " AND 0" : " AND EXISTS(SELECT 1 FROM message_locations l WHERE l.message_id=m.id AND l.account_id=m.account_id AND l.folder_id IN (\(placeholders(ids.count))))"
            values += ids.map { $0.description.databaseValue }
        }
        if filter.unreadOnly { clause += " AND m.unread=1" }
        if filter.flaggedOnly { clause += " AND m.flagged=1" }
        if let unread = query.unread { clause += " AND m.unread=?"; values.append(unread.databaseValue) }
        if let flagged = query.flagged { clause += " AND m.flagged=?"; values.append(flagged.databaseValue) }
        if let after = query.after { clause += " AND m.received_us>=?"; values.append(try IndexRecords.microseconds(after).databaseValue) }
        if let after = filter.receivedAfter { clause += " AND m.received_us>=?"; values.append(try IndexRecords.microseconds(after).databaseValue) }
        if let before = query.before { clause += " AND m.received_us<?"; values.append(try IndexRecords.microseconds(before).databaseValue) }
        if let attachment = query.hasAttachment {
            clause += " AND \(attachment ? "" : "NOT ")EXISTS(SELECT 1 FROM attachments t WHERE t.message_id=m.id AND t.account_id=m.account_id)"
        }
        if let thread { clause += " AND m.thread_id=?"; values.append(thread.description.databaseValue) }
        let eligibleClause = clause; let eligibleArguments = StatementArguments(values)
        if let pattern = query.ftsPattern {
            if query.terms.allSatisfy({ $0.value.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) }) {
                clause += " AND m.id IN (SELECT c.message_id FROM search_index JOIN search_content c ON c.rowid=search_index.rowid WHERE search_index MATCH ?)"
                let permittedPattern = filter.includeIndexedText ? pattern : "{subject sender recipients attachments} : (\(pattern))"
                values.append(permittedPattern.databaseValue)
            } else { clause += " AND 0" }
        }
        let matchedClause = clause; let matchedArguments = StatementArguments(values)
        let fingerprint = Self.fingerprint(filter: filter, scope: scope, thread: thread)
        if let cursor = page.cursor {
            let pieces = cursor.split(separator: "|", omittingEmptySubsequences: false)
            guard pieces.count == 4, pieces[0] == "1", let timestamp = Int64(pieces[1]),
                  (try? MessageID(string: String(pieces[2]))) != nil, pieces[3] == fingerprint else { throw MailFailure.invalidInput }
            clause += " AND (m.received_us<? OR (m.received_us=? AND m.id>?))"
            values += [timestamp.databaseValue, timestamp.databaseValue, String(pieces[2]).databaseValue]
        }
        values.append((page.limit + 1).databaseValue)
        let pagedClause = clause; let pagedArguments = StatementArguments(values)
        let queryAccounts = selectedAccounts.filter(query.matchesAccount)
        let synthetic = (queryAccounts.isEmpty ? selectedAccounts : queryAccounts).allSatisfy { $0.status == .demo }
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT m.* FROM messages m JOIN accounts a ON a.id=m.account_id WHERE \(pagedClause) ORDER BY m.received_us DESC,m.id ASC LIMIT ?", arguments: pagedArguments)
            let hasMore = rows.count > page.limit
            let items = try rows.prefix(page.limit).map { try IndexRecords.message($0, db: db) }
            let available = try Row.fetchOne(db, sql: """
                SELECT count(*) n,min(m.received_us) oldest,max(m.received_us) newest,
                       count(t.message_id) indexed_count,COALESCE(sum(t.truncated),0) truncated_count
                FROM messages m JOIN accounts a ON a.id=m.account_id
                LEFT JOIN message_text t ON t.message_id=m.id AND t.account_id=m.account_id
                WHERE \(eligibleClause)
                """, arguments: eligibleArguments)!
            let matchCount: Int
            if query.ftsPattern == nil { matchCount = available["n"] }
            else {
                matchCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages m JOIN accounts a ON a.id=m.account_id WHERE \(matchedClause)", arguments: matchedArguments) ?? 0
            }
            let oldest: Int64? = available["oldest"]; let newest: Int64? = available["newest"]
            let indexed: Int = filter.includeIndexedText ? available["indexed_count"] : 0
            let folderCoverage = try selectedFolders.map { folder in
                let row = try Row.fetchOne(db, sql: """
                    SELECT s.last_success,s.server_count,s.coverage,
                        EXISTS(SELECT 1 FROM full_mail_scans p WHERE p.account_id=f.account_id AND (p.scope='gmail' OR p.scope=f.id)) scan_pending,
                        (SELECT count(*) FROM message_locations l WHERE l.folder_id=f.id AND l.account_id=f.account_id) local_count
                    FROM folders f LEFT JOIN sync_states s ON s.account_id=f.account_id AND s.folder_id=f.id
                    WHERE f.id=? AND f.account_id=?
                    """, arguments: [folder.id.description, folder.accountID.description])!
                let last: Double? = row["last_success"]
                return SearchFolderCoverage(accountID: folder.accountID, folderID: folder.id, name: folder.name,
                    indexedCount: row["local_count"], serverCount: row["server_count"], lastSuccess: last.map(Date.init(timeIntervalSince1970:)), isComplete: (row["coverage"] as String?) == "fullMetadata" && !(row["scan_pending"] as Bool) && (row["server_count"] as Int?) == (row["local_count"] as Int))
            }
            let coverage = SearchCoverage(isSynthetic: synthetic, metadataOnly: indexed == 0, messageCount: matchCount,
                oldest: oldest.map { Date(timeIntervalSince1970: Double($0) / 1_000_000) },
                newest: newest.map { Date(timeIntervalSince1970: Double($0) / 1_000_000) },
                indexedTextCount: indexed, eligibleMessageCount: available["n"], truncatedTextCount: filter.includeIndexedText ? available["truncated_count"] : 0, folders: folderCoverage)
            let next: String?
            if hasMore, let last = items.last {
                next = "1|\(try IndexRecords.microseconds(last.receivedAt))|\(last.id)|\(fingerprint)"
            } else { next = nil }
            try Task.checkCancellation()
            return MessagePage(items: items, nextCursor: next, coverage: coverage)
        }
    }

    private nonisolated func scopeClause(_ scope: AccessScope) -> (String, [DatabaseValue]) {
        guard !scope.accountIDs.isEmpty, scope.folderIDs?.isEmpty != true else { return ("0", []) }
        var clause = "a.is_deleting=0 AND m.account_id IN (\(placeholders(scope.accountIDs.count)))"
        var values = scope.accountIDs.map { $0.description.databaseValue }
        if let folders = scope.folderIDs {
            clause += " AND EXISTS(SELECT 1 FROM message_locations l WHERE l.message_id=m.id AND l.account_id=m.account_id AND l.folder_id IN (\(placeholders(folders.count))))"
            values += folders.map { $0.description.databaseValue }
        }
        return (clause, values)
    }
    private nonisolated func validate(_ scope: AccessScope) throws {
        guard scope.accountIDs.count <= 100, (scope.folderIDs?.count ?? 0) <= 1000 else { throw MailFailure.invalidInput }
    }
    private nonisolated func placeholders(_ count: Int) -> String { Array(repeating: "?", count: count).joined(separator: ",") }
    private static func fingerprint(filter: MessageFilter, scope: AccessScope, thread: ThreadID?) -> String {
        // JSON length-prefixing prevents delimiter ambiguities in the query text.
        let after = filter.receivedAfter.map { String($0.timeIntervalSince1970) } ?? ""
        let accounts = scope.accountIDs.map(\.description).sorted().joined(separator: ",")
        let folders = scope.folderIDs.map { $0.map(\.description).sorted().joined(separator: ",") } ?? "*"
        let fields: [String] = [filter.text, filter.timeZoneID, filter.accountID?.description ?? "", filter.folderID?.description ?? "",
                      filter.role?.rawValue ?? "", String(filter.unreadOnly), String(filter.flaggedOnly), thread?.description ?? "",
                      String(filter.includeIndexedText), after, accounts, folders]
        let bytes = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
