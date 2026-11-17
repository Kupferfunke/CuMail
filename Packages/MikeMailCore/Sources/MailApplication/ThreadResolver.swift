import Foundation
import MailDomain

/// Operates on IDs already parsed by the MIME library, never on raw headers or subjects.
public enum ThreadResolver {
    public struct Record: Sendable {
        public let message: MessageID
        public let ownID: String?
        public let replyTo: String?
        public let references: [String]
        public init(message: MessageID, ownID: String?, replyTo: String?, references: [String]) {
            self.message = message; self.ownID = ownID; self.replyTo = replyTo; self.references = references
        }
    }
    public struct Resolution: Sendable {
        public let messages: [MessageID: ThreadID]
        public let keys: [String: ThreadID]
    }
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = value.hasPrefix("<") && value.hasSuffix(">") ? String(value.dropFirst().dropLast()) : value
        guard !id.isEmpty, id.utf8.count <= 998,
              !id.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !id.contains("<"), !id.contains(">") else { return nil }
        return id
    }
    public static func resolve(_ records: [Record], account: AccountID, existing: [String: ThreadID] = [:]) throws -> Resolution {
        var parent: [String: String] = [:]
        var messageKeys: [MessageID: String] = [:]
        // Iterative union/find avoids recursion on malicious cycles or long reply chains.
        func root(_ key: String) -> String {
            var current = key
            while let next = parent[current], next != current { current = next }
            var node = key
            while let next = parent[node], next != node { parent[node] = current; node = next }
            return current
        }
        for record in records {
            let own = normalized(record.ownID).map { "id:" + $0 } ?? "local:" + record.message.description
            if parent[own] == nil { parent[own] = own }
            messageKeys[record.message] = own
            let refs = (record.references.prefix(100).compactMap { normalized($0) } + [normalized(record.replyTo)].compactMap { $0 })
            for value in refs {
                let key = "id:" + value
                if parent[key] == nil { parent[key] = key }
                let a = root(own), b = root(key)
                if a != b { parent[max(a,b)] = min(a,b) }
            }
        }
        var components: [String: [String]] = [:]
        for key in Array(parent.keys) { components[root(key), default: []].append(key) }
        var keys: [String: ThreadID] = [:]
        for (root, members) in components {
            // Reuse known identity when older parents arrive; merged threads use one stable survivor.
            let id = try members.compactMap { existing[$0] }.min { $0.description < $1.description }
                ?? IMAPIdentity.thread(account: account, key: root)
            for key in members { keys[key] = id }
        }
        return Resolution(messages: messageKeys.compactMapValues { keys[$0] }, keys: keys)
    }
}
