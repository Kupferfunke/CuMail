import Foundation
import CryptoKit
import SwiftMail
import MailDomain
import MailApplication

public actor SwiftMailSubmission: SMTPSubmissionSession {
    private let profile: SMTPProfile
    private let server: SMTPServer
    private var password: String
    public init(profile: SMTPProfile, password: String) {
        _ = SwiftMailTransport.silenceProtocolLogs
        self.profile = profile; self.password = password
        server = SMTPServer(host: profile.host, port: profile.port,
            transportSecurity: profile.security == IMAPSecurity.implicitTLS.rawValue ? .implicitTLS : .startTLS,
            certificateVerificationPolicy: .fullVerification, minimumTLSVersion: .tlsv12,
            submissionTimeouts: SMTPSubmissionTimeouts(mailFromResponse: 30, recipientResponse: 30, dataResponse: 30, contentUpload: 60, contentResponse: 60))
    }
    init(profile: SMTPProfile, password: String, server: SMTPServer) {
        _ = SwiftMailTransport.silenceProtocolLogs
        self.profile = profile; self.password = password; self.server = server
    }
    public func connect() async throws {
        try profile.validate()
        do {
            try await server.connect()
            try await server.login(username: profile.username, password: password)
            password = ""
        } catch { password = ""; throw ComposeFailure.connection }
    }
    public func prepare(_ draft: LocalDraft, attachments: [OutgoingAttachment]) async throws -> PreparedSubmission {
        guard draft.accountID == profile.accountID else { throw ComposeFailure.accountMismatch }
        let limit = min(await server.maximumMessageSizeOctets ?? 30_000_000, 30_000_000)
        return try SwiftMailMIMEEncoder.prepare(draft, attachments: attachments, maximumBytes: limit)
    }

    public func submit(_ prepared: PreparedSubmission) async throws {
        do {
            // Pinned SwiftMail 1.16 appends CRLF before the DATA terminator even
            // when input already ends in CRLF. Remove exactly that final pair so
            // the delivered bytes and the IMAP Sent copy remain identical.
            var bytes = Data(prepared.rawMessage.utf8)
            if bytes.suffix(2) == Data([13, 10]) { bytes.removeLast(2) }
            _ = try await server.sendRawMessage(bytes, from: SwiftMail.EmailAddress(address: prepared.sender), to: prepared.recipients.map { SwiftMail.EmailAddress(address: $0) })
        } catch let error as SMTPSendError {
            throw error.acceptance == .ambiguous ? ComposeFailure.uncertain : ComposeFailure.rejected
        } catch is SMTPError {
            // SwiftMail wraps every failure after MAIL FROM in SMTPSendError.
            throw ComposeFailure.rejected
        } catch { throw ComposeFailure.uncertain }
    }
    public func disconnect() async { password = ""; try? await server.disconnect() }
}

/// APPEND only for the explicitly selected same-account Sent folder. No deletion,
/// draft mutation, EXPUNGE, or SMTP capability is exposed by this connection.
public actor SwiftMailSentCopy: SentCopySession {
    private let configuration: IMAPConfiguration
    private let server: IMAPServer
    private var password: String
    public init(configuration: IMAPConfiguration, password: String) {
        _ = SwiftMailTransport.silenceProtocolLogs
        self.configuration = configuration; self.password = password
        server = IMAPServer(host: configuration.host, port: configuration.port,
            transportSecurity: configuration.security == .implicitTLS ? .implicitTLS : .startTLS,
            certificateVerificationPolicy: .fullVerification, minimumTLSVersion: .tlsv12,
            responseBufferLimit: 1024 * 1024,
            parserLimits: IMAPParserLimits(bodySizeLimit: 8192, messageAttributeLimit: 64, literalSizeLimit: 8192))
    }
    public func connect() async throws {
        do { try await server.connect(); try await server.login(username: configuration.username, password: password); password = "" }
        catch { password = ""; throw ComposeFailure.connection }
    }
    public func contains(messageID: String, folder: String) async throws -> Bool {
        try ComposeValidation.messageID(messageID); try ComposeValidation.header(folder)
        let selected = try await server.examineMailbox(folder)
        guard selected.isReadOnly else { throw ComposeFailure.sentCopyPending }
        let result: ExtendedSearchResult<UID> = try await server.extendedSearch(criteria: [.header("Message-ID", messageID)])
        // HEADER is a substring search. Confirm the exact parsed Message-ID.
        let count = result.count ?? result.all?.count ?? 0
        guard count >= 0, count <= 20, (result.all?.count ?? 0) <= 20 else { throw ComposeFailure.sentCopyPending }
        guard let ids = result.all, !ids.isEmpty else { return false }
        let infos = try await server.fetchMessageInfosBulk(using: ids, options: [.envelope])
        return infos.contains { $0.messageId?.description == messageID }
    }
    public func append(_ rawMessage: String, folder: String) async throws {
        try ComposeValidation.header(folder)
        guard !folder.isEmpty, rawMessage.utf8.count <= 30_000_000 else { throw ComposeFailure.tooLarge }
        _ = try await server.append(rawMessage: rawMessage, to: folder, flags: [.seen], internalDate: Date())
    }
    public func disconnect() async { password = ""; try? await server.disconnect() }
}
