import Foundation
import CryptoKit
import MailDomain

public enum SearchFailure: Error, Equatable, Sendable, LocalizedError {
    case tooLong, tooManyTerms, quotes, missingValue, unknownField, invalidDate, invalidBoolean, duplicateField, dateRange
    case onlineFilterUnsupported, invalidCursor
    public var errorDescription: String? {
        switch self {
        case .tooLong: "Die Suche darf höchstens 1024 UTF-8-Bytes enthalten."
        case .tooManyTerms: "Bitte verwende höchstens 32 Suchbegriffe oder Filter."
        case .quotes: "Schliesse Anführungszeichen. Innerhalb sind nur \\\" und \\\\ als Escape erlaubt."
        case .missingValue: "Hinter jedem Suchfeld muss ein Wert stehen."
        case .unknownField: "Unbekanntes Suchfeld. Die Suchhilfe zeigt die unterstützten Filter."
        case .invalidDate: "Verwende ein gültiges Datum im Format JJJJ-MM-TT."
        case .invalidBoolean: "Verwende true oder false; bei is: sind unread, read, flagged und unflagged erlaubt."
        case .duplicateField: "Konto, Ordner, Datum und Status dürfen jeweils nur einmal vorkommen."
        case .dateRange: "«Vor» muss nach «Ab» liegen. Der erste Tag zählt mit, der letzte nicht."
        case .onlineFilterUnsupported: "Dateinamen- und Anhangfilter sind nur lokal verfügbar. Entferne diese Filter für die Serversuche."
        case .invalidCursor: "Diese Ergebnisse sind nicht mehr aktuell. Starte die Suche erneut."
        }
    }
}

public struct SearchTerm: Codable, Equatable, Sendable {
    public enum Field: String, Codable, Sendable { case any, sender, recipient, subject, filename }
    public let field: Field
    public let value: String
    public let phrase: Bool
    public init(field: Field = .any, value: String, phrase: Bool = false) {
        self.field = field; self.value = value; self.phrase = phrase
    }
}

/// Typed, bounded query. Dates are absolute local-day boundaries; search text is never a command.
public struct MailSearchQuery: Codable, Equatable, Sendable {
    public var terms: [SearchTerm] = []
    public var account: String?
    public var folder: String?
    public var after: Date?
    public var before: Date?
    public var unread: Bool?
    public var flagged: Bool?
    public var hasAttachment: Bool?
    public var timeZoneID: String
    public init(timeZone: TimeZone = .current) { timeZoneID = timeZone.identifier }
    public var isEmpty: Bool {
        terms.isEmpty && account == nil && folder == nil && after == nil && before == nil
            && unread == nil && flagged == nil && hasAttachment == nil
    }
    public var supportsOnline: Bool { hasAttachment == nil && !terms.contains { $0.field == .filename } }
    public func matchesDate(_ date: Date) -> Bool {
        (after.map { date >= $0 } ?? true) && (before.map { date < $0 } ?? true)
    }
    public func matchesAccount(_ value: MailAccount) -> Bool {
        account.map { Self.same($0, value.id.description) || Self.same($0, value.name) || Self.same($0, value.address.value) } ?? true
    }
    public func matchesFolder(_ value: MailFolder) -> Bool {
        folder.map { Self.same($0, value.id.description) || Self.same($0, value.name) || Self.same($0, value.providerID) } ?? true
    }
    public func validate() throws {
        guard terms.count <= 32 else { throw SearchFailure.tooManyTerms }
        let strings = terms.map(\.value) + [account, folder].compactMap { $0 }
        guard strings.reduce(0, { $0 + $1.utf8.count }) <= 1024,
              strings.allSatisfy({ !$0.isEmpty && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              TimeZone(identifier: timeZoneID) != nil,
              [after, before].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSince1970.isFinite }) else { throw MailFailure.invalidInput }
        if let after, let before, after >= before { throw SearchFailure.dateRange }
    }
    public var ftsPattern: String? {
        guard !terms.isEmpty else { return nil }
        return terms.map { term in
            let column: String
            switch term.field {
            case .any: column = ""
            case .sender: column = "sender : "
            case .recipient: column = "recipients : "
            case .subject: column = "subject : "
            case .filename: column = "attachments : "
            }
            return column + "\"" + term.value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" + (term.phrase ? "" : "*")
        }.joined(separator: " AND ")
    }
    public func fingerprint(context: [String]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(self)) ?? Data()
        let contextBytes = (try? encoder.encode(context)) ?? Data()
        return SHA256.hash(data: bytes + contextBytes).map { String(format: "%02x", $0) }.joined()
    }
    public static func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            == rhs.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    /// Synthetic in-memory preview only; production uses the encrypted FTS index.
    public func matchesMetadata(_ message: MailMessage) -> Bool {
        guard matchesDate(message.receivedAt), unread.map({ $0 == message.isUnread }) ?? true,
              flagged.map({ $0 == message.isFlagged }) ?? true,
              hasAttachment.map({ $0 == !message.attachments.isEmpty }) ?? true else { return false }
        let values: [SearchTerm.Field: String] = [
            .subject: message.subject, .sender: message.sender.name + " " + message.sender.address.value,
            .recipient: message.recipients.map { $0.name + " " + $0.address.value }.joined(separator: " "),
            .filename: message.attachments.map(\.filename).joined(separator: " ")
        ]
        func tokens(_ value: String) -> [String] {
            value.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "de_CH")).lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        return terms.allSatisfy { term in
            let needle = tokens(term.value); guard !needle.isEmpty else { return false }
            let haystacks = term.field == .any ? Array(values.values) : [values[term.field] ?? ""]
            return haystacks.contains { value in
                let haystack = tokens(value); guard haystack.count >= needle.count else { return false }
                return (0...haystack.count - needle.count).contains { start in
                    needle.indices.allSatisfy { index in
                        let actual = haystack[start + index]
                        return !term.phrase && index == needle.count - 1 ? actual.hasPrefix(needle[index]) : actual == needle[index]
                    }
                }
            }
        }
    }
}

public enum MailSearchParser {
    public static func parse(_ input: String, timeZone: TimeZone = .current) throws -> MailSearchQuery {
        guard input.utf8.count <= 1024 else { throw SearchFailure.tooLong }
        guard !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }) else { throw MailFailure.invalidInput }
        var result = MailSearchQuery(timeZone: timeZone)
        let chars = Array(input); var position = 0; var count = 0; var singletons = Set<String>()
        while position < chars.count {
            while position < chars.count && chars[position].isWhitespace { position += 1 }
            guard position < chars.count else { break }
            count += 1; guard count <= 32 else { throw SearchFailure.tooManyTerms }
            var field = ""
            if chars[position] != "\"" {
                let start = position
                while position < chars.count && !chars[position].isWhitespace && chars[position] != ":" && chars[position] != "\"" { position += 1 }
                if position < chars.count && chars[position] == ":" {
                    field = String(chars[start..<position]).lowercased(); position += 1
                } else { position = start }
            }
            guard position < chars.count && !chars[position].isWhitespace else { throw SearchFailure.missingValue }
            var value = ""; let quoted = chars[position] == "\""
            if quoted {
                position += 1; var closed = false
                while position < chars.count {
                    let char = chars[position]; position += 1
                    if char == "\"" { closed = true; break }
                    if char == "\\" {
                        guard position < chars.count, chars[position] == "\"" || chars[position] == "\\" else { throw SearchFailure.quotes }
                        value.append(chars[position]); position += 1
                    } else { value.append(char) }
                }
                guard closed, position == chars.count || chars[position].isWhitespace else { throw SearchFailure.quotes }
            } else {
                while position < chars.count && !chars[position].isWhitespace {
                    guard chars[position] != "\"" else { throw SearchFailure.quotes }
                    value.append(chars[position]); position += 1
                }
            }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SearchFailure.missingValue }
            func once(_ key: String) throws {
                guard singletons.insert(key).inserted else { throw SearchFailure.duplicateField }
            }
            switch field {
            case "", "query": result.terms.append(SearchTerm(value: value, phrase: quoted))
            case "from", "sender": result.terms.append(SearchTerm(field: .sender, value: value, phrase: quoted))
            case "to", "recipient": result.terms.append(SearchTerm(field: .recipient, value: value, phrase: quoted))
            case "subject": result.terms.append(SearchTerm(field: .subject, value: value, phrase: quoted))
            case "filename": result.terms.append(SearchTerm(field: .filename, value: value, phrase: quoted))
            case "account": try once("account"); result.account = value
            case "folder": try once("folder"); result.folder = value
            case "after": try once("after"); result.after = try day(value, timeZone: timeZone)
            case "before": try once("before"); result.before = try day(value, timeZone: timeZone)
            case "unread": try once("unread"); result.unread = try boolean(value)
            case "flagged": try once("flagged"); result.flagged = try boolean(value)
            case "has_attachment": try once("attachment"); result.hasAttachment = try boolean(value)
            case "has":
                guard value.lowercased() == "attachment" else { throw SearchFailure.unknownField }
                try once("attachment"); result.hasAttachment = true
            case "is":
                switch value.lowercased() {
                case "unread", "read": try once("unread"); result.unread = value.lowercased() == "unread"
                case "flagged", "unflagged": try once("flagged"); result.flagged = value.lowercased() == "flagged"
                default: throw SearchFailure.invalidBoolean
                }
            default: throw SearchFailure.unknownField
            }
        }
        try result.validate()
        return result
    }
    public static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    private static func boolean(_ text: String) throws -> Bool {
        switch text.lowercased() { case "true": true; case "false": false; default: throw SearchFailure.invalidBoolean }
    }
    public static func day(_ text: String, timeZone: TimeZone) throws -> Date {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              text.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) }),
              let year = Int(parts[0]), (1...9999).contains(year), let month = Int(parts[1]), let day = Int(parts[2]) else { throw SearchFailure.invalidDate }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else { throw SearchFailure.invalidDate }
        return calendar.startOfDay(for: date)
    }
}

/// Search-specific service keeps raw input parsing separate from UI and provider adapters.
public struct MailSearchService: Sendable {
    private let repository: any MailMetadataRepository
    public init(repository: any MailMetadataRepository) { self.repository = repository }
    public func search(_ filter: MessageFilter, page: PageRequest, scope: AccessScope) async throws -> MessagePage {
        _ = try filter.searchQuery()
        try Task.checkCancellation()
        return try await repository.messages(filter: filter, page: page, in: scope)
    }
}
