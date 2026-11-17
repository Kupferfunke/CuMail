import Foundation
import SwiftMail
import Logging
import MailDomain
import MailApplication
import MailRendering
import struct NIOIMAPCore.MailboxPath
import struct NIOIMAPCore.MailboxName

/// The sole production IMAP adapter. No write-capable library object escapes this actor.
public actor SwiftMailTransport: IMAPWriteSession, IMAPCatalogSession, AttachmentSource {
    private let configuration: IMAPConfiguration
    private var password: String
    private let server: IMAPServer
    private var disconnected = false
    static let silenceProtocolLogs: Void = {
        // SwiftMail's diagnostic loggers include credentials, headers and body chunks.
        // They must never reach stdout, unified logging, or a file in this process.
        LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }
    }()
    public init(configuration: IMAPConfiguration, password: String) {
        _ = Self.silenceProtocolLogs
        self.configuration = configuration; self.password = password
        server = IMAPServer(host: configuration.host, port: configuration.port,
            transportSecurity: configuration.security == .implicitTLS ? .implicitTLS : .startTLS,
            certificateVerificationPolicy: .fullVerification, minimumTLSVersion: .tlsv12,
            responseBufferLimit: 1024 * 1024,
            parserLimits: IMAPParserLimits(bodySizeLimit: 512 * 1024, messageAttributeLimit: 64, literalSizeLimit: 8192))
    }
    /// Test-only seam for a disposable loopback TLS fixture. Not exported to app callers.
    init(configuration: IMAPConfiguration, password: String, fixtureServer: IMAPServer) {
        _ = Self.silenceProtocolLogs
        self.configuration = configuration; self.password = password; server = fixtureServer
    }
    public func connect() async throws {
        try check()
        do {
            try await server.connect()
            try check()
            try await server.login(username: configuration.username, password: password)
            password = ""
            try check()
        } catch { throw sanitized(error) }
    }
    public func disconnect() async {
        disconnected = true; password = ""
        // Disconnect, never CLOSE (which could expunge a mailbox).
        try? await server.disconnect()
    }
    public func folders() async throws -> [MailFolder] {
        try check()
        do {
            let boxes = try await server.listMailboxes()
            try check()
            guard boxes.count <= 500 else { throw IMAPFailure.invalidResponse }
            return try boxes.filter(\.isSelectable).map { box in
                let mailbox = box.name.caseInsensitiveCompare("INBOX") == .orderedSame ? "INBOX" : box.name
                guard !mailbox.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw IMAPFailure.invalidResponse }
                let role: FolderRole
                if mailbox == "INBOX" || box.attributes.contains(.inbox) { role = .inbox }
                else if box.attributes.contains(.sent) { role = .sent }
                else if box.attributes.contains(.drafts) { role = .drafts }
                else if box.attributes.contains(.trash) { role = .trash }
                else if box.attributes.contains(.archive) { role = .archive }
                else { role = .custom }
                let path = try MailboxPath(name: MailboxName(Array(mailbox.utf8)))
                let name = path.displayStringComponents().joined()
                return try MailFolder(id: IMAPIdentity.folder(account: configuration.accountID, mailbox: mailbox),
                    accountID: configuration.accountID, providerID: mailbox, name: Self.display(name, limit: 2048), role: role)
            }
        } catch { throw sanitized(error) }
    }
    public func readFolder(_ folder: MailFolder, checkpoint: IMAPCheckpoint?) async throws -> IMAPFolderBatch {
        try check()
        guard folder.accountID == configuration.accountID else { throw MailFailure.permissionDenied }
        do {
            let selected = try await examine(folder.providerID)
            let flags = try await window(selected)
            let known = checkpoint?.uidValidity == selected.uidValidity.value ? checkpoint?.knownUIDs ?? [] : []
            let missing = flags.map(\.uid).filter { !known.contains($0) }.sorted()
            var messages: [MailMessage] = []
            for start in stride(from: 0, to: missing.count, by: 20) {
                try check()
                let uids = Array(missing[start..<min(start + 20, missing.count)])
                let infos = try await server.fetchMessageInfosBulk(using: UIDSet(uids.map { UID($0) }),
                    options: [.envelope, .internalDate, .flags, .size, .bodyStructure], headerFields: ["References", "In-Reply-To"])
                guard infos.count == uids.count, Set(infos.compactMap { $0.uid?.value }) == Set(uids) else {
                    throw IMAPFailure.mailboxChanged
                }
                messages += try infos.map { try Self.message($0, account: configuration.accountID, folder: folder, validity: selected.uidValidity.value) }
            }
            // A concurrent expunge/new arrival or mailbox replacement invalidates this attempt.
            // Repeat the bounded UID window before committing anything, keeping old cache on failure.
            let verified = try await examine(folder.providerID)
            guard verified.uidValidity == selected.uidValidity, verified.messageCount == selected.messageCount,
                  verified.uidNext == selected.uidNext else { throw IMAPFailure.mailboxChanged }
            let finalFlags = try await window(verified)
            guard Set(finalFlags.map(\.uid)) == Set(flags.map(\.uid)) else { throw IMAPFailure.mailboxChanged }
            try check()
            return try IMAPFolderBatch(uidValidity: selected.uidValidity.value, totalOnServer: selected.messageCount,
                                       flags: finalFlags, newMessages: messages)
        } catch { throw sanitized(error) }
    }
    public func catalog(folder: MailFolder, checkpoint: IMAPCheckpoint?, page: PageRequest) async throws -> OnlineSearchPage {
        try await searchPage(folder: folder, query: MailSearchQuery(), page: page, checkpoint: checkpoint, catalog: true)
    }
    public func search(folder: MailFolder, query: MailSearchQuery, page: PageRequest) async throws -> OnlineSearchPage {
        try await searchPage(folder: folder, query: query, page: page, checkpoint: nil, catalog: false)
    }
    private func searchPage(folder: MailFolder, query: MailSearchQuery, page: PageRequest, checkpoint: IMAPCheckpoint?, catalog: Bool) async throws -> OnlineSearchPage {
        try check(); try query.validate()
        guard folder.accountID == configuration.accountID,
              folder.id == (try IMAPIdentity.folder(account: configuration.accountID, mailbox: folder.providerID)) else { throw MailFailure.permissionDenied }
        guard query.supportsOnline else { throw SearchFailure.onlineFilterUnsupported }
        do {
            let selected = try await examine(folder.providerID)
            guard selected.uidNext.value > 0 else { throw IMAPFailure.invalidResponse }
            let latest = selected.uidNext.value - 1
            let fingerprint = query.fingerprint(context: [configuration.accountID.description, folder.id.description, folder.providerID])
            var upper = latest, ceiling = latest
            if let cursor = page.cursor {
                let parts = cursor.split(separator: "|")
                guard parts.count == 5, parts[0] == "os1", UInt32(parts[1]) == selected.uidValidity.value,
                      let high = UInt32(parts[2]), let originalCeiling = UInt32(parts[3]),
                      high > 0, high <= originalCeiling, originalCeiling <= latest, parts[4] == fingerprint else { throw SearchFailure.invalidCursor }
                upper = high; ceiling = originalCeiling
            }
            guard upper > 0, selected.messageCount > 0 else {
                return OnlineSearchPage(items: [], nextCursor: nil, totalMessagesInFolder: selected.messageCount, uidValidity: selected.uidValidity.value)
            }
            // A bounded UID interval works even without ESEARCH/PARTIAL. Never expand an unbounded ALL set.
            let lower = upper > 4095 ? upper - 4095 : 1
            var criteria: [SearchCriteria] = []
            for term in query.terms {
                switch term.field {
                case .any: criteria.append(.text(term.value))
                case .sender: criteria.append(.from(term.value))
                case .recipient: criteria.append(.or(.to(term.value), .cc(term.value)))
                case .subject: criteria.append(.subject(term.value))
                case .filename: throw SearchFailure.onlineFilterUnsupported
                }
            }
            if let value = query.unread { criteria.append(value ? .unseen : .seen) }
            if let value = query.flagged { criteria.append(value ? .flagged : .unflagged) }
            // IMAP ignores time/zone in INTERNALDATE day searches. Widen one day, then apply exact absolute bounds.
            if let date = query.after { criteria.append(.since(date.addingTimeInterval(-86400))) }
            if let date = query.before { criteria.append(.before(date.addingTimeInterval(86400))) }
            if criteria.isEmpty { criteria = [.all] }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let found: ExtendedSearchResult<UID> = try await server.extendedSearch(
                identifierSet: UIDSet(Int(lower)...Int(upper)), criteria: criteria, calendar: calendar)
            guard (0...4096).contains(found.count ?? 0), (found.all?.count ?? 0) <= 4096,
                  found.count.map({ $0 == (found.all?.count ?? 0) }) ?? true,
                  found.all?.ranges.allSatisfy({ $0.lowerBound >= Int(lower) && $0.upperBound <= Int(upper) }) ?? true,
                  found.all != nil || (found.count ?? 0) == 0 else { throw IMAPFailure.invalidResponse }
            let matches = (found.all?.toArray() ?? []).map(\.value).sorted(by: >)
            let uids = Array(matches.prefix(page.limit))
            let known = catalog && checkpoint?.uidValidity == selected.uidValidity.value ? checkpoint?.knownUIDs ?? [] : []
            let missing = uids.filter { !known.contains($0) }
            let cached = uids.filter { known.contains($0) }
            var flags: [IMAPFlags] = []
            if !cached.isEmpty {
                let infos = try await server.fetchMessageInfosBulk(using: UIDSet(cached.map { UID($0) }), options: [.flags])
                guard infos.count == cached.count, Set(infos.compactMap { $0.uid?.value }) == Set(cached) else { throw IMAPFailure.mailboxChanged }
                flags = infos.compactMap { info in
                    info.uid.map { IMAPFlags(uid: $0.value, unread: !info.flags.contains(.seen), flagged: info.flags.contains(.flagged)) }
                }
            }
            var messages: [MailMessage] = []
            for start in stride(from: 0, to: missing.count, by: 20) {
                try check()
                let batch = Array(missing[start..<min(start + 20, missing.count)])
                let infos = try await server.fetchMessageInfosBulk(using: UIDSet(batch.map { UID($0) }),
                    options: [.envelope, .internalDate, .flags, .size, .bodyStructure], headerFields: ["References", "In-Reply-To"])
                guard infos.count == batch.count, Set(infos.compactMap { $0.uid?.value }) == Set(batch) else { throw IMAPFailure.mailboxChanged }
                messages += try infos.map { try Self.message($0, account: configuration.accountID, folder: folder, validity: selected.uidValidity.value) }
            }
            guard try await examine(folder.providerID).uidValidity == selected.uidValidity else { throw IMAPFailure.mailboxChanged }
            flags += messages.compactMap { message in
                guard case .imap(_, _, let uid) = message.locator else { return nil }
                return IMAPFlags(uid: uid, unread: message.isUnread, flagged: message.isFlagged)
            }
            let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
            let ordered = try uids.compactMap { uid in
                byID[try IMAPIdentity.message(account: configuration.accountID, mailbox: folder.providerID, validity: selected.uidValidity.value, uid: uid)]
            }.filter { query.matchesDate($0.receivedAt) }
            let nextUpper = matches.count > uids.count ? (uids.last ?? lower) - 1 : lower - 1
            let next = nextUpper > 0 ? "os1|\(selected.uidValidity.value)|\(nextUpper)|\(ceiling)|\(fingerprint)" : nil
            try check()
            return OnlineSearchPage(items: ordered, nextCursor: next, totalMessagesInFolder: selected.messageCount, uidValidity: selected.uidValidity.value, indexedFlags: catalog ? flags : nil)
        } catch {
            if error is SearchFailure { throw error }
            throw sanitized(error)
        }
    }
    public func plainText(_ request: ContentRequest) async throws -> String {
        try await fetchBody(request, preferHTML: false, htmlFallback: false).text
    }
    public func body(_ request: ContentRequest, preferHTML: Bool) async throws -> MailBody {
        try await fetchBody(request, preferHTML: preferHTML, htmlFallback: true)
    }
    private func fetchBody(_ request: ContentRequest, preferHTML: Bool, htmlFallback: Bool) async throws -> MailBody {
        try check()
        guard request.accountID == configuration.accountID,
              case .imap(let mailbox, let validity, let rawUID) = request.locator else { throw MailFailure.permissionDenied }
        do {
            let selected = try await examine(mailbox)
            guard selected.uidValidity.value == validity else { throw IMAPFailure.mailboxChanged }
            guard let info = try await server.fetchMessageInfo(for: UID(rawUID), options: [.bodyStructure]),
                  info.uid?.value == rawUID else { throw MailFailure.notFound }
            let limit = min(request.maximumBytes, preferHTML ? MailHTMLSanitizer.maximumBodyBytes : 256 * 1024)
            let eligible = info.parts.filter { candidate in
                let mime = candidate.contentType.lowercased()
                guard (["text/plain", "text/html"].contains(mime.components(separatedBy: ";")[0])),
                      candidate.filename == nil, candidate.disposition?.lowercased() != "attachment" else { return false }
                return !info.parts.contains { parent in
                    candidate.section.description.hasPrefix(parent.section.description + ".") &&
                    (parent.filename != nil || parent.disposition?.lowercased() == "attachment" || parent.contentType.lowercased().hasPrefix("message/"))
                }
            }
            let plain = eligible.first { $0.contentType.lowercased().hasPrefix("text/plain") }
            let html = eligible.first { $0.contentType.lowercased().hasPrefix("text/html") }
            guard var part = (preferHTML ? html ?? plain : plain ?? (htmlFallback ? html : nil)) else { throw IMAPFailure.noPlainText }
            guard (part.size ?? 0) <= limit else { throw IMAPFailure.contentTooLarge }
            try check()
            var bytes = Data()
            while bytes.count <= limit {
                try check()
                let amount = min(64 * 1024, limit + 1 - bytes.count)
                let chunk = try await server.fetchPart(section: part.section, of: UID(rawUID), offset: bytes.count, count: amount)
                bytes.append(chunk)
                if chunk.count < amount { break }
            }
            guard bytes.count <= limit else { throw IMAPFailure.contentTooLarge }
            guard !bytes.isEmpty || (part.size ?? 0) == 0 else { throw MailFailure.notFound }
            let after = try await examine(mailbox)
            guard after.uidValidity.value == validity else { throw IMAPFailure.mailboxChanged }
            part.data = bytes
            guard let text = part.textContent else { throw IMAPFailure.invalidResponse }
            guard text.utf8.count <= limit else { throw IMAPFailure.contentTooLarge }
            var inlineImages: [String: InlineMailImage] = [:]
            if preferHTML, part.contentType.lowercased().hasPrefix("text/html") {
                let references = try MailHTMLSanitizer.inlineContentIDs(in: text)
                var total = 0
                let candidates = info.parts.filter { candidate in
                    InlineMailImage.supports(candidate.contentType) && !info.parts.contains { parent in
                        candidate.section.description.hasPrefix(parent.section.description + ".") &&
                        (parent.contentType.lowercased().hasPrefix("message/") || parent.disposition?.lowercased() == "attachment")
                    }
                }
                for reference in references.sorted() {
                    let matches = candidates.filter { InlineMailImage.contentID($0.contentId ?? "") == reference }
                    guard matches.count == 1, var imagePart = matches.first, let size = imagePart.size,
                          size > 0, size <= InlineMailImage.maximumBytes,
                          total + size <= InlineMailImage.maximumTotalBytes else { continue }
                    // Only referenced raster MIME parts from this message, using PEEK.
                    // A broken optional image must not hide the readable message body.
                    do {
                        var bytes = Data()
                        while bytes.count < size {
                            try check()
                            let amount = min(16 * 1024, size - bytes.count)
                            let chunk = try await server.fetchPart(section: imagePart.section, of: UID(rawUID), offset: bytes.count, count: amount)
                            guard chunk.count == amount else { throw AttachmentFailure.changed }
                            bytes.append(chunk)
                        }
                        imagePart.data = bytes
                        if let decoded = imagePart.decodedData(), let image = InlineMailImage(data: decoded) {
                            inlineImages[reference] = image; total += size
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { try check() }
                }
                guard try await examine(mailbox).uidValidity.value == validity else { throw IMAPFailure.mailboxChanged }
            }
            try check()
            return MailBody(text: text.replacingOccurrences(of: "\0", with: ""), format: part.contentType.lowercased().hasPrefix("text/html") ? .html : .plainText, inlineImages: inlineImages)
        } catch { throw sanitized(error) }
    }
    public func download(_ request: AttachmentRequest, sink: @escaping AttachmentSink,
                         progress: @escaping AttachmentProgress) async throws {
        try check()
        guard request.accountID == configuration.accountID,
              case .imap(let mailbox, let validity, let uid) = request.locator,
              request.messageID == (try IMAPIdentity.message(account: configuration.accountID, mailbox: mailbox, validity: validity, uid: uid)),
              let section = request.attachment.providerPartID,
              request.attachment.id == (try IMAPIdentity.attachment(message: request.messageID, section: section))
        else { throw MailFailure.permissionDenied }
        do {
            guard try await examine(mailbox).uidValidity.value == validity else { throw IMAPFailure.mailboxChanged }
            guard let info = try await server.fetchMessageInfo(for: UID(uid), options: [.bodyStructure]),
                  info.uid?.value == uid, info.parts.count <= 1000 else { throw MailFailure.notFound }
            let matches = info.parts.filter { $0.section.description == section }
            guard matches.count == 1, var part = matches.first,
                  let size = part.size, size >= 0, Int64(size) == request.attachment.byteCount,
                  part.contentType == request.attachment.mimeType else { throw AttachmentFailure.changed }
            guard size <= AttachmentRequest.byteLimit else { throw AttachmentFailure.tooLarge }
            let encoding = part.encoding?.lowercased() ?? "7bit"
            guard ["7bit", "8bit", "binary", "base64", "quoted-printable"].contains(encoding)
            else { throw AttachmentFailure.unsupportedEncoding }
            let buffered = ["base64", "quoted-printable"].contains(encoding)
            var encoded = Data(), offset = 0
            if buffered { encoded.reserveCapacity(size) }
            await progress(0, Int64(size))
            while offset < size {
                try check()
                let amount = min(AttachmentRequest.chunkSize, size - offset)
                let bytes = try await server.fetchPart(section: part.section, of: UID(uid), offset: offset, count: amount)
                guard bytes.count == amount else { throw AttachmentFailure.changed }
                if buffered { encoded.append(bytes) } else { try await sink(bytes) }
                offset += bytes.count; await progress(Int64(offset), Int64(size))
            }
            // Detect incorrect BODYSTRUCTURE lengths, including a falsely empty part.
            guard try await server.fetchPart(section: part.section, of: UID(uid), offset: size, count: 1).isEmpty,
                  try await examine(mailbox).uidValidity.value == validity else { throw AttachmentFailure.changed }
            if buffered {
                if encoding == "base64" {
                    let compact = encoded.filter { ![9, 10, 13, 32].contains($0) }
                    guard Data(base64Encoded: compact) != nil else { throw AttachmentFailure.invalidData }
                }
                part.data = encoded
                guard let decoded = part.decodedData() else { throw AttachmentFailure.invalidData }
                try await AttachmentSafety.writeChunks(decoded, sink: sink)
            }
            try check()
        } catch {
            if error is AttachmentFailure { throw error }
            throw sanitized(error)
        }
    }
    public func perform(_ mutation: MailMutation, on message: MailMessage) async throws {
        try check()
        guard message.accountID == configuration.accountID,
              case .imap(let mailbox, let validity, let rawUID) = message.locator else { throw MailFailure.permissionDenied }
        var submitted = false
        do {
            if case .move(let target) = mutation {
                guard target.accountID == configuration.accountID, target.providerID != mailbox,
                      target.id == (try IMAPIdentity.folder(account: configuration.accountID, mailbox: target.providerID)) else { throw MailFailure.permissionDenied }
                let move = await server.supportsMove, uidPlus = await server.supportsUIDPlus
                guard move, uidPlus else { throw IMAPFailure.unsupportedAction }
                guard try await folders().contains(where: { $0.id == target.id }) else { throw MailFailure.notFound }
            }
            let selected = try await server.selectMailbox(mailbox)
            guard !selected.isReadOnly, selected.uidValidity.value == validity else { throw IMAPFailure.mailboxChanged }
            guard let before = try await server.fetchMessageInfo(for: UID(rawUID), options: .uidFlagsOnly), before.uid?.value == rawUID else { throw MailFailure.notFound }
            try check()
            switch mutation {
            case .read(let value), .flagged(let value):
                let flag: Flag
                if case .read = mutation { flag = .seen } else { flag = .flagged }
                // Refuse a stale snapshot, especially when restoring a previous state.
                let expected = flag == .seen ? !message.isUnread : message.isFlagged
                guard before.flags.contains(flag) == expected else { throw IMAPFailure.mailboxChanged }
                submitted = true
                try await server.store(flags: [flag], on: UIDSet([UID(rawUID)]), operation: value ? .add : .remove)
                guard let after = try await server.fetchMessageInfo(for: UID(rawUID), options: .uidFlagsOnly),
                      after.uid?.value == rawUID, after.flags.contains(flag) == value else { throw IMAPFailure.unconfirmedAction }
                guard try await examine(mailbox).uidValidity.value == validity else { throw IMAPFailure.unconfirmedAction }
            case .move(let target):
                submitted = true
                // Never fall back to COPY + Deleted + EXPUNGE; only the requested UID may move.
                guard let mapping = try await server.move(message: UID(rawUID), to: target.providerID, fallback: .disabled),
                      mapping.mapping.count == 1, let pair = mapping.mapping.first, pair.source.value == rawUID else { throw IMAPFailure.unconfirmedAction }
                let source = try await examine(mailbox)
                guard source.uidValidity.value == validity,
                      try await server.fetchMessageInfo(for: UID(rawUID), options: .uidFlagsOnly) == nil else { throw IMAPFailure.unconfirmedAction }
                let destination = try await examine(target.providerID)
                guard destination.uidValidity == mapping.destinationUIDValidity,
                      let found = try await server.fetchMessageInfo(for: pair.destination, options: .uidFlagsOnly),
                      found.uid == pair.destination else { throw IMAPFailure.unconfirmedAction }
            }
            try check()
        } catch {
            if submitted { throw IMAPFailure.unconfirmedAction }
            throw sanitized(error)
        }
    }
    private func examine(_ mailbox: String) async throws -> Mailbox.Selection {
        try check()
        let selected = try await server.examineMailbox(mailbox)
        guard selected.isReadOnly, selected.uidValidity.value > 0, selected.messageCount >= 0,
              selected.messageCount <= Int(UInt32.max) else { throw IMAPFailure.invalidResponse }
        try check()
        return selected
    }
    private func window(_ selection: Mailbox.Selection) async throws -> [IMAPFlags] {
        try check()
        guard let latest = selection.latest(IMAPFolderBatch.windowLimit) else { return [] }
        let rows = try await server.fetchMessageInfosBulk(using: latest, options: .uidFlagsOnly)
        guard rows.count == min(selection.messageCount, IMAPFolderBatch.windowLimit) else { throw IMAPFailure.mailboxChanged }
        let flags = try rows.map { info -> IMAPFlags in
            guard let uid = info.uid?.value, uid > 0 else { throw IMAPFailure.invalidResponse }
            return IMAPFlags(uid: uid, unread: !info.flags.contains(.seen), flagged: info.flags.contains(.flagged))
        }
        guard Set(flags.map(\.uid)).count == flags.count else { throw IMAPFailure.invalidResponse }
        return flags
    }
    private func check() throws {
        try Task.checkCancellation()
        if disconnected { throw CancellationError() }
    }
    private func sanitized(_ error: any Error) -> any Error {
        if Task.isCancelled || disconnected || error is CancellationError { return CancellationError() }
        if error is IMAPFailure || error is MailFailure { return error }
        if let imap = error as? IMAPError {
            switch imap {
            case .loginFailed, .authFailed, .unsupportedAuthMechanism: return IMAPFailure.authentication
            case .timeout: return IMAPFailure.timeout
            case .connectionFailed, .greetingFailed: return IMAPFailure.connection
            default: return IMAPFailure.invalidResponse
            }
        }
        return IMAPFailure.connection
    }
    private static func message(_ info: MessageInfo, account: AccountID, folder: MailFolder, validity: UInt32) throws -> MailMessage {
        guard let uid = info.uid?.value, uid > 0, info.parts.count <= 1000,
              let receivedAt = info.internalDate else { throw IMAPFailure.invalidResponse }
        let id = try IMAPIdentity.message(account: account, mailbox: folder.providerID, validity: validity, uid: uid)
        let from = info.fromAddresses.mailboxes.first.flatMap(person)
        let fallback = try MailPerson(name: "Absender fehlt oder ist ungültig", address: MailDomain.EmailAddress("unknown@invalid"))
        let people = (info.toAddresses + info.ccAddresses).mailboxes
        guard people.count <= 1000 else { throw IMAPFailure.invalidResponse }
        let attachments = try info.parts.filter {
            $0.filename != nil || $0.disposition?.lowercased() == "attachment" ||
            (!$0.contentType.lowercased().hasPrefix("text/") && !$0.contentType.lowercased().hasPrefix("multipart/"))
        }.map { part in
            try AttachmentMetadata(id: IMAPIdentity.attachment(message: id, section: part.section.description),
                messageID: id, accountID: account, filename: display(part.suggestedFilename, limit: 1024),
                mimeType: display(part.contentType, limit: 256), byteCount: Int64(max(part.size ?? 0, 0)),
                isInline: part.disposition?.lowercased() == "inline", providerPartID: part.section.description,
                contentID: part.contentId.map { display($0, limit: 512) })
        }
        return try MailMessage(id: id, accountID: account,
            locator: .imap(mailbox: folder.providerID, uidValidity: validity, uid: uid), threadID: nil,
            folderIDs: [folder.id], internetMessageID: info.messageId?.description,
            subject: display(info.subject ?? "(Ohne Betreff)", limit: 8192), sender: from ?? fallback,
            recipients: people.compactMap(person), receivedAt: receivedAt,
            isUnread: !info.flags.contains(.seen), isFlagged: info.flags.contains(.flagged), preview: nil, attachments: attachments,
            inReplyTo: info.inReplyTo?.description, references: Array((info.references ?? []).prefix(100)).map(\.description), threadingHeadersLoaded: true,
            ccRecipients: info.ccAddresses.mailboxes.compactMap(person), replyTo: info.replyToAddresses.mailboxes.compactMap(person))
    }
    private static func person(_ address: SwiftMail.EmailAddress) -> MailPerson? {
        guard let valid = try? MailDomain.EmailAddress(address.address) else { return nil }
        return MailPerson(name: display(address.name ?? "", limit: 512), address: valid)
    }
    private static func display(_ text: String, limit: Int) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(limit).map(String.init).joined())
    }
}
