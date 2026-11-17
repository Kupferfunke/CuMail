import Foundation
import Testing
@testable import MailRendering

struct HTMLSafetyTests {
    @Test func replyQuotationPreservesLayoutScopesCSSAndRestoresInlineImages() throws {
        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPYm2zwHwAFgQJQmStAeQAAAABJRU5ErkJggg=="))
        let image = try #require(InlineMailImage(data: bytes))
        let safe = try MailHTMLSanitizer.sanitize("""
        <html><head><style>html,body{color:#123456}p{font-weight:bold}.card{width:600px}
        @media screen and (max-width:640px){body .card,p[title="body,html"]{width:100%}}
        </style></head><body bgcolor="#eeeeee" class="original" style="padding:20px">
        <table class="card" cellpadding="0"><tr><td style="background-color:#aa5500"><b>Formatted original</b></td></tr></table>
        <img src="cid:logo"><img src="cid:logo"><a href="https://example.invalid/details">Details</a></body></html>
        """, inlineImages: ["logo": image])
        let quote = try QuotedMailHTML(safe)
        let scope = "#cumail-quote-" + quote.id.uuidString.lowercased()
        #expect(quote.stylesheet.contains(scope + " .cumail-original-html," + scope + " .cumail-original-body"))
        #expect(quote.stylesheet.contains(scope + " .cumail-original-body .card," + scope + " p[title=\"body,html\"]"))
        #expect(quote.markup.contains("<table") && quote.markup.contains("<b>Formatted original</b>"))
        #expect(quote.markup.contains("background-color:#aa5500") && quote.markup.contains("background-color:#eeeeee"))
        #expect(quote.images.count == 1 && quote.images[0].raster.data == bytes)
        #expect(!quote.markup.contains("data:image") && quote.markup.contains("cid:" + quote.images[0].contentID))
        let reopened = try JSONDecoder().decode(QuotedMailHTML.self, from: JSONEncoder().encode(quote))
        #expect(reopened == quote)
        #expect(reopened.preview.bodyMarkup.contains(image.dataURI))
    }
    @Test func savedQuotationCannotInjectActiveMarkupOrEscapeItsScope() throws {
        let data = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString,
            "source": "<style>body{color:red}@import url(https://evil.invalid/x);</style><p onclick='evil()'>Text</p><script>evil()</script><img src='file:///secret'>"])
        let quote = try JSONDecoder().decode(QuotedMailHTML.self, from: data)
        #expect(!quote.markup.contains("script") && !quote.markup.contains("onclick") && !quote.markup.contains("file:"))
        #expect(quote.stylesheet.hasPrefix("#cumail-quote-") && !quote.stylesheet.contains("evil.invalid"))
    }
    @Test func emailLayoutsKeepInertStylesAndLegacyTableGeometry() throws {
        let raw = """
        <html><head><style>
        body{background:#edf0f3;color:#203040}.card{width:600px;margin:0 auto;background-color:white}
        .card > tbody > tr > td {padding:24px;border:0;color:rgb(32,48,64)}
        @media only screen and (max-width:640px){.card{width:100%!important}.column{display:block!important;width:100%!important}}
        @import url(https://evil.invalid/a);@font-face{font-family:x;src:url(https://evil.invalid/b)}
        .bad{background:url(https://evil.invalid/c);color:red;position:fixed;content:attr(title)}
        </style></head><body class="newsletter" bgcolor="#edf0f3" style="margin:0;padding:20px">
        <table class="card" width="600" cellpadding="0" cellspacing="0" border="0"><tr><td valign="top" align="center" bgcolor="#ffffff" style="font:16px Arial,sans-serif;padding:24px;border-radius:12px">
        <font face="Arial" color="#203040">Hallo <b>Mike</b>!</font><img src="https://example.com/logo" width="120" height="40"></td></tr></table></body></html>
        """
        let safe = try MailHTMLSanitizer.sanitize(raw)
        #expect(safe.stylesheet.contains("@media only screen and (max-width:640px)"))
        #expect(safe.stylesheet.contains(".card > tbody > tr > td"))
        #expect(safe.bodyMarkup.contains("cellpadding=\"0\"") && safe.bodyMarkup.contains("width=\"600\""))
        #expect(safe.bodyMarkup.contains("padding:24px;border-radius:12px"))
        #expect(safe.bodyMarkup.contains("Hallo <b>Mike</b>!"))
        #expect(safe.bodyAttributes.contains("class=\"newsletter\"") && safe.bodyAttributes.contains("padding:20px"))
        for token in ["evil.invalid", "url(", "@font-face", "@import", "position:", "content:"] { #expect(!safe.stylesheet.contains(token)) }
        #expect(safe.document(dark: true) == safe.document(dark: false))
        #expect(!safe.document(dark: false).contains("border:1px solid"))
    }
    @Test func cssObfuscationCannotRestoreNetworkOrActiveContent() throws {
        for value in ["background:u/**/rl(https://evil.invalid/x)", "background:u\\72l(https://evil.invalid/x)", "width:expression(alert(1))",
                      "background:var(--image)", "--image:url(x)", "color:red;behavior:url(x)", "color:red;-moz-binding:url(x)", "content:'evil'", "background:image-set('https://evil.invalid/x' 1x)"] {
            let safe = try MailHTMLSanitizer.sanitize("<p style=\"\(value)\">Safe</p>")
            for token in ["evil.invalid", "expression", "var(", "behavior", "binding", "image-set"] { #expect(!safe.bodyMarkup.contains(token)) }
        }
    }
    @Test func embeddedRasterImagesResolveOnlyMatchingContentIDsAndStayBounded() throws {
        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPYm2zwHwAFgQJQmStAeQAAAABJRU5ErkJggg=="))
        let raster = try #require(InlineMailImage(data: bytes))
        let raw = "<img src='cid:logo%40mail'><img src='cid:missing'><img src='https://example.com/remote'><img src='data:image/svg+xml;base64,PHN2Zz48L3N2Zz4='>"
        #expect(try MailHTMLSanitizer.inlineContentIDs(in: raw) == ["logo@mail", "missing"])
        let safe = try MailHTMLSanitizer.sanitize(raw, inlineImages: ["logo@mail": raster])
        #expect(safe.bodyMarkup.contains(raster.dataURI))
        #expect(safe.unavailableImageCount == 2 && safe.remoteImageCount == 1)
        #expect(!safe.bodyMarkup.contains("svg+xml") && !safe.bodyMarkup.contains("cid:"))
        #expect(InlineMailImage(data: Data("<svg/>".utf8)) == nil)
        #expect(InlineMailImage(data: Data(repeating: 0, count: InlineMailImage.maximumBytes + 1)) == nil)
        let many = try MailHTMLSanitizer.sanitize(String(repeating: "<img src='cid:logo'>", count: 20), inlineImages: ["logo": raster])
        #expect(many.unavailableImageCount == 8)
        #expect(try MailHTMLSanitizer.sanitize("<img src='\(raster.dataURI)'>").unavailableImageCount == 0)
    }
    @Test func activeContentAndNetworkSurfacesAreRemoved() throws {
        let raw = """
        <html><head><base href="https://attacker.invalid/"><meta http-equiv="refresh" content="0;url=https://attacker.invalid/"><style>@import 'https://attacker.invalid/style';body{background:url(https://attacker.invalid/pixel)}</style></head>
        <body onload="attack()"><h1>Lesbare Überschrift</h1><p style="background:url(https://attacker.invalid/css)">Hallo äöü</p>
        <script>attack()</script><iframe src="https://attacker.invalid/frame"></iframe><object data="file:///etc/passwd"></object>
        <form action="https://attacker.invalid/"><input value="secret"></form><svg><image href="https://attacker.invalid/svg"/></svg><math><mtext>hidden</mtext></math>
        <a href="javascript:attack()">Schlecht</a><a href="file:///private/file">Datei</a><a href="https://example.com/help?q=1&amp;x=2">Hilfe</a>
        <img src="https://example.com/picture.png" srcset="https://attacker.invalid/a 2x" onerror="attack()"><img src="cid:logo">
        <table><tr><td colspan="9999999999999">Zelle</td></tr></table></body></html>
        """
        let safe = try MailHTMLSanitizer.sanitize(raw)
        for forbidden in ["<script", "<iframe", "<object", "<form", "<input", "<svg", "<math", "<base", "<meta", "<style", "onload", "onerror", "srcset", "javascript:", "file:", "attacker.invalid", "colspan="] { #expect(!safe.bodyMarkup.contains(forbidden)) }
        #expect(safe.plainText.contains("Hallo äöü"))
        #expect(safe.remoteImageCount == 1 && safe.unavailableImageCount == 1)
        #expect(safe.bodyMarkup.contains("Linkziel:"))
        let defaultDocument = safe.document(dark: false)
        #expect(defaultDocument.contains("img-src data:") && !defaultDocument.contains("img-src https:") && defaultDocument.contains("script-src 'none'"))
        #expect(safe.document(dark: true, allowRemoteImages: true).contains("img-src https:"))
    }
    @Test func schemataAndEncodedControlCharactersFailClosed() throws {
        for value in ["javascript:alert(1)","data:text/html,hello","file:///tmp/x","mailto:x@example.com","https://user:pass@example.com/x","https://example.com/%0aheader","https://example.com/\nnext","//example.com/x"] { #expect(MailLinkPolicy.externalURL(value) == nil) }
        for value in ["http://example.com/image","https://127.0.0.1/x","https://[::1]/x","https://printer.local/x"] { #expect(MailLinkPolicy.remoteImageURL(value) == nil) }
        for raw in ["<a href='java&#x0A;script:alert(1)'>a</a>","<a href='jav&#x09;ascript:alert(1)'>b</a>","<IMG SRC='data:image/svg+xml,<svg onload=alert(1)>'>","<svg><foreignObject><p onclick='x'>test</p></foreignObject></svg>"] {
            let safe = try MailHTMLSanitizer.sanitize(raw)
            #expect(!safe.bodyMarkup.contains("href=") && !safe.bodyMarkup.contains("src=") && !safe.bodyMarkup.contains("onclick"))
        }
    }
    @Test func inputAndTreeBudgetsAreEnforced() throws {
        #expect(throws: HTMLRenderingFailure.tooLarge) { try MailHTMLSanitizer.sanitize(String(repeating: "x", count: MailHTMLSanitizer.maximumBodyBytes + 1)) }
        #expect(throws: HTMLRenderingFailure.tooComplex) { try MailHTMLSanitizer.sanitize(String(repeating: "<div>", count: 150) + "text" + String(repeating: "</div>", count: 150)) }
        let raw = String(repeating: "<img src='https://example.com/pixel'>", count: 60)
        let safe = try MailHTMLSanitizer.sanitize(raw)
        #expect(safe.remoteImageCount == 50 && safe.unavailableImageCount == 10)
    }
    @Test func malformedHTMLKeepsReadableTextWithoutActiveNodes() throws {
        let safe = try MailHTMLSanitizer.sanitize("<table><tr><td>Preis <b>CHF 20<div><a href=https://example.com/details>Details</table><p>Ende &amp; weiter")
        #expect(safe.plainText.contains("CHF 20") && safe.plainText.contains("Ende & weiter"))
        #expect(safe.bodyMarkup.contains("https://example.com/details"))
    }
}
