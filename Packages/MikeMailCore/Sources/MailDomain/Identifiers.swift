import Foundation

public enum DomainError: Error, Equatable, Sendable {
    case invalidID, invalidAddress, invalidLocator, invalidSize
    case duplicateID, unknownAccount, crossAccountReference, inconsistentProvider
}

/// Local identity. Provider identifiers deliberately never enter this type.
public struct EntityID<Tag: Sendable>: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ uuid: UUID = UUID()) throws {
        guard uuid.uuidString != "00000000-0000-0000-0000-000000000000" else { throw DomainError.invalidID }
        rawValue = uuid
    }

    public init(string: String) throws {
        guard string.utf8.count == 36, let value = UUID(uuidString: string) else { throw DomainError.invalidID }
        try self.init(value)
    }

    public var description: String { rawValue.uuidString.lowercased() }

    public init(from decoder: any Decoder) throws {
        try self.init(string: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public enum AccountTag: Sendable {}
public enum MessageTag: Sendable {}
public enum ThreadTag: Sendable {}
public enum FolderTag: Sendable {}
public enum AttachmentTag: Sendable {}
public typealias AccountID = EntityID<AccountTag>
public typealias MessageID = EntityID<MessageTag>
public typealias ThreadID = EntityID<ThreadTag>
public typealias FolderID = EntityID<FolderTag>
public typealias AttachmentID = EntityID<AttachmentTag>

public struct EmailAddress: Hashable, Codable, Sendable {
    public let value: String
    /// UI/domain guard only; not a MIME or RFC mailbox parser.
    public init(_ value: String) throws {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard value.utf8.count <= 254, parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) })
        else { throw DomainError.invalidAddress }
        self.value = value
    }
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(value) }
}
