import Foundation
import GRDB
import MailApplication

enum WorkspaceMigration {
    static func hasDatabaseFiles(_ root: URL) -> Bool {
        PrivateFiles.databaseFiles(root.appendingPathComponent("mail-index.sqlite"))
            .contains { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func prepare(_ paths: WorkspacePaths, key: Data, preferences: Data) throws {
        let manager = FileManager.default
        if let legacy = paths.legacyRoot, hasDatabaseFiles(legacy) {
            guard !manager.fileExists(atPath: paths.root.path) else { throw LocalStoreFailure.conflictingDataLocations }
            try PrivateFiles.directory(legacy, excludedFromBackup: false)
            let source = legacy.appendingPathComponent("mail-index.sqlite")
            for file in PrivateFiles.databaseFiles(source) { try PrivateFiles.protect(file) }
            try RecoveryBackup.regularFile(source)
            let queue = try DatabaseQueue(path: source.path, configuration: IndexDatabase.configuration(key: key, readonly: true))
            do {
                let original = try RecoveryBackup.inventory(queue)
                let copy = try RecoveryBackup.create(from: queue, in: legacy.appendingPathComponent("Backups"), key: key, preferences: preferences)
                let verified = try RecoveryBackup.verify(copy.url, key: key)
                guard original.0 == verified.schema, original.1 == verified.counts else { throw LocalStoreFailure.invalidBackup }
                try queue.close()
                // Rename the entire closed workspace on the same volume. This
                // preserves the main database, WAL, settings and recovery material.
                // If rename fails, the original remains at the old location.
                try manager.moveItem(at: legacy, to: paths.root)
            } catch { try? queue.close(); throw error }
        }
        if let oldCache = paths.legacyCache, manager.fileExists(atPath: oldCache.path),
           !manager.fileExists(atPath: paths.cache.path) {
            try PrivateFiles.directory(oldCache)
            try manager.moveItem(at: oldCache, to: paths.cache)
        }
        try paths.prepare()
    }
}
