import Foundation
import GRDB
import MailApplication
import MailSecurity

enum IndexDatabase {
    static func configuration(key: Data, readonly: Bool = false) throws -> Configuration {
        guard key.count == 32 else { throw LocalStoreFailure.missingKey }
        var configuration = Configuration()
        configuration.readonly = readonly
        configuration.foreignKeysEnabled = true
        configuration.publicStatementArguments = false
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.usePassphrase(key)
            guard let version = try String.fetchOne(db, sql: "PRAGMA cipher_version"), !version.isEmpty
            else { throw LocalStoreFailure.unavailable }
            _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master")
            // Bound the decrypted page cache to 32 MiB. The default 2 MiB repeatedly
            // decrypts the same index pages during scoped counts and FTS joins.
            try db.execute(sql: "PRAGMA cache_size=-32768; PRAGMA temp_store=MEMORY; PRAGMA secure_delete=ON; PRAGMA cipher_memory_security=ON;")
        }
        return configuration
    }

    static func open(paths: WorkspacePaths, key: Data) throws -> DatabaseQueue {
        try paths.prepare()
        for file in PrivateFiles.databaseFiles(paths.database) { try PrivateFiles.protect(file) }
        let queue: DatabaseQueue
        do { queue = try DatabaseQueue(path: paths.database.path, configuration: configuration(key: key)) }
        catch let error as LocalStoreFailure { throw error }
        catch { throw LocalStoreFailure.wrongKeyOrCorrupt }
        do {
            try PrivateFiles.protect(paths.database)
            let version = try queue.read { try IndexSchema.verify($0) }
            if version > 0, version < IndexSchema.currentVersion {
                try backup(queue, paths: paths, key: key)
            }
            try IndexSchema.migrator().migrate(queue)
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode=WAL")
                guard try IndexSchema.verify(db) == IndexSchema.currentVersion else { throw LocalStoreFailure.incompatibleSchema }
                guard try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok",
                      try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty
                else { throw LocalStoreFailure.wrongKeyOrCorrupt }
            }
            for file in PrivateFiles.databaseFiles(paths.database) { try PrivateFiles.protect(file) }
            RedactedLog.record(.indexOpened)
            return queue
        } catch {
            try? queue.close()
            if let safe = error as? LocalStoreFailure { throw safe }
            throw LocalStoreFailure.unavailable
        }
    }

    static func backup(_ queue: DatabaseQueue, paths: WorkspacePaths, key: Data) throws {
        let destination = paths.backups.appendingPathComponent("before-migration-\(UUID().uuidString.lowercased()).sqlite")
        let copy = try DatabaseQueue(path: destination.path, configuration: configuration(key: key))
        do {
            try queue.backup(to: copy)
            try copy.close()
            try PrivateFiles.protect(destination)
        } catch {
            try? copy.close()
            // A failed backup is never used as a valid recovery artifact.
            for file in PrivateFiles.databaseFiles(destination) { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }

    static func purgeMigrationBackups(_ paths: WorkspacePaths) throws {
        // Entirely app-owned directory; only our generated filenames qualify.
        let files = try FileManager.default.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: [.isSymbolicLinkKey])
        for file in files where file.lastPathComponent.hasPrefix("before-migration-") && file.pathExtension == "sqlite" {
            let id = file.deletingPathExtension().lastPathComponent.dropFirst("before-migration-".count)
            guard UUID(uuidString: String(id)) != nil else { continue }
            for owned in PrivateFiles.databaseFiles(file) where FileManager.default.fileExists(atPath: owned.path) {
                try FileManager.default.removeItem(at: owned)
            }
        }
    }
}
