import Foundation
import Testing
import MailApplication
@testable import MikeMailHub

struct SignatureSettingsTests {
    @Test func importReadsUnicodeFilesAndSavingSanitizesWithoutReplacingDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CuMail-signature-import-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = "<p onclick=\"bad()\">Liebe Grüsse · Grüezi &amp; merci<script>bad()</script></p>"
        for (name, bytes) in [
            ("utf8.html", Data(raw.utf8)),
            ("bom.htm", Data([0xEF, 0xBB, 0xBF]) + Data(raw.utf8)),
            ("utf16.html", try #require(raw.data(using: .utf16)))
        ] {
            let file = root.appendingPathComponent(name)
            try bytes.write(to: file)
            #expect(try SignatureHTMLFile.read(file) == raw)
        }
        var form = SignatureForm()
        let first = try form.append(name: "Formal", html: "<p>Original default</p>")
        let next = try form.append(name: " formal ", html: raw)
        #expect(form.entries.count == 2 && form.defaultID == first && next != first)
        #expect(form.entries[0].html == "<p>Original default</p>")
        #expect(form.entries[1].name == "formal 2")
        let library = try form.validatedLibrary()
        #expect(library.defaultID == first && library.entries[1].content.plainText.contains("Grüezi & merci"))
        #expect(!library.entries[1].content.html.contains("script"))
        #expect(!library.entries[1].content.html.contains("onclick"))
    }

    @Test func importRejectsInvalidOversizeAndNonHTMLFilesWithoutReadingUnboundedData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CuMail-signature-invalid-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oversized = root.appendingPathComponent("large.html")
        try Data(repeating: 65, count: 32769).write(to: oversized)
        #expect(throws: SignatureEditingFailure.tooLarge) { try SignatureHTMLFile.read(oversized) }
        let encoding = root.appendingPathComponent("broken.html")
        try Data([0xC3, 0x28]).write(to: encoding)
        #expect(throws: SignatureEditingFailure.encoding) { try SignatureHTMLFile.read(encoding) }
        let onlyScript = root.appendingPathComponent("empty.html")
        try Data("<script>bad()</script>".utf8).write(to: onlyScript)
        #expect(throws: SignatureEditingFailure.empty) { try SignatureHTMLFile.read(onlyScript) }
        let other = root.appendingPathComponent("not-html.txt")
        try Data("<p>Not an HTML file selection</p>".utf8).write(to: other)
        #expect(throws: SignatureEditingFailure.unreadable) { try SignatureHTMLFile.read(other) }
        #expect(throws: SignatureEditingFailure.unreadable) { try SignatureHTMLFile.read(root.appendingPathComponent("missing.html")) }
    }

    @Test func editingExplainsInvalidNamesAndPreservesEntriesAtLimit() throws {
        var form = SignatureForm()
        let id = try form.append(name: "Formal", html: "<p>Signature</p>")
        _ = try form.append(name: "Short", html: "<p>Short signature</p>")
        form.entries[1].name = " FORMAL "
        #expect(throws: SignatureEditingFailure.duplicateName) { try form.validatedLibrary() }
        form.entries[1].name = "\n"
        #expect(throws: SignatureEditingFailure.name) { try form.validatedLibrary() }
        form.entries[1].name = "Short"; form.entries[1].html = " "
        #expect(throws: SignatureEditingFailure.empty) { try form.validatedLibrary() }
        form.entries[1].html = "<p>Short signature</p>"
        while form.entries.count < 20 { _ = try form.append(name: "Signature", html: "<p>Additional signature</p>") }
        let before = try form.validatedLibrary()
        #expect(throws: SignatureEditingFailure.tooMany) { try form.append(name: "Extra", html: "<p>Extra</p>") }
        #expect(try form.validatedLibrary() == before)
        #expect(form.defaultID == id)
    }
}
