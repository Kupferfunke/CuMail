import Foundation

/// Private embedded service. The listener and client both verify the peer's
/// exact bundle identifier and pinned signing certificate before exchanging data.
@objc(MMHKeychainServiceProtocol)
public protocol KeychainXPCProtocol {
    func request(_ operation: String, service: String, account: String, value: Data?,
                 interactionAllowed: Bool, reply: @escaping (Int32, Data?) -> Void)
}
