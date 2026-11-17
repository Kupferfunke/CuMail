import Foundation
import CryptoKit
import MailDomain
import MailRendering

public enum ComposeFailure: Error, Equatable, Sendable {
    case invalidAddress, invalidHeader, tooLarge, missingRecipients, conflict, unavailable, accountMismatch
    case locked, missingConfiguration, missingCredential, connection, authentication, rejected, uncertain
    case attachmentUnavailable, attachmentChanged, sentCopyPending
}

public enum DraftStatus: String, Codable, Sendable {
    case editing, sending, failed, uncertain, accepted, sent
    public var editable: Bool { self == .editing || self == .failed }
}

/// Identifies an assistant-created message, without retaining source mail text.
/// The digest binds a retry to the original request; it is not a send authorization.
public struct AssistantDraftOrigin: Codable, Hashable, Sendable {
    public let messageID: MessageID?
    public let accountID: AccountID?
    public let requestDigest: String
    public init(messageID: MessageID, requestDigest: String) {
        self.messageID = messageID; self.accountID = nil; self.requestDigest = requestDigest
    }
    public init(accountID: AccountID, requestDigest: String) {
        self.messageID = nil; self.accountID = accountID; self.requestDigest = requestDigest
    }
}
/// Source compatibility; existing encoded reply origins retain the same keys.
public typealias AssistantReplyOrigin = AssistantDraftOrigin

/// References only. Attachment bytes are read into bounded RAM immediately before submission.
public struct DraftAttachment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public let filename: String
    public let mimeType: String
    public let byteCount: Int
    public let bookmark: Data
    public let digest: String
    public init(id: UUID = UUID(), filename: String, mimeType: String, byteCount: Int, bookmark: Data, digest: String) {
        self.id = id; self.filename = filename; self.mimeType = mimeType
        self.byteCount = byteCount; self.bookmark = bookmark; self.digest = digest
    }
}

/// The only locally retained message bodies belong to deliberate, user-created drafts.
public struct LocalDraft: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let accountID: AccountID
    public let sender: String
    public var to = ""
    public var cc = ""
    public var bcc = ""
    public var subject = ""
    public var body = ""
    public var quotation: DraftQuotation?
    public var sourceMessageID: MessageID?
    public var signature: MailSignature?
    public var signatureID: UUID?
    public var signatureName: String?
    public var attachments: [DraftAttachment] = []
    public var inReplyTo: String?
    public var references: [String] = []
    public var revision = 0
    public var modifiedAt = Date()
    public var status: DraftStatus = .editing
    public var operationID: UUID?
    public var internetMessageID: String?
    public var appendAttempted = false
    public var assistantOrigin: AssistantDraftOrigin?
    // Preserve the 0.25.0 payload key so saved forwards and send tokens remain
    // compatible. The same local source identity now also applies to replies.
    private enum CodingKeys: String, CodingKey {
        case id, accountID, sender, to, cc, bcc, subject, body, quotation
        case sourceMessageID = "forwardedMessageID"
        case signature, signatureID, signatureName, attachments, inReplyTo, references
        case revision, modifiedAt, status, operationID, internetMessageID, appendAttempted, assistantOrigin
    }
    public init(id: UUID = UUID(), accountID: AccountID, sender: String) {
        self.id = id; self.accountID = accountID; self.sender = sender
    }
    /// Binds an explicit assistant send to this exact stored version, including
    /// recipients, signature and human edits. This token alone is not consent.
    public func sendConfirmationToken() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
    public func validateStorage() throws {
        try signature?.validate()
        if let quotation {
            try ComposeValidation.header(quotation.heading)
            guard quotation.heading.utf8.count <= 8192, quotation.plainText.utf8.count <= MailHTMLSanitizer.maximumBodyBytes else { throw ComposeFailure.tooLarge }
        }
        if let origin = assistantOrigin {
            guard (origin.messageID == nil) != (origin.accountID == nil),
                  origin.accountID == nil || origin.accountID == accountID,
                  origin.requestDigest.count == 64,
                  origin.requestDigest.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw ComposeFailure.invalidHeader }
        }
        guard (signatureID == nil) == (signatureName == nil), signature != nil || signatureID == nil,
              (signatureName?.count ?? 0) <= 80 else { throw ComposeFailure.invalidHeader }
        if let signatureName { try ComposeValidation.header(signatureName) }
        guard body.utf8.count <= 262_144, subject.utf8.count <= 8192,
              [to, cc, bcc].allSatisfy({ $0.utf8.count <= 8192 }),
              attachments.count <= 20, Set(attachments.map(\.id)).count == attachments.count,
              attachments.allSatisfy({ (0...20_000_000).contains($0.byteCount) && $0.bookmark.count <= 32768 &&
                  $0.filename.utf8.count <= 1024 && $0.mimeType.utf8.count <= 256 && $0.digest.count == 64 }),
              attachments.reduce(0, { $0 + $1.byteCount }) <= 20_000_000,
              references.count <= 100, references.allSatisfy({ $0.utf8.count <= 1024 }),
              (inReplyTo?.utf8.count ?? 0) <= 1024,
              assistantOrigin == nil || assistantOrigin?.requestDigest.count == 64 else { throw ComposeFailure.tooLarge }
    }
    public func validateSubmission(requireRecipients: Bool = true) throws {
        try validateStorage()
        try ComposeValidation.header(subject)
        try ComposeValidation.address(sender)
        let recipients = try ComposeValidation.addresses(to) + ComposeValidation.addresses(cc) + ComposeValidation.addresses(bcc)
        guard !requireRecipients || !recipients.isEmpty else { throw ComposeFailure.missingRecipients }
        guard recipients.count <= 100 else { throw ComposeFailure.tooLarge }
        for value in references + [inReplyTo, internetMessageID].compactMap({ $0 }) { try ComposeValidation.messageID(value) }
        for file in attachments {
            try ComposeValidation.header(file.filename); try ComposeValidation.header(file.mimeType)
            guard !file.filename.isEmpty, !file.filename.contains("/"), !file.filename.contains("\\"),
                  !file.filename.contains("\""), !file.mimeType.contains("\""),
                  file.mimeType.range(of: "^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$", options: .regularExpression) != nil else { throw ComposeFailure.invalidHeader }
        }
    }
    public mutating func purgeContent() {
        to = ""; cc = ""; bcc = ""; body = ""; quotation = nil; signature = nil; signatureID = nil; signatureName = nil; attachments = []; inReplyTo = nil; references = []
    }
}

public struct DraftQuotation: Codable, Hashable, Sendable {
    public let heading: String
    public let plainText: String
    public let html: QuotedMailHTML
    public init(heading: String, plainText: String, html: SafeMailHTML) throws {
        self.heading = heading; self.plainText = plainText; self.html = try QuotedMailHTML(html)
    }
    public var quotedPlainText: String {
        heading + "\n" + plainText.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
    }
}

public enum ComposeValidation {
    public static func header(_ value: String) throws {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.value == 0x2028 || $0.value == 0x2029 }) else { throw ComposeFailure.invalidHeader }
    }
    /// Deliberately supports plain ASCII mailbox addresses, not display-name syntax.
    /// The established MIME library encodes headers; this guard rejects injection.
    public static func address(_ value: String) throws {
        try header(value)
        guard value.utf8.count <= 254, value.range(of: "^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$", options: .regularExpression) != nil,
              !value.contains("..") else { throw ComposeFailure.invalidAddress }
        _ = try MailDomain.EmailAddress(value)
    }
    public static func addresses(_ value: String) throws -> [String] {
        try header(value)
        if value.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        let values = value.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard values.count <= 100 else { throw ComposeFailure.tooLarge }
        var seen = Set<String>()
        return try values.filter { try address($0); return seen.insert($0.lowercased()).inserted }
    }
    public static func messageID(_ value: String) throws {
        try header(value)
        guard value.utf8.count <= 1024, value.first == "<", value.last == ">",
              value.dropFirst().dropLast().allSatisfy({ $0.isASCII && !$0.isWhitespace && $0 != "<" && $0 != ">" }),
              value.contains("@") else { throw ComposeFailure.invalidHeader }
    }
}

public enum ComposeKind: Sendable { case reply, replyAll, forward }
public enum DraftBuilder {
    public static func response(to message: MailMessage, kind: ComposeKind, sender: String, ownAddresses: Set<String>, quote: String, htmlQuote: SafeMailHTML? = nil, id: UUID = UUID()) throws -> LocalDraft {
        var draft = LocalDraft(id: id, accountID: message.accountID, sender: sender)
        let forwarding = kind == .forward
        draft.sourceMessageID = message.id
        draft.subject = message.subject.lowercased().hasPrefix(forwarding ? "fwd:" : "re:") ? message.subject : "\(forwarding ? "Fwd:" : "Re:") \(message.subject)"
        if !forwarding {
            let own = Set(ownAddresses.map { $0.lowercased() })
            let targets = message.replyTo.isEmpty ? [message.sender] : message.replyTo
            var seen = own
            func unique(_ people: [MailPerson]) -> [String] { people.map(\.address.value).filter { seen.insert($0.lowercased()).inserted } }
            var primary = unique(targets)
            if kind == .replyAll {
                primary += unique(message.recipients.filter { !message.ccRecipients.contains($0) })
                draft.cc = unique(message.ccRecipients).joined(separator: ", ")
            }
            // A message sent solely between the user's own identities still
            // has a valid reply target. Preserve its explicit Reply-To/From
            // only when excluding own identities removed every recipient.
            if primary.isEmpty, draft.cc.isEmpty, own.contains(message.sender.address.value.lowercased()),
               !message.recipients.isEmpty, message.recipients.allSatisfy({ own.contains($0.address.value.lowercased()) }),
               targets.allSatisfy({ own.contains($0.address.value.lowercased()) }) {
                seen = []; primary = unique(targets)
            }
            draft.to = primary.joined(separator: ", ")
            if let value = message.internetMessageID, (try? ComposeValidation.messageID(value)) != nil {
                draft.inReplyTo = value
                draft.references = Array((message.references.filter { (try? ComposeValidation.messageID($0)) != nil } + [value]).suffix(100))
            }
        }
        let heading = "\(forwarding ? "Weitergeleitete Nachricht" : "Antwort auf Nachricht") von \(message.sender.address.value):"
        if let htmlQuote {
            draft.quotation = try DraftQuotation(heading: heading, plainText: quote, html: htmlQuote)
        } else {
            let bounded = String(quote.prefix(60_000))
            draft.body = "\n\n" + heading + "\n" + bounded.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        }
        try draft.validateStorage()
        return draft
    }
}

public enum SentCopyPolicy: String, Codable, CaseIterable, Sendable { case appendToFolder, providerManaged }
public struct SMTPProfile: Codable, Equatable, Sendable {
    public let accountID: AccountID
    public let host: String
    public let port: Int
    public let security: String
    public let username: String
    public let sentPolicy: SentCopyPolicy
    public let sentFolder: String
    public init(accountID: AccountID, host: String, port: Int, security: IMAPSecurity, username: String, sentPolicy: SentCopyPolicy, sentFolder: String) throws {
        let config = try IMAPConfiguration(accountID: accountID, host: host, port: port, security: security, username: username)
        try ComposeValidation.header(sentFolder)
        guard !sentFolder.isEmpty, sentFolder.utf8.count <= 2048 else { throw ComposeFailure.missingConfiguration }
        self.accountID = accountID; self.host = config.host; self.port = port; self.security = security.rawValue
        self.username = username; self.sentPolicy = sentPolicy; self.sentFolder = sentFolder
    }
    public func validate() throws {
        guard let tls = IMAPSecurity(rawValue: security) else { throw ComposeFailure.missingConfiguration }
        _ = try SMTPProfile(accountID: accountID, host: host, port: port, security: tls, username: username, sentPolicy: sentPolicy, sentFolder: sentFolder)
    }
}

public protocol DraftRepository: Sendable {
    func signature(account: AccountID) async throws -> MailSignature?
    func signatureLibrary(account: AccountID) async throws -> SignatureLibrary
    func drafts(account: AccountID) async throws -> [LocalDraft]
    func draft(id: UUID, account: AccountID) async throws -> LocalDraft
    func saveDraft(_ draft: LocalDraft, expectedRevision: Int) async throws -> LocalDraft
    func discardDraft(id: UUID, account: AccountID, expectedRevision: Int) async throws
    func recoverInterruptedSubmissions() async throws
    func smtpProfile(account: AccountID) async throws -> SMTPProfile?
    func saveSMTPProfile(_ profile: SMTPProfile) async throws
}

public extension DraftRepository {
    func signature(account: AccountID) async throws -> MailSignature? { nil }
    func signatureLibrary(account: AccountID) async throws -> SignatureLibrary {
        guard let content = try await signature(account: account) else { return SignatureLibrary() }
        let entry = NamedMailSignature(id: account.rawValue, name: "Standard", content: content)
        return SignatureLibrary(entries: [entry], defaultID: entry.id)
    }
}

public struct OutgoingAttachment: Sendable {
    public let reference: DraftAttachment
    public let data: Data
    public init(reference: DraftAttachment, data: Data) { self.reference = reference; self.data = data }
}
public struct PreparedSubmission: Sendable {
    public let rawMessage: String
    public let sender: String
    public let recipients: [String]
    public init(rawMessage: String, sender: String, recipients: [String]) { self.rawMessage = rawMessage; self.sender = sender; self.recipients = recipients }
}
public protocol SMTPSubmissionSession: Sendable {
    func connect() async throws
    func prepare(_ draft: LocalDraft, attachments: [OutgoingAttachment]) async throws -> PreparedSubmission
    func submit(_ prepared: PreparedSubmission) async throws
    func disconnect() async
}
public protocol SentCopySession: Sendable {
    func connect() async throws
    func contains(messageID: String, folder: String) async throws -> Bool
    func append(_ rawMessage: String, folder: String) async throws
    func disconnect() async
}
public typealias SMTPFactory = @Sendable (SMTPProfile, String) -> any SMTPSubmissionSession
public typealias SentCopyFactory = @Sendable (IMAPConfiguration, String) -> any SentCopySession
