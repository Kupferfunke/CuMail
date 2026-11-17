import Foundation
import CryptoKit
import GRDB
import MailApplication

public struct LocalBackupInfo: Sendable, Equatable {
    public let url: URL
    public let createdAt: Date
    public let accountCount: Int
    public let messageCount: Int
    public let signatureCount: Int
    public let draftCount: Int
}

/// Consistent SQLCipher snapshot plus authenticated, encrypted preferences.
/// The database key stays in Keychain. This archive requires that same key to restore.
enum RecoveryBackup {
    struct Envelope: Codable {
        var format = 1
        let createdAt: Date
        let schema: Int
        let counts: [String: Int]
        let databaseSHA256: String
        let preferences: Data
    }
    static func envelopeKey(_ key: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key),
                             salt: Data("CuMail recovery v1".utf8), info: Data("preferences".utf8), outputByteCount: 32)
    }
    static func inventory(_ queue: DatabaseQueue) throws -> (Int, [String: Int]) {
        try queue.read { db in
            let schema = try IndexSchema.verify(db)
            guard schema > 0, try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok",
                  try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty,
                  try Row.fetchAll(db, sql: "PRAGMA cipher_integrity_check").isEmpty
            else { throw LocalStoreFailure.wrongKeyOrCorrupt }
            let names = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            var result: [String: Int] = [:]
            for name in names {
                let quoted = name.replacingOccurrences(of: "\"", with: "\"\"")
                result[name] = try Int.fetchOne(db, sql: "SELECT count(*) FROM \"\(quoted)\"") ?? 0
            }
            return (schema, result)
        }
    }
    static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty { hash.update(data: block) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func regularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LocalStoreFailure.invalidBackup }
    }
    static func create(from source: DatabaseQueue, in directory: URL, key: Data, preferences: Data,
                       now: Date = Date()) throws -> LocalBackupInfo {
        guard key.count == 32, preferences.count <= 4 * 1024 * 1024 else { throw LocalStoreFailure.invalidBackup }
        _ = try PropertyListSerialization.propertyList(from: preferences, format: nil)
        try PrivateFiles.directory(directory, excludedFromBackup: false)
        let token = UUID().uuidString.lowercased()
        let stage = directory.appendingPathComponent(".creating-\(token)", isDirectory: true)
        let final = directory.appendingPathComponent("CuMail-\(Int(now.timeIntervalSince1970))-\(token).cumailbackup", isDirectory: true)
        try PrivateFiles.directory(stage, excludedFromBackup: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let database = stage.appendingPathComponent("mail-index.sqlite")
        let target = try DatabaseQueue(path: database.path, configuration: IndexDatabase.configuration(key: key))
        do {
            try source.backup(to: target)
            let (schema, counts) = try inventory(target)
            try target.close()
            try PrivateFiles.protect(database)
            let envelope = Envelope(createdAt: now, schema: schema, counts: counts,
                                    databaseSHA256: try digest(database), preferences: preferences)
            let sealed = try AES.GCM.seal(JSONEncoder().encode(envelope), using: envelopeKey(key))
            let metadata = stage.appendingPathComponent("manifest.aesgcm")
            try sealed.combined!.write(to: metadata, options: .atomic)
            try PrivateFiles.protect(metadata)
            // Reopen exactly the files that will be retained before publishing.
            _ = try verify(stage, key: key)
            try FileManager.default.moveItem(at: stage, to: final)
            return info(envelope, url: final)
        } catch {
            try? target.close()
            throw error
        }
    }
    static func readEnvelope(_ url: URL, key: Data) throws -> Envelope {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw LocalStoreFailure.invalidBackup }
        let metadata = url.appendingPathComponent("manifest.aesgcm")
        try regularFile(metadata)
        guard PrivateFiles.size(metadata) <= 6 * 1024 * 1024 else { throw LocalStoreFailure.invalidBackup }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(contentsOf: metadata))
            let result = try JSONDecoder().decode(Envelope.self, from: AES.GCM.open(box, using: envelopeKey(key)))
            guard result.format == 1, result.createdAt.timeIntervalSince1970.isFinite,
                  result.schema > 0, result.schema <= IndexSchema.currentVersion,
                  (try PropertyListSerialization.propertyList(from: result.preferences, format: nil)) is [String: Any]
            else { throw LocalStoreFailure.invalidBackup }
            return result
        } catch { throw LocalStoreFailure.invalidBackup }
    }
    static func verify(_ url: URL, key: Data) throws -> Envelope {
        let envelope = try readEnvelope(url, key: key)
        let file = url.appendingPathComponent("mail-index.sqlite")
        try regularFile(file)
        guard try digest(file) == envelope.databaseSHA256 else { throw LocalStoreFailure.invalidBackup }
        let queue = try DatabaseQueue(path: file.path, configuration: IndexDatabase.configuration(key: key, readonly: true))
        defer { try? queue.close() }
        let (schema, counts) = try inventory(queue)
        guard schema == envelope.schema, counts == envelope.counts else { throw LocalStoreFailure.invalidBackup }
        return envelope
    }
    static func info(_ envelope: Envelope, url: URL) -> LocalBackupInfo {
        LocalBackupInfo(url: url, createdAt: envelope.createdAt, accountCount: envelope.counts["accounts"] ?? 0,
                        messageCount: envelope.counts["messages"] ?? 0, signatureCount: envelope.counts["signature_choices"] ?? 0,
                        draftCount: envelope.counts["local_drafts"] ?? 0)
    }
    static func list(in directory: URL, key: Data) throws -> [LocalBackupInfo] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "cumailbackup" }
            .compactMap { url in try? info(readEnvelope(url, key: key), url: url) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    static func prune(in directory: URL, key: Data) throws {
        // Retain the newest two snapshots and the newest snapshot of each of the
        // latest seven days (at most eight). Never purge ordinary schema backups here.
        let copies = try list(in: directory, key: key)
        var days: Set<Int> = []; var keep = Set(copies.prefix(2).map(\.url))
        for copy in copies {
            let day = Int(copy.createdAt.timeIntervalSince1970 / 86400)
            if !days.contains(day), days.count < 7 { days.insert(day); keep.insert(copy.url) }
        }
        for copy in copies where !keep.contains(copy.url) { try FileManager.default.removeItem(at: copy.url) }
    }
    static func removeOwnedBackups(in directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard url.pathExtension == "cumailbackup", url.lastPathComponent.hasPrefix("CuMail-"),
                  UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.suffix(36))) != nil else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
}

extension EncryptedMailRepository {
    func recoveryBackup(key: Data, preferences: Data, now: Date = Date()) throws -> LocalBackupInfo {
        let copy = try RecoveryBackup.create(from: database, in: paths.recoveryBackups, key: key, preferences: preferences, now: now)
        try RecoveryBackup.prune(in: paths.recoveryBackups, key: key)
        return copy
    }
}

/// A restore is only published into an empty destination. Existing data can never
/// be overwritten by this API. Callers must explicitly select a recovery workspace.
public enum LocalBackupRestore {
    public static func restore(_ backup: URL, to paths: WorkspacePaths, key: Data) throws -> Data {
        guard !FileManager.default.fileExists(atPath: paths.root.path) else { throw LocalStoreFailure.conflictingDataLocations }
        let envelope = try RecoveryBackup.verify(backup, key: key)
        let stage = paths.root.deletingLastPathComponent().appendingPathComponent(".CuMail-restore-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try PrivateFiles.directory(stage, excludedFromBackup: false)
        let file = stage.appendingPathComponent("mail-index.sqlite")
        try FileManager.default.copyItem(at: backup.appendingPathComponent("mail-index.sqlite"), to: file)
        try PrivateFiles.protect(file)
        guard try RecoveryBackup.digest(file) == envelope.databaseSHA256 else { throw LocalStoreFailure.invalidBackup }
        try FileManager.default.moveItem(at: stage, to: paths.root)
        return envelope.preferences
    }
}
