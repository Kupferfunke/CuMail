import Foundation

public struct UsedRecipient: Sendable, Equatable, Identifiable {
    public let address: String
    public let name: String
    public let useCount: Int
    public let lastUsed: Date
    public var id: String { address.lowercased() }
    public init(address: String, name: String = "", useCount: Int, lastUsed: Date) {
        self.address = address; self.name = name; self.useCount = useCount; self.lastUsed = lastUsed
    }
}

/// Local composition only; not exposed through the assistant's read scope.
public protocol RecipientHistoryRepository: Sendable {
    func recipientHistory() async throws -> [UsedRecipient]
}
