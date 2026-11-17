import Foundation
import CryptoKit
import SwiftMail
import MailDomain
import MailApplication

public enum SwiftMailMIMEEncoder {
    public static func prepare(_ draft: LocalDraft, attachments: [OutgoingAttachment], includeBcc: Bool = false, maximumBytes: Int = 30_000_000, requireRecipients: Bool = true) throws -> PreparedSubmission {
        try draft.validateSubmission(requireRecipients: requireRecipients)
        guard let id = draft.internetMessageID, let messageID = SwiftMail.MessageID(id), attachments.map(\.reference) == draft.attachments else { throw ComposeFailure.invalidHeader }
        var parts = try attachments.map { attachment -> SwiftMail.Attachment in
            let reference = attachment.reference
            guard attachment.data.count == reference.byteCount,
                  SHA256.hash(data: attachment.data).map({ String(format: "%02x", $0) }).joined() == reference.digest else { throw ComposeFailure.attachmentChanged }
            return SwiftMail.Attachment(filename: reference.filename, mimeType: reference.mimeType, data: attachment.data)
        }
        for (index, image) in (draft.quotation?.html.images ?? []).enumerated() {
            let suffix = image.raster.mimeType.components(separatedBy: "/").last ?? "image"
            parts.append(SwiftMail.Attachment(filename: "original-\(index + 1).\(suffix)", mimeType: image.raster.mimeType,
                data: image.raster.data, contentID: image.contentID, isInline: true))
        }
        let to = try ComposeValidation.addresses(draft.to), cc = try ComposeValidation.addresses(draft.cc), bcc = try ComposeValidation.addresses(draft.bcc)
        func addresses(_ values: [String]) -> [SwiftMail.EmailAddress] { values.map { SwiftMail.EmailAddress(address: $0) } }
        var email = SwiftMail.Email(sender: SwiftMail.EmailAddress(address: draft.sender), recipients: addresses(to), ccRecipients: addresses(cc), bccRecipients: addresses(bcc), subject: draft.subject, textBody: draft.outgoingPlainText, htmlBody: draft.outgoingHTML, attachments: parts)
        email.messageID = messageID
        var headers: [String: String] = [:]
        if let parent = draft.inReplyTo { headers["In-Reply-To"] = parent }
        if !draft.references.isEmpty { headers["References"] = draft.references.joined(separator: " ") }
        if includeBcc, !bcc.isEmpty { headers["Bcc"] = bcc.joined(separator: ", ") }
        email.additionalHeaders = headers
        // The library handles quoted-printable, RFC 2047 and attachment base64.
        // Gmail delivers using MIME headers; SMTP keeps Bcc in the envelope only.
        var raw = email.constructContent(use8BitMIME: false)
        if !raw.hasSuffix("\r\n") { raw += "\r\n" }
        guard raw.utf8.count <= maximumBytes else { throw ComposeFailure.tooLarge }
        var seen = Set<String>()
        return PreparedSubmission(rawMessage: raw, sender: draft.sender, recipients: (to + cc + bcc).filter { seen.insert($0.lowercased()).inserted })
    }
}
