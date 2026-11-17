import Foundation
import Security

final class KeychainService: NSObject, KeychainXPCProtocol, NSXPCListenerDelegate {
    private let queue = DispatchQueue(label: "ch.kupferfunke.MikeMailHub.KeychainService")
    private let requirement: String
    init(requirement: String) { self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: KeychainXPCProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
    func request(_ operation: String, service: String, account: String, value: Data?, interactionAllowed: Bool, reply: @escaping (Int32, Data?) -> Void) {
        guard service.hasPrefix("ch.kupferfunke.MikeMailHub."), service.count <= 200,
              service.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0) }),
              account == "index-key.v1" || account.range(of: "^credential\\.[0-9a-fA-F-]{36}\\.(incomingPassword|outgoingPassword|oauthRefreshToken)$", options: .regularExpression) != nil,
              ["read", "add", "update", "delete"].contains(operation), (value?.count ?? 0) <= 65536 else { reply(errSecParam, nil); return }
        queue.async {
            var previous = DarwinBoolean(true)
            SecKeychainGetUserInteractionAllowed(&previous)
            SecKeychainSetUserInteractionAllowed(interactionAllowed)
            defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: false, kSecAttrSynchronizable as String: false,
                kSecUseAuthenticationUI as String: interactionAllowed ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail]
            switch operation {
            case "read":
                query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                reply(status, result as? Data)
            case "add":
                guard let value, !value.isEmpty else { reply(errSecParam, nil); return }
                query[kSecValueData as String] = value
                reply(SecItemAdd(query as CFDictionary, nil), nil)
            case "update":
                guard let value, !value.isEmpty else { reply(errSecParam, nil); return }
                reply(SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary), nil)
            case "delete": reply(SecItemDelete(query as CFDictionary), nil)
            default: reply(errSecParam, nil)
            }
        }
    }
}

guard let fingerprint = Bundle.main.object(forInfoDictionaryKey: "MMHKeychainCertificateSHA1") as? String,
      fingerprint.count == 40, fingerprint.allSatisfy(\.isHexDigit) else { exit(1) }
let requirement = "identifier \"ch.kupferfunke.MikeMailHub\" and certificate leaf = H\"\(fingerprint)\""
let delegate = KeychainService(requirement: requirement)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
