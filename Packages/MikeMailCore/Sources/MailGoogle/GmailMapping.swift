import Foundation
import MailRendering
import SwiftMail
import MailDomain
import MailApplication

struct GmailHeader: Decodable, Sendable { let name: String; let value: String }
struct GmailPart: Decodable, Sendable {
    struct Body: Decodable, Sendable { let size: Int?; let data: String?; let attachmentId: String? }
    let partId: String?
    let mimeType: String
    let filename: String?
    let headers: [GmailHeader]?
    let body: Body?
    let parts: [GmailPart]?
}
struct GmailMessage: Decodable, Sendable {
    let id, threadId: String
    let labelIds: [String]?
    let internalDate: String
    let payload: GmailPart
}
enum GmailMapping {
    static func message(_ wire: GmailMessage, account: AccountID, folders: [MailFolder]) throws -> (MailMessage, String) {
        guard GmailIdentity.validID(wire.id), GmailIdentity.validID(wire.threadId),
              let milliseconds = Double(wire.internalDate), milliseconds.isFinite,
              (0...32_503_680_000_000).contains(milliseconds), (wire.labelIds?.count ?? 0) <= 500,
              folders.allSatisfy({ $0.accountID == account }) else { throw GmailFailure.invalidResponse }
        let id = try GmailIdentity.message(account: account, id: wire.id)
        let thread = try GmailIdentity.thread(account: account, id: wire.threadId)
        let headers = wire.payload.headers ?? []
        guard headers.count <= 1000, headers.allSatisfy({ $0.name.utf8.count <= 256 && $0.value.utf8.count <= 65536 }) else { throw GmailFailure.tooLarge }
        func header(_ name: String) -> String? { headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
        func people(_ name: String) -> [MailPerson] {
            AddressParser.parseAddressList(header(name) ?? "").mailboxes.prefix(1000).compactMap {
                guard let address = try? MailDomain.EmailAddress($0.address) else { return nil }
                return MailPerson(name: $0.name ?? "", address: address)
            }
        }
        let sender = try people("From").first ?? MailPerson(name: "Unbekannter Absender", address: MailDomain.EmailAddress("unknown@example.invalid"))
        let to = people("To"), cc = people("Cc")
        var labels = Set(wire.labelIds ?? [])
        // Gmail keeps DRAFT on discarded drafts in TRASH, but excludes them
        // from its active Drafts view and drafts.list. Keep them in Trash only.
        if labels.contains("TRASH") { labels.remove("DRAFT") }
        if labels.isDisjoint(with: ["INBOX", "TRASH", "SPAM", "DRAFT"]) { labels.insert(GmailIdentity.archive) }
        let locations = Set(folders.filter { labels.contains($0.providerID) }.map(\.id))
        let all = try flatten(wire.payload)
        let attachments = try all.enumerated().filter { !($0.element.filename ?? "").isEmpty || ($0.element.mimeType.lowercased().hasPrefix("image/") && $0.element.headers?.contains { $0.name.lowercased() == "content-id" } == true) }.map { index, part in
            try AttachmentMetadata(id: IMAPIdentity.attachment(message: id, section: "gmail:\(part.partId ?? String(index))"), messageID: id,
                accountID: account, filename: String((part.filename ?? "Anhang").prefix(1024)), mimeType: part.mimeType,
                byteCount: Int64(max(0, part.body?.size ?? 0)),
                isInline: part.headers?.contains { $0.name.lowercased() == "content-disposition" && $0.value.lowercased().hasPrefix("inline") } == true,
                providerPartID: part.partId, contentID: part.headers?.first { $0.name.lowercased() == "content-id" }?.value)
        }
        let references = (header("References") ?? "").split(whereSeparator: \.isWhitespace).map(String.init).filter { (try? ComposeValidation.messageID($0)) != nil }
        let message = try MailMessage(id: id, accountID: account, locator: .gmail(id: wire.id), threadID: thread, folderIDs: locations,
            internetMessageID: header("Message-ID").flatMap { (try? ComposeValidation.messageID($0)) == nil ? nil : $0 },
            subject: String((header("Subject") ?? "(Ohne Betreff)").decodeMIMEHeader().prefix(16000)),
            sender: sender, recipients: Array((to + cc).prefix(1000)), receivedAt: Date(timeIntervalSince1970: milliseconds / 1000),
            isUnread: labels.contains("UNREAD"), isFlagged: labels.contains("STARRED"), preview: nil, attachments: attachments,
            inReplyTo: header("In-Reply-To").flatMap { (try? ComposeValidation.messageID($0)) == nil ? nil : $0 },
            references: Array(references.suffix(100)), threadingHeadersLoaded: true, ccRecipients: cc, replyTo: people("Reply-To"))
        return (message, wire.threadId)
    }
    static func flatten(_ root: GmailPart) throws -> [GmailPart] {
        var result: [GmailPart] = []
        func visit(_ part: GmailPart, depth: Int) throws {
            guard depth <= 20, result.count < 1000 else { throw GmailFailure.tooLarge }
            result.append(part)
            for child in part.parts ?? [] { try visit(child, depth: depth + 1) }
        }
        try visit(root, depth: 0); return result
    }
    static func bodyPart(_ root: GmailPart, preferHTML: Bool) throws -> GmailPart {
        var candidates: [GmailPart] = []
        var count = 0
        func visit(_ part: GmailPart, depth: Int) throws {
            count += 1; guard count <= 1000, depth <= 20 else { throw GmailFailure.tooLarge }
            // An attached mail or a named text attachment never becomes the displayed message body.
            guard (part.filename ?? "").isEmpty, part.mimeType.lowercased() != "message/rfc822",
                  part.headers?.contains(where: { $0.name.lowercased() == "content-disposition" && $0.value.lowercased().hasPrefix("attachment") }) != true else { return }
            if ["text/plain", "text/html"].contains(part.mimeType.lowercased()) { candidates.append(part) }
            for child in part.parts ?? [] { try visit(child, depth: depth + 1) }
        }
        try visit(root, depth: 0)
        guard let part = candidates.first(where: { $0.mimeType.lowercased() == (preferHTML ? "text/html" : "text/plain") }) ?? candidates.first else { throw GmailFailure.noBody }
        return part
    }
    static func inlineImageParts(_ root: GmailPart) throws -> [GmailPart] {
        var result: [GmailPart] = [], count = 0
        func visit(_ part: GmailPart, depth: Int) throws {
            count += 1; guard count <= 1000, depth <= 20 else { throw GmailFailure.tooLarge }
            guard !part.mimeType.lowercased().hasPrefix("message/") else { return }
            if InlineMailImage.supports(part.mimeType) { result.append(part) }
            // Do not resolve a content ID inside an attached multipart document.
            if part.mimeType.lowercased().hasPrefix("multipart/"),
               !(part.filename ?? "").isEmpty || part.headers?.contains(where: { $0.name.lowercased() == "content-disposition" && $0.value.lowercased().hasPrefix("attachment") }) == true { return }
            for child in part.parts ?? [] { try visit(child, depth: depth + 1) }
        }
        try visit(root, depth: 0); return result
    }
    static func decodedData(_ encoded: String, maximumBytes: Int) throws -> Data {
        guard encoded.utf8.count <= (maximumBytes + 2) / 3 * 4 else { throw GmailFailure.tooLarge }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let bytes = Data(base64Encoded: base64), bytes.count <= maximumBytes else { throw GmailFailure.invalidResponse }
        return bytes
    }
    static func body(_ encoded: String, mime: String, headers: [GmailHeader], maximumBytes: Int) throws -> MailBody {
        let bytes = try decodedData(encoded, maximumBytes: maximumBytes)
        let contentType = headers.first { $0.name.lowercased() == "content-type" }?.value ?? mime
        // Reuse the established MIME parser's charset handling for this single API-decoded part.
        guard contentType.utf8.count <= 2048, !contentType.contains("\r"), !contentType.contains("\n") else { throw GmailFailure.invalidResponse }
        var part = Data("Content-Type: \(contentType)\r\nContent-Transfer-Encoding: 8bit\r\n\r\n".utf8)
        part.append(bytes)
        let parsed = try EMLParser.parse(part)
        let html = mime.lowercased() == "text/html"
        guard let text = html ? parsed.htmlBody : parsed.textBody, text.utf8.count <= maximumBytes else { throw GmailFailure.noBody }
        return MailBody(text: text, format: html ? .html : .plainText)
    }
}
