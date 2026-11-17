import Foundation
import CryptoKit
import Testing
import SwiftMail
import MailApplication
import MailDomain
import MailRendering
@testable import MailIMAP

private final class SMTPFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MikeMailSMTPFixture-\(UUID())")
    let process = Process()
    let port: Int
    let exited = DispatchSemaphore(value: 0)
    init(mode: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let output = Pipe(), finished = exited
        process.terminationHandler = { _ in finished.signal() }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", Bundle.module.url(forResource: "smtp_fixture", withExtension: "py", subdirectory: "Fixtures")!.path, root.path, mode]
        process.standardOutput = output; process.standardError = Pipe(); try process.run()
        var bytes = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte[0] != 10 { bytes.append(byte) }
        port = try #require(Int(String(decoding: bytes, as: UTF8.self)))
    }
    var commands: String { (try? String(contentsOf: root.appendingPathComponent("commands.txt"), encoding: .utf8)) ?? "" }
    var message: String { (try? String(contentsOf: root.appendingPathComponent("message.eml"), encoding: .utf8)) ?? "" }
    func close() {
        if process.isRunning { process.terminate(); _ = exited.wait(timeout: .now() + 3) }
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct SMTPTests {
    private func profile(port: Int, security: IMAPSecurity = .implicitTLS) throws -> SMTPProfile {
        try SMTPProfile(accountID: AccountID(), host: "localhost", port: port, security: security, username: "sender@example.invalid", sentPolicy: .appendToFolder, sentFolder: "Sent")
    }
    private func draft(_ profile: SMTPProfile) -> LocalDraft {
        var draft = LocalDraft(accountID: profile.accountID, sender: "sender@example.invalid")
        draft.to = "to@example.invalid"; draft.cc = "cc@example.invalid"; draft.bcc = "bcc@example.invalid"
        draft.subject = "Test äöü"; draft.body = "First line\n.Second line\nUnicode äöü"
        draft.internetMessageID = "<stable-operation@example.invalid>"
        draft.inReplyTo = "<parent@example.invalid>"; draft.references = ["<root@example.invalid>", "<parent@example.invalid>"]
        return draft
    }
    @Test(arguments: ["accept", "reject-recipient", "reject-content", "ambiguous", "size"])
    func encryptedProtocolPreservesEnvelopeMimeAndClassifiesOutcomes(mode: String) async throws {
        let fixture = try SMTPFixture(mode: mode); defer { fixture.close() }
        let settings = try profile(port: fixture.port)
        let server = SMTPServer(host: "localhost", port: fixture.port, transportSecurity: .implicitTLS,
            certificateVerificationPolicy: .noVerification, minimumTLSVersion: .tlsv12,
            submissionTimeouts: SMTPSubmissionTimeouts(mailFromResponse: 3, recipientResponse: 3, dataResponse: 3, contentUpload: 3, contentResponse: 3))
        let adapter = SwiftMailSubmission(profile: settings, password: "public-test-password", server: server)
        try await adapter.connect()
        if mode == "size" {
            await #expect(throws: ComposeFailure.tooLarge) { try await adapter.prepare(draft(settings), attachments: []) }
            #expect(!fixture.commands.contains("MAIL FROM"))
        } else {
            let prepared = try await adapter.prepare(draft(settings), attachments: [])
            #expect(prepared.recipients.count == 3 && !prepared.rawMessage.contains("Bcc:"))
            #expect(prepared.rawMessage.contains("Message-Id: <stable-operation@example.invalid>"))
            #expect(prepared.rawMessage.contains("In-Reply-To: <parent@example.invalid>"))
            #expect(prepared.rawMessage.contains("References: <root@example.invalid> <parent@example.invalid>"))
            if mode == "accept" { try await adapter.submit(prepared) }
            else { await #expect(throws: mode == "ambiguous" ? ComposeFailure.uncertain : .rejected) { try await adapter.submit(prepared) } }
            #expect(fixture.commands.contains("RCPT TO:<bcc@example.invalid>"))
            if mode == "reject-recipient" { #expect(!fixture.commands.contains("\nDATA\n") && fixture.message.isEmpty) }
            else { #expect(fixture.message == prepared.rawMessage) }
        }
        await adapter.disconnect()
    }
    @Test func untrustedCertificateAndMissingRequiredSTARTTLSFailBeforeCredentials() async throws {
        for mode in ["accept", "missing-starttls"] {
            let fixture = try SMTPFixture(mode: mode); defer { fixture.close() }
            let settings = try profile(port: fixture.port, security: mode == "accept" ? .implicitTLS : .startTLS)
            let adapter = SwiftMailSubmission(profile: settings, password: "never-transmit-this-test-value")
            await #expect(throws: ComposeFailure.connection) { try await adapter.connect() }
            #expect(!fixture.commands.contains("AUTH") && !fixture.commands.contains("MAIL FROM"))
            await adapter.disconnect()
        }
    }
    @Test func attachmentActualBytesAndHeaderInjectionAreChecked() async throws {
        let settings = try profile(port: 465), data = Data("public synthetic attachment".utf8)
        let file = DraftAttachment(filename: "test.txt", mimeType: "text/plain", byteCount: data.count, bookmark: Data(), digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        var message = draft(settings); message.attachments = [file]
        let adapter = SwiftMailSubmission(profile: settings, password: "")
        let result = try await adapter.prepare(message, attachments: [OutgoingAttachment(reference: file, data: data)])
        #expect(result.rawMessage.contains(data.base64EncodedString()))
        await #expect(throws: ComposeFailure.attachmentChanged) { try await adapter.prepare(message, attachments: [OutgoingAttachment(reference: file, data: Data("changed".utf8))]) }
        message.subject = "subject\r\nBcc: injection@example.invalid"
        await #expect(throws: ComposeFailure.invalidHeader) { try await adapter.prepare(message, attachments: [OutgoingAttachment(reference: file, data: data)]) }
    }
}

struct SignatureMIMETests {
    @Test func htmlReplyRoundTripsThroughActualMIMEWithEmbeddedImageAndAttachment() throws {
        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPYm2zwHwAFgQJQmStAeQAAAABJRU5ErkJggg=="))
        let image = try #require(InlineMailImage(data: bytes))
        let safe = try MailHTMLSanitizer.sanitize("<style>td{color:#123456}</style><table><tr><td><b>Original</b><img src='cid:logo'></td></tr></table>", inlineImages: ["logo": image])
        var draft = LocalDraft(accountID: try AccountID(), sender: "sender@example.invalid")
        draft.to = "receiver@example.invalid"; draft.body = "My answer"; draft.internetMessageID = "<html-reply@example.invalid>"
        draft.quotation = try DraftQuotation(heading: "Original message:", plainText: "Original", html: safe)
        let data = Data("Selected file".utf8)
        let ref = DraftAttachment(filename: "selected.txt", mimeType: "text/plain", byteCount: data.count, bookmark: Data(), digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        draft.attachments = [ref]
        let raw = try SwiftMailMIMEEncoder.prepare(draft, attachments: [OutgoingAttachment(reference: ref, data: data)]).rawMessage
        let parsed = try EMLParser.parse(Data(raw.utf8))
        let html = try #require(parsed.htmlBody), contentID = try #require(draft.quotation?.html.images.first?.contentID)
        #expect(parsed.textBody?.contains("My answer") == true && parsed.textBody?.contains("> Original") == true)
        #expect(html.contains("<table") && html.contains("<b>Original</b>") && html.contains("color:#123456"))
        #expect(html.contains("cid:" + contentID) && !html.contains("data:image"))
        #expect(raw.contains("Content-ID: <" + contentID + ">") && raw.contains("multipart/related") && raw.contains("selected.txt"))
        #expect(parsed.parts.first { $0.contentId == contentID }?.decodedData() == bytes)
    }
    @Test func signatureSanitizesActiveContentKeepsFormattingAndProducesBothMimeAlternatives() throws {
        let signature = try MailSignature(html: "<div style=\"color:#A85429;font-size:12px;position:fixed;background:url(https://bad.invalid/x)\"><b>Mike</b><br><a href=\"mailto:mike@example.invalid\">Kontakt</a><script>evil()</script><img src=\"https://example.invalid/logo.png\" onerror=\"evil()\"></div>")
        try signature.validate()
        #expect(signature.html.contains("color:#A85429") && signature.html.contains("mailto:"))
        #expect(!signature.html.contains("script") && !signature.html.contains("onerror") && !signature.html.contains("position:") && !signature.html.contains("url("))
        var draft = LocalDraft(accountID: try AccountID(), sender: "sender@example.invalid")
        draft.to = "receiver@example.invalid"; draft.subject = "Signature"; draft.body = "Hello <world> & everyone"
        draft.signature = signature; draft.internetMessageID = "<signature-test@example.invalid>"
        let raw = try SwiftMailMIMEEncoder.prepare(draft, attachments: []).rawMessage
        #expect(raw.contains("multipart/alternative") && raw.contains("text/plain") && raw.contains("text/html"))
        #expect(draft.outgoingHTML?.contains("&lt;world&gt; &amp; everyone") == true)
        #expect(draft.outgoingPlainText.contains("Mike") && draft.outgoingPlainText.components(separatedBy: "Mike").count == 2)
        let decoded = try JSONDecoder().decode(LocalDraft.self, from: JSONEncoder().encode(draft))
        #expect(decoded.signature == signature && decoded.outgoingPlainText == draft.outgoingPlainText)
        draft.signature?.enabled = false
        #expect(draft.outgoingHTML == nil && draft.outgoingPlainText == draft.body)
        draft.purgeContent(); #expect(draft.signature == nil)
    }
    @Test func oldDraftWithoutSignatureStillDecodes() throws {
        let draft = LocalDraft(accountID: try AccountID(), sender: "sender@example.invalid")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        json.removeValue(forKey: "signature")
        let restored = try JSONDecoder().decode(LocalDraft.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.signature == nil)
    }
}
