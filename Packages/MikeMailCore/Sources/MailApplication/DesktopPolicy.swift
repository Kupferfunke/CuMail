import Foundation
import MailDomain

public enum BackgroundSyncOutcome: Equatable, Sendable {
    case success, cancelled, authenticationRequired
    case retry(after: TimeInterval?)
}

/// One entry per account. Wake/network events cannot bypass provider backoff.
public struct BackgroundSyncSchedule: Sendable {
    public private(set) var nextAttempt: Date
    public private(set) var running = false
    public private(set) var authenticationRequired = false
    private var failures = 0
    public init(now: Date) { nextAttempt = now }
    public mutating func begin(now: Date) -> Bool {
        guard !running, !authenticationRequired, now >= nextAttempt else { return false }
        running = true; return true
    }
    public mutating func finish(_ outcome: BackgroundSyncOutcome, now: Date, jitter: TimeInterval = 0) {
        running = false
        switch outcome {
        case .success:
            failures = 0; authenticationRequired = false; nextAttempt = now.addingTimeInterval(120)
        case .cancelled: nextAttempt = max(nextAttempt, now.addingTimeInterval(30))
        case .authenticationRequired: authenticationRequired = true
        case .retry(let retryAfter):
            failures = min(failures + 1, 5)
            let backoff = min(1800, 120 * pow(2, Double(failures - 1)))
            let requested = retryAfter.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
            nextAttempt = now.addingTimeInterval(max(backoff, requested) + min(30, max(0, jitter)))
        }
    }
}

public struct InboxNotificationDelta: Sendable {
    public let newest: MailMessage
    public let count: Int
    public init(newest: MailMessage, count: Int) { self.newest = newest; self.count = count }
}

/// Persisted inside SQLCipher. At-most-once claims precede notification delivery.
/// Old imports and messages reappearing after UID resets are deliberately silent.
public struct InboxNotificationLedger: Codable, Sendable {
    public static let maximumEntries = 2000
    private struct Entry: Codable, Sendable { let id: MessageID; let receivedAt: Date }
    private var entries: [Entry] = []
    private var baseline = false
    private var notBefore: Date
    public init(now: Date) { notBefore = now }
    public var entryCount: Int { entries.count }

    public mutating func consume(_ messages: [MailMessage], now: Date) throws -> InboxNotificationDelta? {
        guard messages.count <= 1000, entries.count <= Self.maximumEntries,
              now.timeIntervalSince1970.isFinite, notBefore.timeIntervalSince1970.isFinite,
              Set(messages.map(\.id)).count == messages.count,
              Set(messages.map(\.accountID)).count <= 1,
              messages.allSatisfy({ $0.receivedAt.timeIntervalSince1970.isFinite })
        else { throw LocalStoreFailure.invalidInput }
        let known = Set(entries.map(\.id))
        let candidates = messages.filter {
            baseline && !known.contains($0.id) && $0.isUnread && $0.receivedAt >= notBefore && $0.receivedAt <= now.addingTimeInterval(300)
        }.sorted { $0.receivedAt == $1.receivedAt ? $0.id.description < $1.id.description : $0.receivedAt > $1.receivedAt }
        entries += messages.filter { !known.contains($0.id) }.map { Entry(id: $0.id, receivedAt: $0.receivedAt) }
        entries.sort { $0.receivedAt == $1.receivedAt ? $0.id.description < $1.id.description : $0.receivedAt > $1.receivedAt }
        if entries.count > Self.maximumEntries {
            // Evicted dates become ineligible, so bounded storage cannot cause replays.
            notBefore = max(notBefore, entries[Self.maximumEntries].receivedAt.addingTimeInterval(0.000001))
            entries = Array(entries.prefix(Self.maximumEntries))
        }
        baseline = true
        guard let newest = candidates.first else { return nil }
        return InboxNotificationDelta(newest: newest, count: candidates.count)
    }
}

public extension MailRoute {
    var url: URL {
        switch self {
        case .message(let id): URL(string: "cumail://message/\(id)")!
        case .thread(let id): URL(string: "cumail://thread/\(id)")!
        }
    }
}
