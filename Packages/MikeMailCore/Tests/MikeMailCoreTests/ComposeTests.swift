import Foundation
import Testing
import MailDomain
import MailApplication
import MailDemo
import MailRendering

struct ComposeTests {
    @Test func recipientSeparatorsAndLegacyAutocompleteSuffixesAreSafe() throws {
        for separator in [",", ";"] {
            for suffix in ["", separator, separator + " ", separator + "   "] {
                #expect(try ComposeValidation.addresses("one@example.invalid" + suffix) == ["one@example.invalid"])
                #expect(try ComposeValidation.addresses("one@example.invalid\(separator) two@example.invalid" + suffix) == ["one@example.invalid", "two@example.invalid"])
            }
        }
        #expect(try ComposeValidation.addresses("one@example.invalid; , ONE@example.invalid, two@example.invalid; ") == ["one@example.invalid", "two@example.invalid"])
        var draft = LocalDraft(accountID: try AccountID(), sender: "sender@example.invalid")
        draft.to = "one@example.invalid, "; draft.cc = "copy@example.invalid; "; draft.bcc = "blind@example.invalid, "
        try draft.validateSubmission()
        draft.to = ", ; "; draft.cc = ""; draft.bcc = ""
        #expect(throws: ComposeFailure.missingRecipients) { try draft.validateSubmission() }
        for malformed in ["good@example.invalid; bad@; ", "good@example.invalid; missing-domain; ", "good@example.invalid, \r\n"] {
            #expect(throws: (any Error).self) { try ComposeValidation.addresses(malformed) }
        }
    }
    @Test(arguments: [ComposeKind.reply, .replyAll, .forward])
    func htmlOriginalRemainsSeparateFromAnswerAndSignature(kind: ComposeKind) throws {
        let source = try SyntheticFixtures.make().snapshot.messages[0]
        let html = try MailHTMLSanitizer.sanitize("<table><tr><td style='color:#123456'><b>Original</b></td></tr></table>")
        var draft = try DraftBuilder.response(to: source, kind: kind, sender: "me@example.invalid", ownAddresses: ["me@example.invalid"], quote: "Original", htmlQuote: html)
        #expect(draft.sourceMessageID == source.id)
        #expect(draft.body.isEmpty && draft.quotation?.plainText == "Original")
        draft.body = "Answer <safe> & readable"
        draft.signature = try MailSignature(html: "<p>My signature</p>")
        let outgoing = try #require(draft.outgoingHTML)
        #expect(outgoing.contains("<table") && outgoing.contains("<b>Original</b>"))
        #expect(outgoing.contains("Answer &lt;safe&gt; &amp; readable"))
        #expect(outgoing.range(of: "My signature")!.lowerBound < outgoing.range(of: "<table")!.lowerBound)
        #expect(draft.outgoingPlainText.contains("My signature\n\n") && draft.outgoingPlainText.hasSuffix("> Original"))
        let saved = try JSONDecoder().decode(LocalDraft.self, from: JSONEncoder().encode(draft))
        #expect(saved == draft && saved.outgoingHTML == outgoing)
        draft.signature = nil
        #expect(draft.outgoingHTML?.contains("<table") == true)
        draft.quotation = nil
        #expect(draft.outgoingHTML == nil && draft.outgoingPlainText == draft.body)
        var purged = saved; purged.purgeContent(); #expect(purged.quotation == nil && purged.sourceMessageID == source.id)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        #expect(legacy["forwardedMessageID"] != nil && legacy["sourceMessageID"] == nil)
        legacy.removeValue(forKey: "quotation")
        legacy.removeValue(forKey: "forwardedMessageID")
        #expect(try JSONDecoder().decode(LocalDraft.self, from: JSONSerialization.data(withJSONObject: legacy)).quotation == nil)
        #expect(try JSONDecoder().decode(LocalDraft.self, from: JSONSerialization.data(withJSONObject: legacy)).sourceMessageID == nil)
    }
    @Test func replyToOwnSelfMessageRetainsExplicitRecipientAndThread() throws {
        let source = try SyntheticFixtures.make().snapshot.messages[0]
        let own = MailPerson(name: "Self", address: try EmailAddress("me@example.invalid"))
        let alias = MailPerson(name: "Alias", address: try EmailAddress("alias@example.invalid"))
        for replyTo in [[], [alias]] as [[MailPerson]] {
            let message = try MailMessage(id: source.id, accountID: source.accountID, locator: source.locator,
                threadID: nil, folderIDs: source.folderIDs, internetMessageID: "<self@example.invalid>",
                subject: "Self test", sender: own, recipients: [own], receivedAt: Date(), isUnread: true,
                isFlagged: false, preview: nil, threadingHeadersLoaded: true, replyTo: replyTo)
            for kind in [ComposeKind.reply, .replyAll] {
                let draft = try DraftBuilder.response(to: message, kind: kind, sender: own.address.value,
                    ownAddresses: [own.address.value, alias.address.value], quote: "")
                #expect(draft.to == (replyTo.first ?? own).address.value)
                #expect(draft.cc.isEmpty && draft.bcc.isEmpty && draft.attachments.isEmpty)
                #expect(draft.inReplyTo == "<self@example.invalid>")
                try draft.validateSubmission()
            }
        }
    }
    @Test func injectionAndInvalidRecipientsFailBeforeSubmission() throws {
        for text in ["a@example.invalid\r\nBcc: hidden@example.invalid", "a@example.invalid\0", "Name <a@example.invalid>", "x..y@example.invalid"] {
            #expect(throws: (any Error).self) { try ComposeValidation.addresses(text) }
        }
        var draft = LocalDraft(accountID: try AccountID(), sender: "sender@example.invalid")
        draft.to = "one@example.invalid"; draft.subject = "Hello\r\nBcc: hidden@example.invalid"
        #expect(throws: ComposeFailure.invalidHeader) { try draft.validateSubmission() }
        draft.subject = "Unicode äöü 日本語"; draft.body = "Body\nwith lines"
        try draft.validateSubmission()
        draft.body = String(repeating: "a", count: 262_145)
        #expect(throws: ComposeFailure.tooLarge) { try draft.validateStorage() }
    }
    @Test func replyAllRespectsReplyToCcOwnIdentitiesAndHeaders() throws {
        let source = try SyntheticFixtures.make().snapshot.messages[0]
        func person(_ address: String) throws -> MailPerson { MailPerson(name: "", address: try EmailAddress(address)) }
        let a = try person("a@example.invalid"), b = try person("b@example.invalid"), own = try person("me@example.invalid")
        let message = try MailMessage(id: source.id, accountID: source.accountID, locator: source.locator, threadID: nil, folderIDs: source.folderIDs,
            internetMessageID: "<parent@example.invalid>", subject: "Topic", sender: a, recipients: [own, a, b], receivedAt: Date(), isUnread: false, isFlagged: false, preview: nil,
            references: ["<root@example.invalid>"], threadingHeadersLoaded: true, ccRecipients: [b], replyTo: [try person("reply@example.invalid")])
        let reply = try DraftBuilder.response(to: message, kind: .replyAll, sender: own.address.value, ownAddresses: [own.address.value, "alias@example.invalid"], quote: "Original")
        #expect(reply.accountID == source.accountID && reply.sender == own.address.value)
        #expect(reply.to == "reply@example.invalid, a@example.invalid" && reply.cc == b.address.value && reply.bcc.isEmpty)
        #expect(reply.inReplyTo == "<parent@example.invalid>" && reply.references == ["<root@example.invalid>", "<parent@example.invalid>"])
        #expect(reply.body.contains("> Original"))
        let forward = try DraftBuilder.response(to: message, kind: .forward, sender: own.address.value, ownAddresses: [own.address.value], quote: "Original")
        #expect(forward.to.isEmpty && forward.cc.isEmpty && forward.bcc.isEmpty && forward.inReplyTo == nil && forward.references.isEmpty)
    }
}
