import Foundation
import MailApplication

public struct WorkspacePaths: Sendable {
    public let root: URL
    public let cache: URL
    public let legacyRoot: URL?
    public let legacyCache: URL?
    public var database: URL { root.appendingPathComponent("mail-index.sqlite") }
    public var backups: URL { root.appendingPathComponent("MigrationBackups", isDirectory: true) }
    public var recoveryBackups: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    public init(root: URL, cache: URL, legacyRoot: URL? = nil, legacyCache: URL? = nil) {
        self.root = root; self.cache = cache; self.legacyRoot = legacyRoot; self.legacyCache = legacyCache
    }

    public static func current() throws -> WorkspacePaths {
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let caches = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return WorkspacePaths(root: support.appendingPathComponent("CuMail", isDirectory: true),
                              cache: caches.appendingPathComponent("CuMail", isDirectory: true),
                              legacyRoot: support.appendingPathComponent("MikeMailHub/Phase1Synthetic", isDirectory: true),
                              legacyCache: caches.appendingPathComponent("MikeMailHub/Phase1Synthetic", isDirectory: true))
    }

    public static func synthetic() throws -> WorkspacePaths {
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let caches = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return WorkspacePaths(
            root: support.appendingPathComponent("MikeMailHub/Phase1Synthetic", isDirectory: true),
            cache: caches.appendingPathComponent("MikeMailHub/Phase1Synthetic", isDirectory: true))
    }
    func prepare() throws {
        try PrivateFiles.directory(root, excludedFromBackup: false)
        try PrivateFiles.directory(recoveryBackups, excludedFromBackup: false)
        for directory in [backups, cache] { try PrivateFiles.directory(directory) }
    }
}

enum PrivateFiles {
    static func directory(_ url: URL, excludedFromBackup: Bool = true) throws {
        guard url.isFileURL else { throw LocalStoreFailure.invalidInput }
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw LocalStoreFailure.invalidInput }
        } else {
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        var mutable = url
        var values = URLResourceValues(); values.isExcludedFromBackup = excludedFromBackup
        try mutable.setResourceValues(values)
    }
    static func protect(_ file: URL) throws {
        let manager = FileManager.default
        // attributesOfItem inspects the link itself, including a dangling link.
        guard let attributes = try? manager.attributesOfItem(atPath: file.path) else {
            guard !manager.fileExists(atPath: file.path) else { throw LocalStoreFailure.unavailable }
            return
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LocalStoreFailure.invalidInput }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func databaseFiles(_ url: URL) -> [URL] {
        [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm"),
         URL(fileURLWithPath: url.path + "-journal")]
    }
    static func size(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
