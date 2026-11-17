import Foundation
import Testing
import MailDomain
import MailApplication
import MailDemo

struct DesktopPolicyTests {
    @Test func pollingCoalescesAndRespectsBackoffAndAuthenticationPause() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var schedule = BackgroundSyncSchedule(now: now)
        #expect({ schedule.begin(now: now) }())
        #expect({ !schedule.begin(now: now.addingTimeInterval(999)) }())
        schedule.finish(.retry(after: 600), now: now, jitter: 20)
        #expect({ !schedule.begin(now: now.addingTimeInterval(619)) }())
        #expect({ schedule.begin(now: now.addingTimeInterval(620)) }())
        schedule.finish(.authenticationRequired, now: now)
        #expect({ !schedule.begin(now: now.addingTimeInterval(99_999)) }())
        schedule.finish(.success, now: now)
        #expect({ !schedule.begin(now: now.addingTimeInterval(119)) }())
        #expect({ schedule.begin(now: now.addingTimeInterval(120)) }())
    }
    @Test func initialImportIsSilentAndClaimsSurviveSerialization() throws {
        let base = try SyntheticFixtures.make().snapshot.messages[0], now = Date()
        var ledger = InboxNotificationLedger(now: now)
        let original = try copy(base, at: now)
        #expect(try ledger.consume([original], now: now) == nil)
        let fresh = try copy(base, at: now.addingTimeInterval(10))
        let old = try copy(base, at: now.addingTimeInterval(-100))
        let future = try copy(base, at: now.addingTimeInterval(10_000))
        let delta = try ledger.consume([original, fresh, old, future], now: now.addingTimeInterval(11))
        #expect(delta?.count == 1 && delta?.newest.id == fresh.id)
        ledger = try JSONDecoder().decode(InboxNotificationLedger.self, from: JSONEncoder().encode(ledger))
        #expect(try ledger.consume([original, fresh], now: now.addingTimeInterval(20)) == nil)
        #expect(try ledger.consume([], now: now.addingTimeInterval(30)) == nil)
        #expect(try ledger.consume([fresh], now: now.addingTimeInterval(40)) == nil)
    }
    @Test func ledgerIsBoundedWithoutReplayingEvictedMessages() throws {
        let base = try SyntheticFixtures.make().snapshot.messages[0], now = Date()
        var ledger = InboxNotificationLedger(now: now)
        _ = try ledger.consume([], now: now)
        var first: MailMessage?
        for batch in 0..<3 {
            let items = try (0..<1000).map { index in try copy(base, at: now.addingTimeInterval(Double(batch * 1000 + index))) }
            if batch == 0 { first = items.first }
            _ = try ledger.consume(items, now: now.addingTimeInterval(Double((batch + 1) * 1000)))
        }
        #expect(ledger.entryCount == 2000)
        #expect(try ledger.consume([#require(first)], now: now.addingTimeInterval(4000)) == nil)
        #expect(try JSONEncoder().encode(ledger).count < 262144)
    }
    @Test func notificationTargetsRoundTripOnlyThroughNavigationRoutes() throws {
        let message = MailRoute.message(try MessageID()), thread = MailRoute.thread(try ThreadID())
        #expect(try DeepLinkParser.parse(message.url.absoluteString) == message)
        #expect(try DeepLinkParser.parse(thread.url.absoluteString) == thread)
        for suffix in ["?send=true", "#delete", "/../send", "%2Fsecret"] {
            #expect(throws: DeepLinkError.invalid) { try DeepLinkParser.parse(message.url.absoluteString + suffix) }
        }
    }
    private func copy(_ base: MailMessage, at date: Date) throws -> MailMessage {
        try MailMessage(id: MessageID(), accountID: base.accountID, locator: base.locator, threadID: nil,
            folderIDs: base.folderIDs, subject: "Synthetic notification", sender: base.sender, recipients: [],
            receivedAt: date, isUnread: true, isFlagged: false, preview: nil)
    }
}
