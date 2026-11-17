import Foundation
import MailDomain
import MailApplication
import MailRendering

public struct GmailClient: GmailAPI, GmailPagedReadAPI, GmailHistoryProgressAPI, GmailSyncReportingAPI, AttachmentSource {
    public let accountID: AccountID
    private let configuration: GmailConfiguration
    private let tokens: any GoogleTokenSource
    private let transport: any ProviderTransport
    private var syncProgress: (@Sendable (GmailSyncProgress) async -> Void)?
    public init(configuration: GmailConfiguration, tokens: any GoogleTokenSource, transport: any ProviderTransport = GmailTransport()) {
        self.configuration = configuration; accountID = configuration.accountID; self.tokens = tokens; self.transport = transport
    }
    public func reportingSyncProgress(_ progress: @escaping @Sendable (GmailSyncProgress) async -> Void) -> any GmailAPI {
        var copy = self; copy.syncProgress = progress; return copy
    }
    public func profile() async throws -> GmailProfile {
        let wire: Profile = try await request("profile", query: ["fields": "emailAddress,historyId,messagesTotal"])
        guard !wire.emailAddress.isEmpty, Self.validHistory(wire.historyId), wire.messagesTotal.map({ $0 >= 0 }) ?? true else { throw GmailFailure.invalidResponse }
        return GmailProfile(email: wire.emailAddress, historyID: wire.historyId, messageCount: wire.messagesTotal)
    }
    public func folders() async throws -> [MailFolder] {
        let result: Labels = try await request("labels", query: ["fields": "labels(id,name,type)"])
        guard result.labels.count < 500, Set(result.labels.map(\.id)).count == result.labels.count else { throw GmailFailure.tooLarge }
        var folders = try result.labels.map { label -> MailFolder in
            guard GmailIdentity.validID(label.id), label.name.utf8.count <= 2048 else { throw GmailFailure.invalidResponse }
            let role: FolderRole = switch label.id { case "INBOX": .inbox; case "SENT": .sent; case "DRAFT": .drafts; case "TRASH": .trash; default: .custom }
            let name = ["INBOX": "Posteingang", "SENT": "Gesendet", "DRAFT": "Entwürfe bei Gmail", "TRASH": "Papierkorb", "SPAM": "Spam", "STARRED": "Markiert", "UNREAD": "Ungelesen", "IMPORTANT": "Wichtig", "CHAT": "Chats", "CATEGORY_PERSONAL": "Allgemein", "CATEGORY_PROMOTIONS": "Werbung", "CATEGORY_SOCIAL": "Soziale Netzwerke", "CATEGORY_UPDATES": "Benachrichtigungen", "CATEGORY_FORUMS": "Foren"][label.id] ?? label.name
            return try MailFolder(id: GmailIdentity.folder(account: accountID, label: label.id), accountID: accountID, providerID: label.id, name: name, role: role)
        }
        folders.append(try MailFolder(id: GmailIdentity.folder(account: accountID, label: GmailIdentity.archive), accountID: accountID,
                                      providerID: GmailIdentity.archive, name: "Archiv", role: .archive))
        return folders
    }
    public func allMessageIDs(cursor: String?) async throws -> GmailMessagePage {
        guard cursor.map({ !$0.isEmpty && $0.utf8.count <= 2048 }) ?? true else { throw MailFailure.invalidInput }
        var parameters = ["maxResults": "100", "includeSpamTrash": "true", "fields": "messages(id),nextPageToken"]
        parameters["pageToken"] = cursor
        let page: Messages
        do { page = try await request("messages", query: parameters) }
        catch MailFailure.invalidInput where cursor != nil { throw SearchFailure.invalidCursor }
        let ids = (page.messages ?? []).map(\.id)
        guard ids.count <= 100, Set(ids).count == ids.count, ids.allSatisfy(GmailIdentity.validID),
              page.nextPageToken.map({ !$0.isEmpty && $0.utf8.count <= 2048 && $0 != cursor }) ?? true else { throw GmailFailure.invalidResponse }
        return GmailMessagePage(ids: ids, nextCursor: page.nextPageToken)
    }
    public func messageIDs(label: String, limit: Int, query: String? = nil) async throws -> [String] {
        guard (1...200).contains(limit), GmailIdentity.validID(label), (query?.utf8.count ?? 0) <= 2048 else { throw MailFailure.invalidInput }
        var ids: [String] = [], next: String?, seen: Set<String> = []
        for _ in 0..<10 {
            var parameters = ["maxResults": String(limit - ids.count), "includeSpamTrash": "true", "fields": "messages(id),nextPageToken"]
            if label == GmailIdentity.archive { parameters["q"] = "-in:inbox -in:trash -in:spam -in:drafts" }
            else { parameters["labelIds"] = label }
            if let query { parameters["q"] = [parameters["q"], query].compactMap { $0 }.joined(separator: " ") }
            parameters["pageToken"] = next
            let page: Messages = try await request("messages", query: parameters)
            for message in page.messages ?? [] {
                guard GmailIdentity.validID(message.id), seen.insert(message.id).inserted else { throw GmailFailure.invalidResponse }
                ids.append(message.id)
            }
            guard ids.count <= limit else { throw GmailFailure.invalidResponse }
            guard ids.count < limit, let cursor = page.nextPageToken else { return ids }
            guard cursor.utf8.count <= 2048, cursor != next else { throw GmailFailure.invalidResponse }
            next = cursor
        }
        throw GmailFailure.tooLarge
    }
    public func history(since: String) async throws -> GmailHistory {
        try await history(since: since, existingLabelIDs: nil, progress: { _, _ in })
    }
    public func history(since: String, existingLabelIDs: Set<String>?,
                        progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> GmailHistory {
        guard Self.validHistory(since) else { throw MailFailure.invalidInput }
        var next: String?, changed: Set<String> = [], seen: Set<String> = []
        for pageNumber in 1...1000 {
            try Task.checkCancellation()
            var query = ["startHistoryId": since, "maxResults": "500", "fields": "historyId,nextPageToken,history(messages(id),messagesAdded(message(id)),messagesDeleted(message(id)),labelsAdded(message(id),labelIds),labelsRemoved(message(id),labelIds))"]
            query["pageToken"] = next
            let page: History
            do { page = try await request("history", query: query, maximumBytes: 2 * 1024 * 1024) }
            catch MailFailure.notFound { throw GmailFailure.historyExpired }
            guard Self.validHistory(page.historyId), (page.history?.count ?? 0) <= 500 else { throw GmailFailure.invalidResponse }
            for event in page.history ?? [] {
                var typed: Set<String> = []
                for entries in [event.messagesAdded, event.messagesDeleted, event.labelsAdded, event.labelsRemoved] {
                    typed.formUnion((entries ?? []).map { $0.message.id })
                }
                guard typed.allSatisfy(GmailIdentity.validID), (event.messages ?? []).allSatisfy({ GmailIdentity.validID($0.id) }) else { throw GmailFailure.invalidResponse }
                // Gmail also repeats typed changes in `messages`; do not let that
                // duplicate list turn a deleted-label cleanup into thousands of GETs.
                changed.formUnion(Set((event.messages ?? []).map(\.id)).subtracting(typed))
                for entries in [event.messagesAdded, event.messagesDeleted, event.labelsAdded] {
                    changed.formUnion((entries ?? []).map { $0.message.id })
                }
                for removal in event.labelsRemoved ?? [] {
                    if let existingLabelIDs, let labels = removal.labelIds, !labels.isEmpty,
                       labels.allSatisfy(GmailIdentity.validID), Set(labels).isDisjoint(with: existingLabelIDs) { continue }
                    changed.insert(removal.message.id)
                }
            }
            guard changed.count <= 100_000, changed.allSatisfy(GmailIdentity.validID) else { throw GmailFailure.historyLimit }
            await progress(pageNumber, changed.count)
            guard let cursor = page.nextPageToken else { return GmailHistory(changedIDs: changed, historyID: page.historyId) }
            guard cursor.utf8.count <= 2048, seen.insert(cursor).inserted else { throw GmailFailure.invalidResponse }
            next = cursor
        }
        throw GmailFailure.historyLimit
    }
    public func metadata(id: String, folders: [MailFolder]) async throws -> (MailMessage, String) {
        try Self.validate(id)
        // Gmail parses MIME; partial fields explicitly exclude every body.data value.
        let wire: GmailMessage = try await request("messages/" + id, query: ["format": "full", "fields": Self.metadataFields], maximumBytes: 512 * 1024)
        guard wire.id == id else { throw GmailFailure.invalidResponse }
        return try GmailMapping.message(wire, account: accountID, folders: folders)
    }
    public func body(id: String, preferHTML: Bool, maximumBytes: Int) async throws -> MailBody {
        try Self.validate(id)
        guard maximumBytes > 0, maximumBytes <= 2 * 1024 * 1024 else { throw MailFailure.invalidInput }
        let wire: GmailMessage = try await request("messages/" + id, query: ["format": "full", "fields": "id,threadId,labelIds,internalDate,payload"], maximumBytes: 4 * maximumBytes)
        guard wire.id == id else { throw GmailFailure.invalidResponse }
        let part = try GmailMapping.bodyPart(wire.payload, preferHTML: preferHTML)
        let encoded: String
        if let data = part.body?.data { encoded = data }
        else if let attachment = part.body?.attachmentId {
            guard !attachment.isEmpty, attachment.utf8.count <= 2048,
                  attachment.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw GmailFailure.invalidResponse }
            let result: GmailPart.Body = try await request("messages/\(id)/attachments/\(attachment)", maximumBytes: maximumBytes * 2)
            guard let data = result.data else { throw GmailFailure.noBody }; encoded = data
        } else { throw GmailFailure.noBody }
        let body = try GmailMapping.body(encoded, mime: part.mimeType, headers: part.headers ?? [], maximumBytes: maximumBytes)
        guard preferHTML, body.format == .html else { return body }
        let references = try MailHTMLSanitizer.inlineContentIDs(in: body.text)
        let parts = try GmailMapping.inlineImageParts(wire.payload)
        var images: [String: InlineMailImage] = [:], total = 0
        for reference in references.sorted() {
            let matches = parts.filter { candidate in
                InlineMailImage.contentID(candidate.headers?.first { $0.name.lowercased() == "content-id" }?.value ?? "") == reference
            }
            guard matches.count == 1, let imagePart = matches.first, let size = imagePart.body?.size,
                  size > 0, size <= InlineMailImage.maximumBytes, total + size <= InlineMailImage.maximumTotalBytes else { continue }
            do {
                try Task.checkCancellation()
                let encodedImage: String?
                if let data = imagePart.body?.data { encodedImage = data }
                else if let attachment = imagePart.body?.attachmentId, Self.validAttachmentID(attachment) {
                    let result: GmailPart.Body = try await request("messages/\(id)/attachments/\(attachment)", maximumBytes: size * 2 + 8192)
                    encodedImage = result.data
                } else { encodedImage = nil }
                if let encodedImage, let image = InlineMailImage(data: try GmailMapping.decodedData(encodedImage, maximumBytes: size)) {
                    images[reference] = image; total += image.data.count
                }
            } catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation() }
        }
        return MailBody(text: body.text, format: body.format, inlineImages: images)
    }
    private static func validAttachmentID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 2048 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    public func download(_ request: AttachmentRequest, sink: @escaping AttachmentSink,
                         progress: @escaping AttachmentProgress) async throws {
        guard request.accountID == accountID, case .gmail(let id) = request.locator,
              request.messageID == (try GmailIdentity.message(account: accountID, id: id)),
              let partID = request.attachment.providerPartID,
              request.attachment.id == (try IMAPIdentity.attachment(message: request.messageID, section: "gmail:" + partID))
        else { throw MailFailure.permissionDenied }
        try Self.validate(id)
        let metadata: GmailMessage = try await self.request("messages/" + id,
            query: ["format": "full", "fields": Self.metadataFields], maximumBytes: 512 * 1024)
        guard metadata.id == id else { throw AttachmentFailure.changed }
        let matches = try GmailMapping.flatten(metadata.payload).filter { $0.partId == partID }
        guard matches.count == 1, let part = matches.first, let size = part.body?.size, size >= 0,
              Int64(size) == request.attachment.byteCount, part.mimeType == request.attachment.mimeType
        else { throw AttachmentFailure.changed }
        guard size <= AttachmentRequest.byteLimit else { throw AttachmentFailure.tooLarge }
        let body: GmailPart.Body
        if let remote = part.body?.attachmentId {
            guard !remote.isEmpty, remote.utf8.count <= 2048,
                  remote.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 })
            else { throw AttachmentFailure.invalidData }
            body = try await self.request("messages/\(id)/attachments/\(remote)",
                maximumBytes: (size + 2) / 3 * 4 + 8192, progress: progress)
        } else {
            // Small inline parts have no separate endpoint. The complete API response is
            // still strictly bounded and transient; only this part reaches the file sink.
            let full: GmailMessage = try await self.request("messages/" + id,
                query: ["format": "full", "fields": "id,threadId,labelIds,internalDate,payload"],
                maximumBytes: 12 * 1024 * 1024, progress: progress)
            let selected = try GmailMapping.flatten(full.payload).filter { $0.partId == partID }
            guard full.id == id, selected.count == 1, selected.first?.mimeType == part.mimeType,
                  let value = selected.first?.body else { throw AttachmentFailure.changed }
            body = value
        }
        guard body.size == size, let data = body.data, data.utf8.count <= (size + 2) / 3 * 4 else { throw AttachmentFailure.changed }
        var encoded = data.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let decoded = Data(base64Encoded: encoded), decoded.count == size else { throw AttachmentFailure.invalidData }
        try await AttachmentSafety.writeChunks(decoded, sink: sink)
    }
    public func modify(id: String, adding: [String], removing: [String]) async throws {
        try Self.validate(id); try writable()
        guard (adding + removing).allSatisfy(GmailIdentity.validID), adding.count + removing.count <= 20 else { throw MailFailure.invalidInput }
        if adding.contains("TRASH") {
            let _: Identifier = try await request("messages/\(id)/trash", method: "POST")
            return
        }
        if removing.contains("TRASH") {
            let _: Identifier = try await request("messages/\(id)/untrash", method: "POST")
        }
        let _: Identifier = try await request("messages/\(id)/modify", method: "POST", payload: JSONEncoder().encode(Modify(addLabelIds: adding, removeLabelIds: removing.filter { $0 != "TRASH" })))
    }
    public func send(raw: Data, draftID: String?) async throws -> String {
        try writable(); guard raw.count <= 30_000_000 else { throw ComposeFailure.tooLarge }
        let payload: Data
        if let draftID { try Self.validate(draftID); payload = try JSONEncoder().encode(DraftWrite(id: draftID, message: Raw(raw: raw.base64URL))) }
        else { payload = try JSONEncoder().encode(Raw(raw: raw.base64URL)) }
        do {
            let result: Identifier = try await request(draftID == nil ? "messages/send" : "drafts/send", method: "POST", payload: payload)
            try Self.validate(result.id); return result.id
        } catch let error as MailFailure {
            switch error { case .permissionDenied, .authenticationExpired, .invalidInput: throw ComposeFailure.rejected; default: throw ComposeFailure.uncertain }
        } catch { throw ComposeFailure.uncertain }
    }
    public func saveDraft(raw: Data, draftID: String?) async throws -> GmailDraftReceipt {
        try writable(); guard raw.count <= 30_000_000 else { throw ComposeFailure.tooLarge }
        if let draftID { try Self.validate(draftID) }
        let result: DraftResult = try await request(draftID.map { "drafts/" + $0 } ?? "drafts", method: draftID == nil ? "POST" : "PUT",
            payload: JSONEncoder().encode(DraftWrite(id: draftID, message: Raw(raw: raw.base64URL))))
        return try result.receipt()
    }
    public func draftVersion(id: String) async throws -> GmailDraftReceipt {
        try Self.validate(id)
        let result: DraftResult = try await request("drafts/" + id, query: ["format": "minimal", "fields": "id,message(id)"])
        guard result.id == id else { throw GmailFailure.invalidResponse }; return try result.receipt()
    }
    public func findDraft(internetMessageID: String) async throws -> GmailDraftReceipt? {
        try ComposeValidation.messageID(internetMessageID)
        let queryID = internetMessageID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let result: DraftList = try await request("drafts", query: ["q": "rfc822msgid:" + queryID, "maxResults": "20", "fields": "drafts(id,message(id)),nextPageToken"])
        guard result.nextPageToken == nil, (result.drafts?.count ?? 0) <= 20 else { throw GmailFailure.tooLarge }
        var matches: [GmailDraftReceipt] = []
        for draft in result.drafts ?? [] {
            let receipt = try draft.receipt()
            let wire: MessageHeaders = try await request("messages/" + receipt.messageID, query: ["format": "metadata", "fields": "id,payload(headers)", "metadataHeaders": "Message-ID"])
            guard wire.id == receipt.messageID else { throw GmailFailure.invalidResponse }
            if wire.payload.headers?.contains(where: { $0.name.lowercased() == "message-id" && $0.value == internetMessageID }) == true { matches.append(receipt) }
        }
        guard matches.count <= 1 else { throw ComposeFailure.conflict }; return matches.first
    }
    private func writable() throws { guard configuration.permission == .manageMail else { throw GmailFailure.insufficientScope } }
    static func validate(_ id: String) throws { guard GmailIdentity.validID(id) else { throw MailFailure.invalidInput } }
    static func validHistory(_ id: String) -> Bool { !id.isEmpty && id.count <= 64 && id.utf8.allSatisfy { (48...57).contains($0) } }
    static var metadataFields: String {
        var part = "partId,mimeType,filename,headers,body(size,attachmentId)"
        for _ in 0..<12 { part = "partId,mimeType,filename,headers,body(size,attachmentId),parts(\(part))" }
        return "id,threadId,labelIds,internalDate,payload(\(part))"
    }
    private func request<T: Decodable>(_ path: String, method: String = "GET", query: [String: String] = [:], payload: Data? = nil, maximumBytes: Int = 512 * 1024, progress: AttachmentProgress? = nil) async throws -> T {
        var url = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)!
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var refreshed = false, forceNextRefresh = false
        for attempt in 0..<6 {
            try Task.checkCancellation()
            if method == "GET" { try await GmailReadPacer.shared.wait(account: accountID, progress: syncProgress) }
            let token = try await tokens.accessToken(for: configuration, forceRefresh: forceNextRefresh)
            forceNextRefresh = false
            var request = URLRequest(url: url.url!); request.httpMethod = method; request.httpBody = payload
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if payload != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let data: Data, response: HTTPURLResponse
            do {
            if let progress, let reporter = transport as? any ProgressProviderTransport {
                (data, response) = try await reporter.data(for: request, maximumBytes: maximumBytes, progress: progress)
            } else { (data, response) = try await transport.data(for: request, maximumBytes: maximumBytes) }
            } catch MailFailure.offline where method == "GET" && attempt < 2 {
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                continue
            }
            guard data.count <= maximumBytes else { throw GmailFailure.tooLarge }
            if (200...299).contains(response.statusCode) {
                do { return try JSONDecoder().decode(T.self, from: data) } catch { throw GmailFailure.invalidResponse }
            }
            let reason = (try? JSONDecoder().decode(GmailAPIError.self, from: data))?.error.errors?.first?.reason
            let throttled = response.statusCode == 429 || (response.statusCode == 403 && ["rateLimitExceeded", "userRateLimitExceeded"].contains(reason ?? ""))
            if throttled, method == "GET" { await GmailReadPacer.shared.throttle(account: accountID) }
            if response.statusCode == 401, method == "GET", !refreshed { refreshed = true; forceNextRefresh = true; continue }
            if method == "GET", attempt < 5, throttled || (500...599).contains(response.statusCode) {
                let delay = min(30, max(1, Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(attempt))))
                await syncProgress?(.waiting(Int(delay.rounded(.up))))
                try await Task.sleep(for: .seconds(delay)); continue
            }
            switch response.statusCode {
            case 400: throw MailFailure.invalidInput
            case 401: throw MailFailure.authenticationExpired
            case 403:
                if throttled { throw MailFailure.rateLimited(retryAfter: 30) }
                let known: Set<String> = ["dailyLimitExceeded", "domainPolicy", "insufficientPermissions", "accessNotConfigured", "forbidden", "notAuthorized"]
                if let reason, known.contains(reason) {
                    throw GmailFailure.accessDenied(operation: String(path.split(separator: "/").first ?? "mail"), reason: reason)
                }
                throw MailFailure.permissionDenied
            case 404: throw MailFailure.notFound
            case 429: throw MailFailure.rateLimited(retryAfter: 30)
            default: throw MailFailure.providerFailure
            }
        }
        throw MailFailure.authenticationExpired
    }
}
private struct Profile: Decodable { let emailAddress: String; let historyId: String; let messagesTotal: Int? }
private struct Label: Decodable { let id: String; let name: String }
private struct Labels: Decodable { let labels: [Label] }
private struct Identifier: Decodable { let id: String }
private struct Messages: Decodable { let messages: [Identifier]?; let nextPageToken: String? }
private struct History: Decodable {
    struct Change: Decodable { let message: Identifier; let labelIds: [String]? }
    struct Event: Decodable { let messages: [Identifier]?; let messagesAdded, messagesDeleted, labelsAdded, labelsRemoved: [Change]? }
    let historyId: String; let nextPageToken: String?; let history: [Event]?
}
private struct Modify: Encodable { let addLabelIds, removeLabelIds: [String] }
private struct Raw: Encodable { let raw: String }
private struct DraftWrite: Encodable { let id: String?; let message: Raw }
private struct DraftResult: Decodable {
    let id: String; let message: Identifier
    func receipt() throws -> GmailDraftReceipt {
        try GmailClient.validate(id); try GmailClient.validate(message.id); return GmailDraftReceipt(id: id, messageID: message.id)
    }
}
private struct DraftList: Decodable { let drafts: [DraftResult]?; let nextPageToken: String? }
private struct MessageHeaders: Decodable {
    struct Payload: Decodable {
        struct Header: Decodable { let name: String; let value: String }
        let headers: [Header]?
    }
    let id: String; let payload: Payload
}
extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

private struct GmailAPIError: Decodable {
    struct Detail: Decodable {
        struct Entry: Decodable { let reason: String? }
        let errors: [Entry]?
    }
    let error: Detail
}

/// Bound the initial import rate per account and slow down after provider throttling.
/// No headers, tokens, addresses or mail identifiers are retained here.
private actor GmailReadPacer {
    static let shared = GmailReadPacer()
    private struct State {
        var next = Date.distantPast
        var interval: TimeInterval = 0.2
        var lastThrottle = Date.distantPast
    }
    private var accounts: [AccountID: State] = [:]
    func wait(account: AccountID, progress: (@Sendable (GmailSyncProgress) async -> Void)?) async throws {
        let now = Date()
        var state = accounts[account] ?? State()
        let start = max(now, state.next)
        state.next = start.addingTimeInterval(state.interval)
        accounts[account] = state
        let delay = start.timeIntervalSince(now)
        if delay >= 10 { await progress?(.waiting(Int(delay.rounded(.up)))) }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        try Task.checkCancellation()
    }
    func throttle(account: AccountID) {
        let now = Date()
        var state = accounts[account] ?? State()
        if now.timeIntervalSince(state.lastThrottle) > 15 {
            state.interval = min(2, state.interval * 2)
            state.next = max(state.next, now.addingTimeInterval(30))
            state.lastThrottle = now
        }
        accounts[account] = state
    }
}
