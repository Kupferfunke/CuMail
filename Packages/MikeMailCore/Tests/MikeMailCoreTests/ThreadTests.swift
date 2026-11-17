import Foundation
import Testing
import MailApplication
import MailDomain

struct ThreadTests {
    @Test func referencesJoinRepliesAndSurviveLateParentsWithoutCrossAccountGrouping() throws {
        let account = try AccountID(), other = try AccountID(), child = try MessageID(), parent = try MessageID()
        let a = ThreadResolver.Record(message: child, ownID: "<child@example.invalid>", replyTo: "<parent@example.invalid>", references: ["<root@example.invalid>"])
        let first = try ThreadResolver.resolve([a], account: account)
        let b = ThreadResolver.Record(message: parent, ownID: "<parent@example.invalid>", replyTo: "<earlier@example.invalid>", references: [])
        let later = try ThreadResolver.resolve([b,a], account: account, existing: first.keys)
        #expect(later.messages[child] == first.messages[child])
        #expect(later.messages[parent] == later.messages[child])
        #expect(try ThreadResolver.resolve([a,b], account: other).messages[child] != later.messages[child])
    }
    @Test func missingMalformedHeadersAndCyclesAreBounded() throws {
        let account = try AccountID(), a = try MessageID(), b = try MessageID(), c = try MessageID()
        let invalid = ThreadResolver.Record(message: c, ownID: nil, replyTo: "bad\nreference", references: ["", "<bad id>"])
        let one = ThreadResolver.Record(message: a, ownID: "<a@x>", replyTo: "<b@x>", references: [])
        let two = ThreadResolver.Record(message: b, ownID: "<b@x>", replyTo: "<a@x>", references: [])
        let result = try ThreadResolver.resolve([invalid,two,one], account: account)
        #expect(result.messages[a] == result.messages[b])
        #expect(result.messages[a] != result.messages[c])
        #expect(result.keys.count == 3)
    }
}
