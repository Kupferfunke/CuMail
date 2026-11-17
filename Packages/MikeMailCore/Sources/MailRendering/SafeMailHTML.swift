import Foundation
import SwiftSoup

public enum HTMLRenderingFailure: Error, Sendable { case tooLarge, tooComplex, invalid }

public enum MailLinkPolicy {
    public static func externalURL(_ raw: String) -> URL? {
        guard raw.utf8.count <= 4096,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
              let decoded = raw.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
    public static func remoteImageURL(_ raw: String) -> URL? {
        guard let url = externalURL(raw), url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              !host.contains(":"), !host.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return url
    }
}

/// This value can only be constructed by the parser-backed sanitizer. Reader HTML
/// is transient; deliberate replies retain their own QuotedMailHTML snapshot.
public struct SafeMailHTML: Sendable, Hashable {
    public let isSignature: Bool
    public let bodyMarkup: String
    public let stylesheet: String
    public let bodyAttributes: String
    public let plainText: String
    public let remoteImageCount: Int
    public let unavailableImageCount: Int

    public func document(dark: Bool, allowRemoteImages: Bool = false) -> String {
        // Received HTML is a document with its own colours. Recolouring only its
        // unstyled parts for dark mode makes many real emails unreadable.
        let themed = isSignature && dark
        let text = themed ? "#F3EEE5" : "#222222"
        let paper = themed ? "#202C2F" : "#FFFFFF"
        let accent = themed ? "#F9D09C" : "#1659A5"
        let images = allowRemoteImages ? "https: data:" : "data:"
        return """
        <!doctype html><html lang="de"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src \(images); font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; media-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="referrer" content="no-referrer"><style>
        :root{color-scheme:\(themed ? "dark" : "light");color:\(text);background-color:\(paper)}body{margin:0;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.4;overflow-wrap:break-word}
        a{color:\(accent)}pre{white-space:pre-wrap}
        </style><style>\(stylesheet)</style></head><body\(bodyAttributes)>\(bodyMarkup)</body></html>
        """
    }
}

public enum MailHTMLSanitizer {
    public static let maximumBodyBytes = 2 * 1024 * 1024
    public static func sanitize(_ html: String, inlineImages: [String: InlineMailImage] = [:]) throws -> SafeMailHTML {
        try sanitize(html, signature: false, inlineImages: inlineImages)
    }
    public static func signature(_ html: String) throws -> SafeMailHTML { try sanitize(html, signature: true, inlineImages: [:]) }
    // A deliberately saved reply can include the already resolved inline images.
    // The original network input limit stays unchanged.
    static func savedQuotation(_ html: String) throws -> SafeMailHTML {
        try sanitize(html, signature: false, inlineImages: [:], maximumInputBytes: 8 * 1024 * 1024)
    }
    public static func inlineContentIDs(in html: String) throws -> Set<String> {
        guard html.utf8.count <= maximumBodyBytes else { throw HTMLRenderingFailure.tooLarge }
        let document = try SwiftSoup.parse(html)
        return Set(try document.select("img[src]").array().compactMap { image in
            let value = try image.attr("src")
            guard value.lowercased().hasPrefix("cid:") else { return nil }
            return InlineMailImage.contentID(String(value.dropFirst(4)).removingPercentEncoding ?? "")
        }.prefix(InlineMailImage.maximumCount))
    }
    private static func sanitize(_ html: String, signature: Bool, inlineImages: [String: InlineMailImage], maximumInputBytes: Int = maximumBodyBytes) throws -> SafeMailHTML {
        guard html.utf8.count <= maximumInputBytes else { throw HTMLRenderingFailure.tooLarge }
        let document = try SwiftSoup.parse(html)
        var stack: [(Node, Int)] = [(document, 0)]
        var count = 0
        while let (node, depth) = stack.popLast() {
            count += 1
            guard count <= 30_000, depth <= 128 else { throw HTMLRenderingFailure.tooComplex }
            stack.append(contentsOf: node.getChildNodes().map { ($0, depth + 1) })
        }
        // Preserve inert layout rules, including responsive email styles. Active
        // elements and all network-capable CSS are removed independently of CSP.
        let stylesheet = signature ? "" : try document.select("style").array().map { MailCSS.stylesheet(try $0.data()) }.joined(separator: "\n")
        let originalBody = document.body()
        let bodyAttributeNames = ["style", "class", "id", "dir", "lang", "bgcolor", "text", "align"]
        let originalBodyAttributes = try bodyAttributeNames.compactMap { name -> (String, String)? in
            guard let originalBody, originalBody.hasAttr(name) else { return nil }
            return (name, try originalBody.attr(name))
        }
        try document.select("script,style,iframe,frame,frameset,object,embed,form,input,button,textarea,select,option,svg,math,template,video,audio,source,link,meta,base").remove()
        let allow = try Whitelist.none()
            .addTags("a","abbr","b","blockquote","br","caption","center","code","col","colgroup","dd","del","div","dl","dt","em","font","h1","h2","h3","h4","h5","h6","hr","i","img","li","ol","p","pre","s","small","span","strong","sub","sup","table","tbody","td","tfoot","th","thead","tr","u","ul")
            .addAttributes(":all", "style", "class", "id", "dir", "lang", "align")
            .addAttributes("a", "href", "title")
            .addAttributes("img", "src", "alt", "title", "width", "height", "border")
            .addAttributes("table", "width", "height", "border", "cellpadding", "cellspacing", "bgcolor")
            .addAttributes("tr", "bgcolor", "valign")
            .addAttributes("td", "colspan", "rowspan", "width", "height", "bgcolor", "valign")
            .addAttributes("th", "colspan", "rowspan", "width", "height", "bgcolor", "valign")
            .addAttributes("col", "span", "width")
            .addAttributes("colgroup", "span", "width")
            .addAttributes("font", "color", "face", "size")
            .addAttributes("ol", "start", "type")
            .addProtocols("a", "href", "http", "https")
            .addProtocols("img", "src", "https", "cid", "data")
        if signature {
            try allow.addAttributes(":all", "style")
            try allow.addAttributes("img", "width", "height")
            try allow.addProtocols("a", "href", "mailto", "tel")
        }
        let clean = try Cleaner(headWhitelist: nil, bodyWhitelist: allow).clean(document)
        // Pretty-printing injects visible whitespace in inline text and preformatted mail.
        clean.outputSettings().prettyPrint(pretty: false)
        if let body = clean.body() { for (name, value) in originalBodyAttributes { try body.attr(name, value) } }
        var remote = 0, unavailable = 0, embeddedBytes = 0, embeddedCount = 0
        for link in try clean.select("a[href]").array() {
            if let url = MailLinkPolicy.externalURL(try link.attr("href")) {
                try link.attr("href", url.absoluteString)
                try link.attr("title", "Linkziel: " + url.absoluteString)
                try link.attr("aria-label", (try link.text()) + ". Linkziel: " + url.absoluteString)
                try link.attr("rel", "noreferrer noopener")
            } else if signature, let contact = contactURL(try link.attr("href")) {
                try link.attr("href", contact)
            } else { try link.removeAttr("href") }
        }
        for image in try clean.select("img").array() {
            let source = try image.attr("src")
            let contentID = source.lowercased().hasPrefix("cid:") ? InlineMailImage.contentID(String(source.dropFirst(4)).removingPercentEncoding ?? "") : nil
            let embedded = contentID.flatMap { inlineImages[$0] } ?? InlineMailImage.dataURI(source)
            if !signature, let embedded, embeddedCount < InlineMailImage.maximumCount,
               embeddedBytes + embedded.data.count <= InlineMailImage.maximumTotalBytes {
                embeddedCount += 1; embeddedBytes += embedded.data.count
                try image.attr("src", embedded.dataURI)
            } else if let url = MailLinkPolicy.remoteImageURL(source), remote < 50 {
                remote += 1
                try image.attr("src", url.absoluteString)
                try image.attr("referrerpolicy", "no-referrer")
                if try image.attr("alt").isEmpty { try image.attr("alt", "Externes Bild") }
            } else {
                unavailable += 1
                try image.removeAttr("src")
                if try image.attr("alt").isEmpty { try image.attr("alt", "Bild nicht geladen") }
            }
        }
        for cell in try clean.select("td,th").array() {
            for name in ["colspan", "rowspan"] where cell.hasAttr(name) {
                guard let value = Int(try cell.attr(name)), (1...100).contains(value) else { try cell.removeAttr(name); continue }
            }
        }
        for element in try clean.select("[style]").array() {
                let css = signature ? safeSignatureCSS(try element.attr("style")) : MailCSS.declarations(try element.attr("style"))
                if css.isEmpty { try element.removeAttr("style") } else { try element.attr("style", css) }
        }
        for element in try clean.select("*").array() {
            for name in ["width", "height", "cellpadding", "cellspacing", "border", "span"] where element.hasAttr(name) {
                let value = try element.attr(name)
                let percent = value.hasSuffix("%")
                let number = Double(percent ? String(value.dropLast()) : value)
                if let number, number.isFinite, (0...(percent ? 100 : 10000)).contains(number) {} else { try element.removeAttr(name) }
            }
            for name in ["bgcolor", "color", "text"] where element.hasAttr(name) {
                if try element.attr(name).range(of: "^(#[A-Fa-f0-9]{3,8}|[A-Za-z]{1,24})$", options: .regularExpression) == nil { try element.removeAttr(name) }
            }
        }
        guard let body = clean.body() else { throw HTMLRenderingFailure.invalid }
        let bodyAttributes = try bodyAttributeNames.filter { body.hasAttr($0) }.map {
            " " + $0 + "=\"" + (try body.attr($0)).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") + "\""
        }.joined()
        let markup = try body.html()
        let plain: String
        if signature {
            // Preserve intentional line breaks in the plain-text MIME alternative.
            for element in try body.select("br").array() { try element.before("\n") }
            for element in try body.select("p,div,tr,li").array() { try element.after("\n") }
            plain = try body.text(trimAndNormaliseWhitespace: false).trimmingCharacters(in: .whitespacesAndNewlines)
        } else { plain = try body.text() }
        guard markup.utf8.count <= 8 * 1024 * 1024, plain.utf8.count <= maximumBodyBytes else { throw HTMLRenderingFailure.tooLarge }
        return SafeMailHTML(isSignature: signature, bodyMarkup: markup, stylesheet: stylesheet, bodyAttributes: bodyAttributes,
                            plainText: plain, remoteImageCount: remote, unavailableImageCount: unavailable)
    }
    private static func contactURL(_ raw: String) -> String? {
        guard raw.utf8.count <= 512, let decoded = raw.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !raw.contains("?"), !raw.contains("#") else { return nil }
        if raw.range(of: "^mailto:[A-Za-z0-9.!#$%&'*+/=_`{|}~-]+@[A-Za-z0-9.-]+$", options: .regularExpression) != nil { return raw }
        if raw.range(of: "^tel:[+0-9(). -]+$", options: .regularExpression) != nil { return raw }
        return nil
    }
    private static func safeSignatureCSS(_ raw: String) -> String {
        let allowed: Set<String> = ["color", "background-color", "font-family", "font-size", "font-weight", "font-style",
            "text-decoration", "text-align", "line-height", "letter-spacing", "vertical-align", "width", "height", "max-width",
            "padding", "padding-top", "padding-bottom", "padding-left", "padding-right", "margin", "margin-top", "margin-bottom",
            "border", "border-top", "border-bottom", "border-left", "border-right", "border-color", "border-width", "border-style", "border-collapse"]
        return raw.split(separator: ";").prefix(64).compactMap { declaration -> String? in
            let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, allowed.contains(parts[0].lowercased()), parts[1].utf8.count <= 256,
                  parts[1].range(of: "^[A-Za-z0-9 #.,%'\"-]+$", options: .regularExpression) != nil,
                  !parts[1].lowercased().contains("expression"), !parts[1].lowercased().contains("javascript") else { return nil }
            return parts[0].lowercased() + ":" + parts[1]
        }.joined(separator: ";")
    }

}
