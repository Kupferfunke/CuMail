import Foundation
import Security

/// A small, byte-identical helper owns the legacy Keychain entries. macOS uses
/// CDHash partitions even for self-signed certificates; a stable designated
/// requirement alone is insufficient. App updates authenticate to the helper
/// by certificate, while the helper retains its unchanged Keychain partition.
struct XPCKeychainAPI: KeychainAPI {
    let fingerprint: String
    init(fingerprint: String) throws {
        guard fingerprint.count == 40, fingerprint.allSatisfy(\.isHexDigit) else { throw KeychainFailure.unavailable }
        self.fingerprint = fingerprint
    }
    private final class Reply: @unchecked Sendable {
        let lock = NSLock()
        var result: (OSStatus, Data?) = (errSecNotAvailable, nil)
        func set(_ status: OSStatus, _ data: Data?) { lock.lock(); defer { lock.unlock() }; result = (status, data) }
        func get() -> (OSStatus, Data?) { lock.lock(); defer { lock.unlock() }; return result }
    }
    private func invoke(_ operation: String, query: [String: Any], value: Data? = nil) -> (OSStatus, Data?) {
        guard let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String else { return (errSecParam, nil) }
        let connection = NSXPCConnection(serviceName: "ch.kupferfunke.MikeMailHub.KeychainService")
        connection.remoteObjectInterface = NSXPCInterface(with: KeychainXPCProtocol.self)
        connection.setCodeSigningRequirement("identifier \"ch.kupferfunke.MikeMailHub.KeychainService\" and certificate leaf = H\"\(fingerprint)\"")
        connection.resume(); defer { connection.invalidate() }
        let output = Reply()
        guard let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler({ _ in output.set(errSecNotAvailable, nil) }) as? KeychainXPCProtocol else { return (errSecNotAvailable, nil) }
        proxy.request(operation, service: service, account: account, value: value,
            interactionAllowed: query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIAllow as String) {
                output.set($0, $1)
            }
        return output.get()
    }
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) { invoke("read", query: query) }
    func add(_ query: [String: Any]) -> OSStatus { invoke("add", query: query, value: query[kSecValueData as String] as? Data).0 }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { invoke("update", query: query, value: attributes[kSecValueData as String] as? Data).0 }
    func delete(_ query: [String: Any]) -> OSStatus { invoke("delete", query: query).0 }
}
