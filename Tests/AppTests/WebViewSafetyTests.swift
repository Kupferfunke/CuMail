import Foundation
import AppKit
import WebKit
import Testing
import MailRendering
import MailApplication
import MailDomain
@testable import MikeMailHub

@Suite(.serialized)
@MainActor
struct WebViewSafetyTests {
    @Test func outgoingReplyPreservesOriginalStylesWithoutChangingTheAnswer() async throws {
        _ = NSApplication.shared
        let original = try MailHTMLSanitizer.sanitize("""
        <style>body{color:#123456}p{font-size:24px;color:#983f23}td{padding:22px;background-color:#edf0f3}
        @media screen and (max-width:640px){td{padding:12px}}</style>
        <table width="500"><tr><td id="quoted-cell"><p id="quoted-heading"><b>Formatted original</b></p></td></tr></table>
        """)
        var draft = LocalDraft(accountID: try AccountID(), sender: "sender@example.invalid")
        draft.body = "My new answer"
        draft.signature = try MailSignature(html: "<p id='own-signature'>My signature</p>")
        draft.quotation = try DraftQuotation(heading: "Original:", plainText: original.plainText, html: original)
        let restored = try JSONDecoder().decode(LocalDraft.self, from: JSONEncoder().encode(draft))
        let view = SafeMailWebView.makeWebView()
        let delegate = SafeMailWebView.Coordinator(openLink: { _ in }, failed: { Issue.record("Reply render failed") })
        view.navigationDelegate = delegate; view.uiDelegate = delegate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { delegate.task?.cancel(); view.stopLoading(); window.contentView = nil }
        delegate.load(try #require(restored.outgoingHTML), images: false, in: view)
        try await settle { view.url?.absoluteString == "about:blank" && !view.isLoading }
        #expect(try await evaluateString("getComputedStyle(document.getElementById('quoted-heading')).color", in: view) == "rgb(152, 63, 35)")
        #expect(try await evaluateString("getComputedStyle(document.getElementById('quoted-heading')).fontSize", in: view) == "24px")
        #expect(try await evaluateString("getComputedStyle(document.getElementById('quoted-cell')).paddingTop", in: view) == "22px")
        #expect(try await evaluateString("getComputedStyle(document.getElementById('own-signature')).color", in: view) != "rgb(152, 63, 35)")
        #expect(try await evaluateString("getComputedStyle(document.body.firstElementChild).color", in: view) != "rgb(18, 52, 86)")
        if let directory = ProcessInfo.processInfo.environment["CUMAIL_HTML_RENDER_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try await saveSnapshot(view, to: URL(fileURLWithPath: directory).appendingPathComponent("html-reply-outgoing.png"))
        }
    }
    @Test func realWebKitPreservesEmailLayoutFitsWidthAndReportsFullHeight() async throws {
        _ = NSApplication.shared
        let rasterData = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPYm2zwHwAFgQJQmStAeQAAAABJRU5ErkJggg=="))
        let raster = try #require(InlineMailImage(data: rasterData))
        let raw = """
        <html><head><style>
        .card{width:600px;margin:0 auto;background:#ffffff;border-collapse:collapse}
        .heading{font:700 28px Arial;color:#983f23}.copy{font:16px/1.6 Arial;color:#203040}
        @media screen and (max-width:640px){.card{width:100%!important}.space{padding:16px!important}}
        </style></head><body style="margin:0;background:#edf0f3">
        <table class="card" id="card" width="600" cellpadding="0" cellspacing="0" border="0">
        <tr><td class="space" id="cell" style="padding:28px"><img id="logo" src="cid:logo" width="20" height="20">
        <p class="heading" id="headline">Eine Mail in ihrem eigenen Layout.</p><p class="copy">Synthetische Layoutprüfung · CuMail</p>
        \(String(repeating: "<p class='copy'>Tabellen, Abstände, Farben und Schrift bleiben erhalten. Die vollständige Nachricht scrollt zusammen mit dem Lesebereich.</p>", count: 14))
        <p class="copy" id="end">Ende der vollständigen Testnachricht.</p></td></tr></table></body></html>
        """
        let safe = try MailHTMLSanitizer.sanitize(raw, inlineImages: ["logo": raster])
        let view = SafeMailWebView.makeWebView()
        let delegate = SafeMailWebView.Coordinator(openLink: { _ in Issue.record("Unexpected link") }, failed: { Issue.record("Render failed") })
        var height: CGFloat = 0
        delegate.heightChanged = { height = $0 }
        view.navigationDelegate = delegate; view.uiDelegate = delegate
        view.widthChanged = { [weak view, weak delegate] in if let view { delegate?.measure(view) } }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { delegate.task?.cancel(); delegate.measureTask?.cancel(); view.stopLoading(); window.contentView = nil }
        delegate.load(safe.document(dark: true), images: false, in: view)
        try await settle { height > 1000 }
        #expect(try await evaluateString("String(document.getElementById('card').offsetWidth)", in: view) == "600")
        #expect(try await evaluateString("getComputedStyle(document.getElementById('cell')).borderTopWidth", in: view) == "0px")
        #expect(try await evaluateString("getComputedStyle(document.getElementById('cell')).paddingTop", in: view) == "28px")
        #expect(try await evaluateString("getComputedStyle(document.getElementById('headline')).color", in: view) == "rgb(152, 63, 35)")
        #expect(try await evaluateString("String(document.getElementById('logo').naturalWidth)", in: view) == "1")
        #expect(view.pageZoom == 1)
        if let directory = ProcessInfo.processInfo.environment["CUMAIL_HTML_RENDER_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            view.setFrameSize(NSSize(width: 720, height: height))
            try await saveSnapshot(view, to: URL(fileURLWithPath: directory).appendingPathComponent("html-wide.png"))
        }
        let wideHeight = height; height = 0
        window.setContentSize(NSSize(width: 360, height: 400))
        try await settle { height > wideHeight }
        let narrowCardWidth = try await evaluateString("String(document.getElementById('card').offsetWidth)", in: view)
        let viewportWidth = try await evaluateString("String(document.documentElement.clientWidth)", in: view)
        // macOS can reserve 17 px when the user chooses always-visible scrollbars.
        #expect(narrowCardWidth == viewportWidth)
        #expect((Int(viewportWidth ?? "") ?? 0) <= 360 && (Int(viewportWidth ?? "") ?? 0) >= 340)
        #expect(try await evaluateString("getComputedStyle(document.getElementById('cell')).paddingTop", in: view) == "16px")
        #expect(view.pageZoom == 1)
        if let directory = ProcessInfo.processInfo.environment["CUMAIL_HTML_RENDER_DIR"] {
            view.setFrameSize(NSSize(width: 360, height: height))
            try await saveSnapshot(view, to: URL(fileURLWithPath: directory).appendingPathComponent("html-narrow.png"))
        }
        // Older fixed-width newsletters shrink to the viewport without clipped columns.
        height = 0
        delegate.load(try MailHTMLSanitizer.sanitize("<table width='720'><tr><td style='width:720px'>Fixed width</td></tr></table>").document(dark: false), images: false, in: view)
        try await settle { height > 0 }
        #expect(view.pageZoom < 0.51)
        height = 0
        delegate.load(try MailHTMLSanitizer.sanitize("<p>Short mail</p>").document(dark: false), images: false, in: view)
        try await settle { height > 0 }
        #expect(height < 150 && view.pageZoom == 1)
    }
    private func saveSnapshot(_ view: WKWebView, to path: URL) async throws {
        let image = try await view.takeSnapshot(configuration: nil)
        let data = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]))
        try png.write(to: path)
    }
    @Test(arguments: [false, true]) func actualWebKitBlocksScriptsSubresourcesAndExternalNavigation(images: Bool) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MikeMailWebTest-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", """
        from http.server import HTTPServer, BaseHTTPRequestHandler
        import pathlib,sys
        root=pathlib.Path(sys.argv[1])
        class Handler(BaseHTTPRequestHandler):
          def do_GET(self):
            with (root/'requests.txt').open('a') as f: f.write('request\\n')
            self.send_response(200); self.end_headers(); self.wfile.write(b'fixture')
          def log_message(self,*args): pass
        server=HTTPServer(('127.0.0.1',0),Handler)
        print(server.server_port,flush=True)
        server.serve_forever()
        """, root.path]
        process.standardOutput = output; process.standardError = Pipe()
        try process.run()
        defer { process.terminate(); process.waitUntilExit(); try? FileManager.default.removeItem(at: root) }
        var portBytes = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte[0] != 10 { portBytes.append(byte) }
        let port = try #require(Int(String(decoding: portBytes, as: UTF8.self)))
        let endpoint = "http://127.0.0.1:\(port)"
        let view = SafeMailWebView.makeWebView()
        var failed = false
        let delegate = SafeMailWebView.Coordinator(openLink: { _ in Issue.record("Unexpected external link") }, failed: { failed = true })
        view.navigationDelegate = delegate; view.uiDelegate = delegate
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 600,height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { view.stopLoading(); window.contentView = nil }
        let raw = """
        <html><body><p>Safe view fixture</p><script>document.body.setAttribute('data-unsafe','yes')</script>
        <img src="\(endpoint)/pixel"><iframe src="\(endpoint)/frame"></iframe><style>body{background-image:url('\(endpoint)/css')}</style></body></html>
        """
        // Deliberately omit sanitizer/CSP in this fixture to test the independent WebKit controls.
        delegate.load(raw, images: images, in: view)
        try await settle { view.url?.absoluteString == "about:blank" && !view.isLoading }
        let body = try await evaluateString("document.body.innerText", in: view)
        let executed = try await evaluateString("document.body.getAttribute('data-unsafe') || 'absent'", in: view)
        #expect(body?.contains("Safe view fixture") == true)
        #expect(executed == "absent")
        #expect(!view.configuration.websiteDataStore.isPersistent)
        #expect(!view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("requests.txt").path))
        let before = delegate.blockedNavigationCount
        view.load(URLRequest(url: try #require(URL(string: endpoint + "/navigation"))))
        try await settle { delegate.blockedNavigationCount > before }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("requests.txt").path))
        #expect(!failed)
    }
    private func evaluateString(_ script: String, in view: WKWebView) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? String)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        Issue.record("WebKit did not reach the expected state in ten seconds")
    }
}
