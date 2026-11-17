import Foundation
import SwiftSoup

/// A sanitized snapshot retained only as part of a deliberately created draft.
/// Decoding always sanitizes again. Derived MIME parts are never trusted from JSON.
public struct QuotedMailHTML: Codable, Hashable, Sendable {
    public struct Image: Hashable, Sendable {
        public let contentID: String
        public let raster: InlineMailImage
    }
    public let id: UUID
    public let preview: SafeMailHTML
    public let markup: String
    public let stylesheet: String
    public let images: [Image]
    private let source: String

    public init(_ html: SafeMailHTML, id: UUID = UUID()) throws {
        self.id = id
        let source = "<!doctype html><html><head><style>" + html.stylesheet + "</style></head><body" + html.bodyAttributes + ">" + html.bodyMarkup + "</body></html>"
        guard source.utf8.count <= 8 * 1024 * 1024 else { throw HTMLRenderingFailure.tooLarge }
        self.source = source; preview = html
        let document = try SwiftSoup.parse(source)
        document.outputSettings().prettyPrint(pretty: false)
        guard let body = document.body() else { throw HTMLRenderingFailure.invalid }
        var images: [Image] = [], contentIDs: [String: String] = [:]
        for element in try body.select("img[src]").array() {
            let src = try element.attr("src")
            guard let image = InlineMailImage.dataURI(src) else { continue }
            let contentID: String
            if let existing = contentIDs[src] { contentID = existing }
            else {
                contentID = "cumail-quote-\(id.uuidString.lowercased())-\(images.count)@inline.cumail"
                contentIDs[src] = contentID; images.append(Image(contentID: contentID, raster: image))
            }
            try element.attr("src", "cid:" + contentID)
        }
        self.images = images
        try body.tagName("div")
        try body.addClass("cumail-original-body")
        var legacyStyle = "margin:0;"
        if body.hasAttr("bgcolor") { legacyStyle += "background-color:" + (try body.attr("bgcolor")) + ";" }
        if body.hasAttr("text") { legacyStyle += "color:" + (try body.attr("text")) + ";" }
        try body.attr("style", legacyStyle + (try body.attr("style")))
        let scope = "cumail-quote-" + id.uuidString.lowercased()
        stylesheet = MailCSS.quotedStylesheet(html.stylesheet, scope: "#" + scope)
        // Match the reader's neutral defaults. Sender CSS applies only inside this
        // wrapper, so it cannot recolour or hide the new answer or its signature.
        markup = "<div id=\"" + scope + "\" style=\"color:#222222;background-color:#FFFFFF;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.4;overflow-wrap:break-word\"><div class=\"cumail-original-html\">" + (try body.outerHtml()) + "</div></div>"
    }
    private enum CodingKeys: String, CodingKey { case id, source }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(String.self, forKey: .source)
        try self.init(MailHTMLSanitizer.savedQuotation(source), id: container.decode(UUID.self, forKey: .id))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id); try container.encode(source, forKey: .source)
    }
}
