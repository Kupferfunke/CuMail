import Foundation
import MailDomain

public enum AttachmentFailure: Error, Equatable, Sendable {
    case tooLarge, changed, invalidData, unsupportedEncoding, previewUnavailable, busy
}
public typealias AttachmentSink = @Sendable (Data) async throws -> Void
public typealias AttachmentProgress = @Sendable (_ received: Int64, _ expected: Int64?) async -> Void

/// Constructed only from a specific, visible attachment in the authorised message.
/// The bridge's metadata-only service receives no download capability.
public struct AttachmentRequest: Sendable {
    public static let byteLimit = 8 * 1024 * 1024
    public static let chunkSize = 64 * 1024
    public let messageID: MessageID
    public let accountID: AccountID
    public let locator: ProviderLocator
    public let attachment: AttachmentMetadata
    public init(message: MailMessage, attachment: AttachmentMetadata, scope: AccessScope) throws {
        guard scope.permits(message), message.attachments.contains(attachment),
              attachment.messageID == message.id, attachment.accountID == message.accountID
        else { throw MailFailure.permissionDenied }
        guard attachment.byteCount <= Self.byteLimit else { throw AttachmentFailure.tooLarge }
        messageID = message.id; accountID = message.accountID; locator = message.locator; self.attachment = attachment
    }
}

public protocol AttachmentSource: Sendable {
    func download(_ request: AttachmentRequest, sink: @escaping AttachmentSink,
                  progress: @escaping AttachmentProgress) async throws
}

public enum AttachmentSafety {
    /// Used only as a save-panel suggestion, never as an internal path.
    public static func filename(_ original: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(.init(charactersIn: "/\\:<>|\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"))
        var result = String(String.UnicodeScalarView(original.unicodeScalars.map { forbidden.contains($0) ? "_" : $0 }))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        result = String(result.prefix(120))
        while result.utf8.count > 180 { result.removeLast() }
        return result.isEmpty ? "Anhang" : result
    }
    /// Narrow Quick Look allowlist. Original extensions cannot select a renderer.
    public static func previewExtension(mimeType: String, prefix: Data) -> String? {
        switch mimeType.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) {
        case "application/pdf" where prefix.starts(with: Data("%PDF-".utf8)): return "pdf"
        case "image/png" where prefix.starts(with: Data([137,80,78,71,13,10,26,10])): return "png"
        case "image/jpeg" where prefix.starts(with: Data([255,216,255])): return "jpg"
        case "text/plain" where !prefix.contains(0): return "txt"
        default: return nil
        }
    }
    public static func writeChunks(_ bytes: Data, sink: @escaping AttachmentSink) async throws {
        guard bytes.count <= AttachmentRequest.byteLimit else { throw AttachmentFailure.tooLarge }
        for offset in stride(from: 0, to: bytes.count, by: AttachmentRequest.chunkSize) {
            try Task.checkCancellation()
            try await sink(bytes.subdata(in: offset..<min(bytes.count, offset + AttachmentRequest.chunkSize)))
        }
        try Task.checkCancellation()
    }
}

public protocol ProgressProviderTransport: ProviderTransport {
    func data(for request: URLRequest, maximumBytes: Int, progress: @escaping AttachmentProgress) async throws -> (Data, HTTPURLResponse)
}
