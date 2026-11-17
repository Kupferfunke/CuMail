import Foundation
import Testing
import MailApplication
import MailDomain

struct SearchParserTests {
    let zurich = TimeZone(identifier: "Europe/Zurich")!
    @Test func typedFieldsPhrasesEscapesAndAliases() throws {
        let query = try MailSearchParser.parse(#"Rechnung "rote Mappe" from:"Lena \"Beispiel\"" to:mara subject:Plan filename:pdf account:alpha folder:INBOX after:2026-01-01 before:2027-01-01 is:unread flagged:false has:attachment"#, timeZone: zurich)
        #expect(query.terms.count == 6)
        #expect(query.terms[1].phrase && query.terms[1].value == "rote Mappe")
        #expect(query.terms[2].value == "Lena \"Beispiel\"")
        #expect(query.account == "alpha" && query.folder == "INBOX")
        #expect(query.unread == true && query.flagged == false && query.hasAttachment == true)
        #expect(query.ftsPattern?.contains("sender : \"Lena \"\"Beispiel\"\"\"") == true)
        #expect(!query.supportsOnline)
        #expect(try MailSearchParser.parse(" \n\t ").isEmpty)
        #expect(try MailSearchParser.parse("sender:a recipient:b unread:false has_attachment:false").unread == false)
    }
    @Test(arguments: ["after:2026-02-30", "before:2026-13-01", "after:26-01-01", "after:2026-1-01",
                      "from:", "from: value", "\"offen", "from:\"x\"rest", #"from:"bad\q""#,
                      "missing:x", "unread:yes", "is:deleted", "has:photo", "account:a account:b",
                      "is:read unread:true", "after:2026-01-02 before:2026-01-02"])
    func malformedInputFailsClosed(_ input: String) {
        #expect(throws: (any Error).self) { try MailSearchParser.parse(input, timeZone: zurich) }
    }
    @Test func localDayBoundariesIncludeDSTAndExcludeBefore() throws {
        let spring = try MailSearchParser.parse("after:2026-03-29 before:2026-03-30", timeZone: zurich)
        #expect(spring.before!.timeIntervalSince(spring.after!) == 23 * 3600)
        #expect(spring.matchesDate(spring.after!))
        #expect(!spring.matchesDate(spring.after!.addingTimeInterval(-0.001)))
        #expect(!spring.matchesDate(spring.before!))
        let fall = try MailSearchParser.parse("after:2026-10-25 before:2026-10-26", timeZone: zurich)
        #expect(fall.before!.timeIntervalSince(fall.after!) == 25 * 3600)
        let utc = try MailSearchParser.parse("after:2026-03-29", timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(utc.after != spring.after)
    }
    @Test func budgetsFingerprintAndLiteralFTSOperators() throws {
        #expect(throws: SearchFailure.tooLong) { try MailSearchParser.parse(String(repeating: "ä", count: 513)) }
        #expect(throws: SearchFailure.tooManyTerms) { try MailSearchParser.parse(Array(repeating: "a", count: 33).joined(separator: " ")) }
        let query = try MailSearchParser.parse(#"OR NOT subject:"x:y" "*" "#)
        #expect(query.ftsPattern == #""OR"* AND "NOT"* AND subject : "x:y" AND "*""#)
        #expect(query.fingerprint(context: ["account-a"]) != query.fingerprint(context: ["account-b"]))
        let value = #"a "quoted" \ value"#
        #expect(try MailSearchParser.parse(MailSearchParser.quote(value)).terms.first?.value == value)
    }
}
