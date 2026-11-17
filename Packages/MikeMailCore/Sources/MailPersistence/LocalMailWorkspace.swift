import Foundation
import MailDomain
import MailApplication
import MailSecurity

/// Coordinates durable deletion intent with the index, app-owned Keychain entries and cache.
/// The application stops content work and serializes provider operations before local maintenance.
public actor LocalMailWorkspace: LocalMailMaintenance {
    public nonisolated let repository: EncryptedMailRepository
    public nonisolated let temporaryFiles: ManagedTemporaryStore
    private let credentials: any CredentialStore & DatabaseKeyStore
    private let syntheticSnapshot: MailSnapshot
    private var maintenanceInProgress = false

    private init(repository: EncryptedMailRepository, temporaryFiles: ManagedTemporaryStore,
                 credentials: any CredentialStore & DatabaseKeyStore, snapshot: MailSnapshot) {
        self.repository = repository; self.temporaryFiles = temporaryFiles
        self.credentials = credentials; syntheticSnapshot = snapshot
    }
    public static func open(paths: WorkspacePaths, credentials: any CredentialStore & DatabaseKeyStore,
                            syntheticSnapshot: MailSnapshot, preferences: Data? = nil) async throws -> LocalMailWorkspace {
        let existing = WorkspaceMigration.hasDatabaseFiles(paths.root) || paths.legacyRoot.map(WorkspaceMigration.hasDatabaseFiles) == true
        let key = try await credentials.databaseKey(createIfMissing: !existing)
        let preferences = try preferences ?? PropertyListSerialization.data(fromPropertyList: [String: String](), format: .binary, options: 0)
        try WorkspaceMigration.prepare(paths, key: key, preferences: preferences)
        let repository = try EncryptedMailRepository(paths: paths, key: key)
        do {
            let cache = try ManagedTemporaryStore(root: paths.cache)
            try await cache.recover()
            let workspace = LocalMailWorkspace(repository: repository, temporaryFiles: cache, credentials: credentials, snapshot: syntheticSnapshot)
            try await workspace.resumeDeletions()
            try await repository.finishMaintenance()
            try await repository.seedIfNeeded(syntheticSnapshot)
            try await repository.recoverInterruptedSubmissions()
            return workspace
        } catch {
            try? await repository.close()
            throw error
        }
    }
    public func settings(for account: AccountID) async throws -> AccountSettings { try await repository.settings(for: account) }
    public func saveSettings(_ settings: AccountSettings) async throws {
        try beginMaintenance(); defer { maintenanceInProgress = false }
        try await repository.saveSettings(settings)
    }
    public func storeExtract(_ text: String, for message: MessageID, account: AccountID) async throws {
        try await storeExtract(text, for: message, account: account, source: .plainText)
    }
    public func storeExtract(_ text: String, for message: MessageID, account: AccountID, source: TextExtractionSource) async throws {
        try beginMaintenance(); defer { maintenanceInProgress = false }
        try await repository.storeExtract(text, for: message, account: account, source: source)
    }
    public func clearExtracts(account: AccountID) async throws {
        try beginMaintenance(); defer { maintenanceInProgress = false }
        try await repository.clearExtracts(account: account)
    }
    public func removeAccount(_ account: AccountID) async throws {
        try beginMaintenance(); defer { maintenanceInProgress = false }
        try await repository.markAccountForRemoval(account)
        try await resumeDeletions()
        RedactedLog.record(.accountRemoved)
    }
    public func clearLocalData() async throws {
        try beginMaintenance(); defer { maintenanceInProgress = false }
        // Explicitly clearing all local data also clears the app-owned recovery
        // copies. Ordinary sync and metadata cleanup never purge these backups.
        try RecoveryBackup.removeOwnedBackups(in: backupDirectory)
        // One transaction records the entire intent before any external cleanup starts.
        try await repository.markAllAccountsForRemoval()
        try await resumeDeletions()
        try await temporaryFiles.clear()
        try await repository.finishMaintenance()
        RedactedLog.record(.localDataCleared)
    }
    public func rebuildIndex() async throws {
        try beginMaintenance(); defer { maintenanceInProgress = false }
        try await resumeDeletions()
        let ids = Set(try await repository.allAccountIDsIncludingPending())
        let snapshot = try MailSnapshot(
            accounts: syntheticSnapshot.accounts.filter { ids.contains($0.id) },
            folders: syntheticSnapshot.folders.filter { ids.contains($0.accountID) },
            threads: syntheticSnapshot.threads.filter { ids.contains($0.accountID) },
            messages: syntheticSnapshot.messages.filter { ids.contains($0.accountID) })
        try await temporaryFiles.clear()
        try await repository.replaceMetadata(with: snapshot)
        RedactedLog.record(.indexRebuilt)
    }
    public func restoreSyntheticData() async throws {
        try beginMaintenance(); defer { maintenanceInProgress = false }
        try await resumeDeletions()
        try await repository.restoreSyntheticData(syntheticSnapshot)
    }
    public func summary() async throws -> LocalIndexSummary {
        try await temporaryFiles.cleanup()
        return try await repository.summary(temporaryBytes: temporaryFiles.byteCount())
    }
    public func close() async throws {
        try beginMaintenance(); defer { maintenanceInProgress = false }
        try await repository.close()
    }
    public nonisolated var dataDirectory: URL { repository.paths.root }
    public nonisolated var backupDirectory: URL { repository.paths.recoveryBackups }
    public func recoveryBackups() async throws -> [LocalBackupInfo] {
        let key = try await credentials.databaseKey(createIfMissing: false)
        return try RecoveryBackup.list(in: backupDirectory, key: key)
    }
    public func createRecoveryBackup(preferences: Data) async throws -> LocalBackupInfo {
        try beginMaintenance(); defer { maintenanceInProgress = false }
        let key = try await credentials.databaseKey(createIfMissing: false)
        return try await repository.recoveryBackup(key: key, preferences: preferences)
    }
    public func verifyRecoveryBackup(_ backup: LocalBackupInfo) async throws -> LocalBackupInfo {
        let key = try await credentials.databaseKey(createIfMissing: false)
        return RecoveryBackup.info(try RecoveryBackup.verify(backup.url, key: key), url: backup.url)
    }
    private func beginMaintenance() throws {
        guard !maintenanceInProgress else { throw LocalStoreFailure.cleanupPending }
        maintenanceInProgress = true
    }
    private func resumeDeletions() async throws {
        for account in try await repository.pendingAccountRemovals() {
            for purpose in [CredentialReference.Purpose.incomingPassword, .outgoingPassword, .oauthRefreshToken] {
                try await credentials.delete(CredentialReference(accountID: account, purpose: purpose))
            }
            try await temporaryFiles.removeAccount(account)
            try await repository.finishAccountRemoval(account)
        }
    }
}
