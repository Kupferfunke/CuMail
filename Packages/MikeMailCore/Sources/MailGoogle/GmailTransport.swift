import Foundation
import MailApplication

/// A reusable ephemeral connection pool; no cookies, cached responses or stored HTTP credentials.
public struct GmailTransport: ProgressProviderTransport {
    private let pool = GmailSessionPool()
    public init() {}
    public func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        try await data(for: request, maximumBytes: maximumBytes, progress: { _, _ in })
    }
    public func data(for request: URLRequest, maximumBytes: Int, progress: @escaping AttachmentProgress) async throws -> (Data, HTTPURLResponse) {
        guard maximumBytes > 0, maximumBytes <= 12 * 1024 * 1024,
              request.url?.scheme == "https", ["gmail.googleapis.com", "oauth2.googleapis.com"].contains(request.url?.host ?? "")
        else { throw MailFailure.invalidInput }
        do {
            let (bytes, response) = try await pool.session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw GmailFailure.invalidResponse }
            guard http.expectedContentLength <= maximumBytes else { throw GmailFailure.tooLarge }
            let expected: Int64? = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
            await progress(0, expected)
            var body = Data(); body.reserveCapacity(min(maximumBytes, 65536))
            for try await byte in bytes {
                guard body.count < maximumBytes else { throw GmailFailure.tooLarge }
                body.append(byte)
                if body.count % AttachmentRequest.chunkSize == 0 {
                    try Task.checkCancellation(); await progress(Int64(body.count), expected)
                }
            }
            try Task.checkCancellation()
            await progress(Int64(body.count), expected)
            return (body, http)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw GmailFailure.timeout }
            throw MailFailure.offline
        }
    }
}
private final class GmailSessionPool: Sendable {
    let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 90
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
}
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public protocol GoogleTokenSource: Sendable {
    func accessToken(for configuration: GmailConfiguration, forceRefresh: Bool) async throws -> String
}
