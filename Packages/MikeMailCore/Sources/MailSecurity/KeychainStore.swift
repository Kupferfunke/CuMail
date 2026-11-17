import Foundation
import Security
import MailDomain
import MailApplication

public enum KeychainFailure: Error, Equatable, Sendable {
    case lockedOrInteractionRequired, accessDenied, unavailable, missingDatabaseKey, invalidSecret
    case systemStatus(Int32)
}

// Kept internal so tests can exercise denial/locking without locking the user's keychain.
protocol KeychainAPI: Sendable {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ query: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}
struct SystemKeychainAPI: KeychainAPI {
    // AuthenticationUIFail alone does not suppress legacy login-Keychain ACL
    // prompts. Serialise the process-wide legacy switch and restore its value.
    private static let interactionLock = NSLock()
    private func perform<T>(_ query: [String: Any], _ action: () -> T) -> T {
        Self.interactionLock.lock()
        defer { Self.interactionLock.unlock() }
        var previous = DarwinBoolean(true)
        SecKeychainGetUserInteractionAllowed(&previous)
        let allowed = (query[kSecUseAuthenticationUI as String] as? String) == (kSecUseAuthenticationUIAllow as String)
        SecKeychainSetUserInteractionAllowed(allowed)
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return action()
    }
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        perform(query) {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }
    }
    func add(_ query: [String: Any]) -> OSStatus { perform(query) { SecItemAdd(query as CFDictionary, nil) } }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        perform(query) { SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
    }
    func delete(_ query: [String: Any]) -> OSStatus { perform(query) { SecItemDelete(query as CFDictionary) } }
}

/// SecItem API, file-based login keychain owned by the immutable signed XPC service.
/// No iCloud, access group, broad searches or fallback to a file.
/// UI interaction is disabled until explicitly enabled by the user's access button.
/// A provisioned release can opt into the Data Protection implementation explicitly.
public actor KeychainStore: CredentialStore, DatabaseKeyStore {
    public static let syntheticNamespace = "ch.kupferfunke.MikeMailHub.phase1.synthetic"
    private let service: String
    private let legacyService: String
    private let api: any KeychainAPI
    private let dataProtection: Bool
    private var userInteractionAllowed = false

    public func allowUserRequestedInteraction() { userInteractionAllowed = true }
    public func disallowUserInteraction() { userInteractionAllowed = false }

    public init(namespace: String = KeychainStore.syntheticNamespace, dataProtection: Bool = false) throws {
        let api: any KeychainAPI
        if !dataProtection, let fingerprint = Bundle.main.object(forInfoDictionaryKey: "MMHKeychainCertificateSHA1") as? String {
            api = try XPCKeychainAPI(fingerprint: fingerprint)
        } else { api = SystemKeychainAPI() } // SwiftPM / isolated Xcode test runners.
        try self.init(namespace: namespace, dataProtection: dataProtection, api: api)
    }
    init(namespace: String, dataProtection: Bool = false, api: any KeychainAPI) throws {
        guard namespace.hasPrefix("ch.kupferfunke.MikeMailHub."),
              namespace.count <= 180,
              namespace.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0) })
        else { throw KeychainFailure.invalidSecret }
        self.legacyService = namespace
        self.service = namespace + ".signed-v1"; self.dataProtection = dataProtection; self.api = api
    }

    private func query(_ account: String, legacy: Bool = false) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacy ? legacyService : service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: dataProtection,
            kSecUseAuthenticationUI as String: userInteractionAllowed ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        ]
    }
    private func account(_ reference: CredentialReference) -> String {
        "credential.\(reference.accountID).\(reference.purpose.rawValue)"
    }
    private func readAccount(_ account: String) throws -> Data? {
        if let current = try rawRead(account, legacy: false) { return current }
        guard let old = try rawRead(account, legacy: true) else { return nil }
        // A one-time grant for the old ad-hoc build may be "Allow once".
        // Create an entry owned by the unchanged XPC helper so subsequent
        // app builds do not inherit the old CDHash ACL. No broad ACL or plaintext.
        var item = query(account)
        item[kSecValueData as String] = old
        if dataProtection { item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
        let status = api.add(item)
        if status == errSecDuplicateItem {
            guard let current = try rawRead(account, legacy: false), current == old else { throw KeychainFailure.invalidSecret }
            return current
        }
        try check(status)
        return old
    }
    private func rawRead(_ account: String, legacy: Bool) throws -> Data? {
        var request = query(account, legacy: legacy)
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecReturnData as String] = true
        let (status, value) = api.copy(request)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let value else { throw KeychainFailure.invalidSecret }
        return value
    }
    public func read(_ reference: CredentialReference) throws -> Data? { try readAccount(account(reference)) }

    public func save(_ secret: Data, for reference: CredentialReference) throws {
        guard !secret.isEmpty, secret.count <= 64 * 1024 else { throw KeychainFailure.invalidSecret }
        let identity = query(account(reference))
        let status = api.update(identity, attributes: [kSecValueData as String: secret])
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = secret
            if dataProtection { item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
            let added = api.add(item)
            if added == errSecDuplicateItem {
                try check(api.update(identity, attributes: [kSecValueData as String: secret]))
            } else { try check(added) }
        } else { try check(status) }
    }
    public func delete(_ reference: CredentialReference) throws {
        try deleteAccount(account(reference))
    }
    private func deleteAccount(_ account: String) throws {
        for legacy in [false, true] {
            let status = api.delete(query(account, legacy: legacy))
            if status != errSecItemNotFound { try check(status) }
        }
    }

    public func databaseKey(createIfMissing: Bool) throws -> Data {
        if let existing = try readAccount("index-key.v1") {
            guard existing.count == 32 else { throw KeychainFailure.invalidSecret }
            return existing
        }
        guard createIfMissing else { throw KeychainFailure.missingDatabaseKey }
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try check(status)
        var item = query("index-key.v1")
        item[kSecValueData as String] = key
        if dataProtection { item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
        let added = api.add(item)
        if added == errSecDuplicateItem {
            key.resetBytes(in: 0..<key.count)
            guard let winner = try readAccount("index-key.v1"), winner.count == 32 else { throw KeychainFailure.invalidSecret }
            return winner
        }
        do { try check(added); return key }
        catch { key.resetBytes(in: 0..<key.count); throw error }
    }
    public func deleteDatabaseKey() throws { try deleteAccount("index-key.v1") }

    private func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        RedactedLog.record(.keychainUnavailable, outcome: .unavailable)
        switch status {
        case errSecInteractionNotAllowed, errSecInteractionRequired: throw KeychainFailure.lockedOrInteractionRequired
        case errSecAuthFailed, errSecMissingEntitlement, errSecUserCanceled: throw KeychainFailure.accessDenied
        case errSecNotAvailable: throw KeychainFailure.unavailable
        default: throw KeychainFailure.systemStatus(status)
        }
    }
}
