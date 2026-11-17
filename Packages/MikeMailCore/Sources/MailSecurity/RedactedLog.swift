import Foundation
import OSLog

public enum MailLogEvent: String, Sendable, CaseIterable {
    case indexOpened, migrationCompleted, indexRebuilt, localDataCleared, accountRemoved
    case settingsSaved, cacheCleaned, operationFailed, keychainUnavailable
}
public enum MailLogOutcome: String, Sendable { case success, unavailable, denied, invalid, failed }

/// Closed fields only: callers cannot accidentally pass an address, query, subject, secret or SQL error.
public struct RedactedLogRecord: Sendable, CustomStringConvertible {
    public let event: MailLogEvent
    public let outcome: MailLogOutcome
    public let count: Int
    public init(_ event: MailLogEvent, outcome: MailLogOutcome = .success, count: Int = 0) {
        self.event = event; self.outcome = outcome; self.count = min(max(count, 0), 1_000_000_000)
    }
    public var description: String { "event=\(event.rawValue) outcome=\(outcome.rawValue) count=\(count)" }
}
public enum RedactedLog {
    private static let logger = Logger(subsystem: "ch.kupferfunke.MikeMailHub", category: "local-store")
    public static func record(_ event: MailLogEvent, outcome: MailLogOutcome = .success, count: Int = 0) {
        let record = RedactedLogRecord(event, outcome: outcome, count: count)
        logger.notice("\(record.description, privacy: .public)")
    }
}
