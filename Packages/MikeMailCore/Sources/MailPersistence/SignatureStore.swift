import Foundation
import GRDB
import MailApplication
import MailDomain

extension EncryptedMailRepository: SignatureRepository {
    public func signature(account: AccountID) async throws -> MailSignature? {
        try await signatureLibrary(account: account).defaultSignature?.content
    }
    public func signatureLibrary(account: AccountID) async throws -> SignatureLibrary {
        try await database.read { db in
            try Self.checkSignatureAccount(account, db: db)
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM signature_choices WHERE account_id=? ORDER BY position,id", arguments: [account.description])
            let entries = try rows.map { row -> NamedMailSignature in
                guard let id = UUID(uuidString: row["id"]) else { throw ComposeFailure.invalidHeader }
                return NamedMailSignature(id: id, name: row["name"], content: try JSONDecoder().decode(MailSignature.self, from: row["payload"]))
            }
            let defaultID = rows.first { ($0["is_default"] as Bool) }.flatMap { UUID(uuidString: $0["id"]) }
            let library = SignatureLibrary(entries: entries, defaultID: defaultID)
            try library.validate()
            return library
        }
    }
    public func saveSignature(_ signature: MailSignature?, account: AccountID) async throws {
        var library = try await signatureLibrary(account: account)
        if let signature {
            if let index = library.entries.firstIndex(where: { $0.id == library.defaultID }) { library.entries[index].content = signature }
            else {
                let entry = NamedMailSignature(name: "Standard", content: signature)
                library.entries.append(entry); library.defaultID = entry.id
            }
        } else {
            library.entries.removeAll { $0.id == library.defaultID }
            library.defaultID = library.entries.first?.id
        }
        try saveSignatureLibrary(library, account: account)
    }
    public func saveSignatureLibrary(_ library: SignatureLibrary, account: AccountID) throws {
        try library.validate()
        try database.write { db in
            try Self.checkSignatureAccount(account, db: db)
            for entry in library.entries {
                if let owner = try String.fetchOne(db, sql: "SELECT account_id FROM signature_choices WHERE id=?", arguments: [entry.id.uuidString.lowercased()]), owner != account.description { throw ComposeFailure.accountMismatch }
            }
            try db.execute(sql: "DELETE FROM signature_choices WHERE account_id=?", arguments: [account.description])
            for (position, entry) in library.entries.enumerated() {
                try db.execute(sql: "INSERT INTO signature_choices(id,account_id,name,payload,position,is_default) VALUES(?,?,?,?,?,?)",
                    arguments: [entry.id.uuidString.lowercased(), account.description, entry.name, try JSONEncoder().encode(entry.content), position, entry.id == library.defaultID])
            }
        }
        try protectFiles()
    }
    public func folderOrder(account: AccountID) throws -> [FolderID] {
        try database.read { db in
            try Self.checkSignatureAccount(account, db: db)
            return try Data.fetchOne(db, sql: "SELECT payload FROM folder_order WHERE account_id=?", arguments: [account.description])
                .map { try JSONDecoder().decode([FolderID].self, from: $0) } ?? []
        }
    }
    public func saveFolderOrder(_ order: [FolderID], account: AccountID) throws {
        guard order.count <= 500, Set(order).count == order.count else { throw LocalStoreFailure.invalidInput }
        try database.write { db in
            try Self.checkSignatureAccount(account, db: db)
            let current = Set(try String.fetchAll(db, sql: "SELECT id FROM folders WHERE account_id=?", arguments: [account.description]))
            guard Set(order.map(\.description)).isSubset(of: current) else { throw MailFailure.permissionDenied }
            try db.execute(sql: "INSERT INTO folder_order(account_id,payload) VALUES(?,?) ON CONFLICT(account_id) DO UPDATE SET payload=excluded.payload",
                arguments: [account.description, try JSONEncoder().encode(order)])
        }
        try protectFiles()
    }
    private static func checkSignatureAccount(_ account: AccountID, db: Database) throws {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM accounts WHERE id=? AND is_deleting=0)", arguments: [account.description]) == true else { throw ComposeFailure.accountMismatch }
    }
}
