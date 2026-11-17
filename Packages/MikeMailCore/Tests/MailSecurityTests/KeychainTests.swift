import Foundation
import Testing
import Security
import MailDomain
import MailApplication
@testable import MailSecurity

private struct DeniedAPI: KeychainAPI {
    let status: OSStatus
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) { (status, nil) }
    func add(_ query: [String: Any]) -> OSStatus { status }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { status }
    func delete(_ query: [String: Any]) -> OSStatus { status }
}

private struct InteractionAPI: KeychainAPI {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        guard query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIAllow as String else {
            return (errSecInteractionNotAllowed, nil)
        }
        guard (query[kSecAttrService as String] as? String)?.hasPrefix("ch.kupferfunke.MikeMailHub.tests.") == true,
              query[kSecAttrAccount as String] as? String == "index-key.v1" else { return (errSecAuthFailed, nil) }
        return (errSecSuccess, Data(repeating: 0x72, count: 32))
    }
    func add(_ query: [String: Any]) -> OSStatus { errSecAuthFailed }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { errSecAuthFailed }
    func delete(_ query: [String: Any]) -> OSStatus { errSecAuthFailed }
}

private final class MigrationAPI: KeychainAPI, @unchecked Sendable {
    // Accessed only by the one KeychainStore actor under test.
    let namespace: String
    var migrated: Data?
    var legacyReads = 0
    init(namespace: String) { self.namespace = namespace }
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        guard query[kSecAttrAccount as String] as? String == "index-key.v1" else { return (errSecItemNotFound, nil) }
        if query[kSecAttrService as String] as? String == namespace + ".signed-v1" {
            return migrated.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }
        guard query[kSecAttrService as String] as? String == namespace else { return (errSecAuthFailed, nil) }
        legacyReads += 1
        return (errSecSuccess, Data(repeating: 0x29, count: 32))
    }
    func add(_ query: [String: Any]) -> OSStatus {
        guard query[kSecAttrService as String] as? String == namespace + ".signed-v1" else { return errSecAuthFailed }
        migrated = query[kSecValueData as String] as? Data; return errSecSuccess
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { errSecAuthFailed }
    func delete(_ query: [String: Any]) -> OSStatus { errSecAuthFailed }
}

struct KeychainTests {
    @Test func adHocEntryMigratesOnceIntoStableAppOwnedNamespace() async throws {
        let namespace = "ch.kupferfunke.MikeMailHub.tests.\(UUID())"
        let api = MigrationAPI(namespace: namespace), store = try KeychainStore(namespace: namespace, api: api)
        #expect(try await store.databaseKey(createIfMissing: false) == Data(repeating: 0x29, count: 32))
        #expect(try await store.databaseKey(createIfMissing: false) == Data(repeating: 0x29, count: 32))
        #expect(api.legacyReads == 1 && api.migrated != nil)
    }
    @Test func interactiveAccessRequiresExplicitUserActionAndKeepsTheExactItemScope() async throws {
        let store = try KeychainStore(namespace: "ch.kupferfunke.MikeMailHub.tests.\(UUID())", api: InteractionAPI())
        await #expect(throws: KeychainFailure.lockedOrInteractionRequired) { try await store.databaseKey(createIfMissing: false) }
        await store.allowUserRequestedInteraction()
        #expect(try await store.databaseKey(createIfMissing: false) == Data(repeating: 0x72, count: 32))
        await store.disallowUserInteraction()
        await #expect(throws: KeychainFailure.lockedOrInteractionRequired) { try await store.databaseKey(createIfMissing: false) }
        await store.allowUserRequestedInteraction()
        await #expect(throws: KeychainFailure.accessDenied) {
            try await store.read(CredentialReference(accountID: AccountID(), purpose: .incomingPassword))
        }
    }
    @Test func unavailableAndLockedKeychainsFailWithoutFallback() async throws {
        let reference = CredentialReference(accountID: try AccountID(), purpose: .incomingPassword)
        for (status, expected) in [(errSecInteractionNotAllowed, KeychainFailure.lockedOrInteractionRequired),
                                   (errSecMissingEntitlement, .accessDenied), (errSecNotAvailable, .unavailable)] {
            let store = try KeychainStore(namespace: "ch.kupferfunke.MikeMailHub.tests.\(UUID())", api: DeniedAPI(status: status))
            await #expect(throws: expected) { try await store.read(reference) }
            await #expect(throws: expected) { try await store.databaseKey(createIfMissing: true) }
            await #expect(throws: expected) { try await store.delete(reference) }
        }
    }
    @Test func missingExistingDatabaseKeyIsNotRegenerated() async throws {
        let store = try KeychainStore(namespace: "ch.kupferfunke.MikeMailHub.tests.\(UUID())", api: DeniedAPI(status: errSecItemNotFound))
        await #expect(throws: KeychainFailure.missingDatabaseKey) { try await store.databaseKey(createIfMissing: false) }
    }
    @Test func logRecordsOnlyContainClosedEventFields() {
        for event in MailLogEvent.allCases {
            let record = RedactedLogRecord(event, outcome: .denied, count: Int.max)
            #expect(record.description == "event=\(event.rawValue) outcome=denied count=1000000000")
            #expect(!record.description.contains("@"))
        }
        #expect(RedactedLogRecord(.indexOpened, count: -1).count == 0)
    }
    /// Opt-in explicitly creates and deletes only new UUID-scoped synthetic keychain items.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIKE_MAIL_KEYCHAIN_TESTS"] == "1"))
    func realKeychainRoundTripIsolatedByNamespaceAccountAndPurpose() async throws {
        let namespace = "ch.kupferfunke.MikeMailHub.tests.\(UUID())"
        let first = try KeychainStore(namespace: namespace)
        let a = try AccountID(), b = try AccountID()
        let incoming = CredentialReference(accountID: a, purpose: .incomingPassword)
        let outgoing = CredentialReference(accountID: a, purpose: .outgoingPassword)
        let other = CredentialReference(accountID: b, purpose: .incomingPassword)
        do {
            try await first.save(Data("synthetic-incoming-only".utf8), for: incoming)
            try await first.save(Data("synthetic-outgoing-only".utf8), for: outgoing)
            try await first.save(Data("synthetic-other-account".utf8), for: other)
            let key = try await first.databaseKey(createIfMissing: true)
            #expect(key.count == 32)
            let reopened = try KeychainStore(namespace: namespace)
            #expect(try await reopened.read(incoming) == Data("synthetic-incoming-only".utf8))
            #expect(try await reopened.databaseKey(createIfMissing: false) == key)
            try await reopened.save(Data("synthetic-updated".utf8), for: incoming)
            #expect(try await first.read(incoming) == Data("synthetic-updated".utf8))
            try await reopened.delete(incoming)
            #expect(try await first.read(incoming) == nil)
            #expect(try await first.read(outgoing) == Data("synthetic-outgoing-only".utf8))
            #expect(try await first.read(other) == Data("synthetic-other-account".utf8))
            for reference in [incoming,outgoing,other] { try await first.delete(reference) }
            try await first.deleteDatabaseKey()
            await #expect(throws: KeychainFailure.missingDatabaseKey) { try await reopened.databaseKey(createIfMissing: false) }
        } catch {
            for reference in [incoming,outgoing,other] { try? await first.delete(reference) }
            try? await first.deleteDatabaseKey()
            throw error
        }
    }
}
