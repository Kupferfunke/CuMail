import Foundation
import MailDomain
import MailRendering

public struct MailSignature: Codable, Hashable, Sendable {
    public var enabled: Bool
    public let html: String
    public let plainText: String
    public init(html: String, enabled: Bool = true) throws {
        guard html.utf8.count <= 32768 else { throw ComposeFailure.tooLarge }
        let first = try MailHTMLSanitizer.signature(html)
        let clean = try MailHTMLSanitizer.signature(first.bodyMarkup)
        self.html = clean.bodyMarkup; plainText = clean.plainText; self.enabled = enabled
        try validate()
    }
    public func validate() throws {
        guard html.utf8.count <= 65536, plainText.utf8.count <= 32768 else { throw ComposeFailure.tooLarge }
        let clean = try MailHTMLSanitizer.signature(html)
        guard clean.bodyMarkup == html, clean.plainText == plainText else { throw ComposeFailure.invalidHeader }
    }
}

public protocol SignatureRepository: Sendable {
    func signature(account: AccountID) async throws -> MailSignature?
    func saveSignature(_ signature: MailSignature?, account: AccountID) async throws
    func signatureLibrary(account: AccountID) async throws -> SignatureLibrary
    func saveSignatureLibrary(_ library: SignatureLibrary, account: AccountID) async throws
}

public struct NamedMailSignature: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var content: MailSignature
    public init(id: UUID = UUID(), name: String, content: MailSignature) {
        self.id = id; self.name = name; self.content = content
    }
}

public struct SignatureLibrary: Codable, Hashable, Sendable {
    public var entries: [NamedMailSignature]
    public var defaultID: UUID?
    public init(entries: [NamedMailSignature] = [], defaultID: UUID? = nil) {
        self.entries = entries; self.defaultID = defaultID
    }
    public var defaultSignature: NamedMailSignature? { entries.first { $0.id == defaultID } }
    public func validate() throws {
        guard entries.count <= 20, Set(entries.map(\.id)).count == entries.count,
              Set(entries.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count == entries.count,
              entries.isEmpty ? defaultID == nil : defaultSignature != nil else { throw ComposeFailure.invalidHeader }
        for entry in entries {
            guard !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entry.name.count <= 80, entry.name.utf8.count <= 320 else { throw ComposeFailure.invalidHeader }
            try ComposeValidation.header(entry.name)
            try entry.content.validate()
        }
    }
}

public extension LocalDraft {
    mutating func useSignature(_ selected: NamedMailSignature?) {
        signature = selected?.content
        signature?.enabled = true
        signatureID = selected?.id; signatureName = selected?.name
    }
    var outgoingPlainText: String {
        var text = body
        if let signature, signature.enabled, !signature.plainText.isEmpty { text += "\n\n" + signature.plainText }
        if let quotation { text += "\n\n" + quotation.quotedPlainText }
        return text
    }
    var outgoingHTML: String? {
        let signatureHTML = signature.flatMap { $0.enabled && !$0.html.isEmpty ? $0.html : nil }
        guard signatureHTML != nil || quotation != nil else { return nil }
        func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>\n") }
        var text = "<div>" + escape(body) + "</div>"
        if let signatureHTML { text += "<br><div>" + signatureHTML + "</div>" }
        if let quotation {
            text += "<br><div>" + escape(quotation.heading) + "</div><blockquote style=\"margin:12px 0 0;padding-left:12px;border-left:2px solid #d6d6d6\">" + quotation.html.markup + "</blockquote>"
        }
        let stylesheet = quotation.map { "<style>" + $0.html.stylesheet + "</style>" } ?? ""
        return "<!doctype html><html><head><meta charset=\"utf-8\">" + stylesheet + "</head><body style=\"font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.45;color:#222222\">" + text + "</body></html>"
    }
}
