import Foundation
import Testing
@preconcurrency import AppAuth
import MailDomain
import MailApplication
@testable import MailGoogle

private actor MemoryCredentials: CredentialStore {
    var values: [CredentialReference: Data] = [:]
    func read(_ reference: CredentialReference) -> Data? { values[reference] }
    func save(_ secret: Data, for reference: CredentialReference) { values[reference] = secret }
    func delete(_ reference: CredentialReference) { values[reference] = nil }
}
private final class TokenURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var count = 0
    nonisolated(unsafe) static var invalidGrant = false
    static func reset(invalid: Bool = false) { lock.withLock { count = 0; invalidGrant = invalid } }
    static var requests: Int { lock.withLock { count } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let invalid = Self.lock.withLock { Self.count += 1; return Self.invalidGrant }
        guard request.url?.absoluteString == "https://oauth2.googleapis.com/token" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: invalid ? 400 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        let data = invalid ? #"{"error":"invalid_grant"}"# : #"{"access_token":"synthetic-new-access","refresh_token":"synthetic-rotated-refresh","token_type":"Bearer","expires_in":3600,"scope":"https://www.googleapis.com/auth/gmail.readonly"}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(data.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private struct OfflineRevocation: ProviderTransport {
    func data(for request: URLRequest, maximumBytes: Int) throws -> (Data, HTTPURLResponse) { throw MailFailure.offline }
}
private final class SyntheticUserAgent: NSObject, OIDExternalUserAgent {
    func present(_ request: any OIDExternalUserAgentRequest, session: any OIDExternalUserAgentSession) -> Bool { true }
    func dismiss(animated: Bool, completion: @escaping @Sendable () -> Void) { completion() }
}

@Suite(.serialized) @MainActor
struct GoogleAuthenticationTests {
    @Test func sdkRefreshIsCoalescedAndRotatedStateSurvivesANewOwner() async throws {
        let session = fakeSession(); defer { OIDURLSessionProvider.setSession(URLSession.shared); session.invalidateAndCancel() }
        TokenURLProtocol.reset()
        let config = try configuration(), credentials = MemoryCredentials()
        let state = try state(config)
        try await save(state, config: config, store: credentials)
        let owner = GoogleAuthentication(credentials: credentials)
        async let first = owner.accessToken(for: config, forceRefresh: false)
        async let second = owner.accessToken(for: config, forceRefresh: false)
        let values = try await [first, second]
        #expect(values == ["synthetic-new-access", "synthetic-new-access"])
        #expect(TokenURLProtocol.requests == 1)
        let saved = try #require(await credentials.read(CredentialReference(accountID: config.accountID, purpose: .oauthRefreshToken)))
        let restored = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: saved))
        #expect(restored.refreshToken == "synthetic-rotated-refresh")
        let newOwner = GoogleAuthentication(credentials: credentials)
        #expect(try await newOwner.accessToken(for: config, forceRefresh: false) == "synthetic-new-access")
        #expect(TokenURLProtocol.requests == 1)
    }
    @Test func wrongAccountAndScopeCannotReuseAnotherAccountsGrant() async throws {
        let session = fakeSession(); defer { OIDURLSessionProvider.setSession(URLSession.shared); session.invalidateAndCancel() }
        TokenURLProtocol.reset()
        let config = try configuration(), credentials = MemoryCredentials()
        try await save(state(config), config: config, store: credentials)
        let owner = GoogleAuthentication(credentials: credentials)
        let other = try configuration()
        #expect(!owner.resumeBrowserAuthorization(URL(string: "com.googleusercontent.apps.1234567890-synthetic:/oauthredirect?code=synthetic&state=unsolicited")!))
        await #expect(throws: MailFailure.authenticationExpired) { try await owner.accessToken(for: other, forceRefresh: false) }
        let broad = try GmailConfiguration(accountID: config.accountID, clientID: config.clientID, permission: .manageMail)
        await #expect(throws: MailFailure.authenticationExpired) { try await owner.accessToken(for: broad, forceRefresh: false) }
        #expect(TokenURLProtocol.requests == 0)
    }
    @Test func invalidGrantPausesAccessAndOfflineRevocationStillDeletesLocalCredentials() async throws {
        let session = fakeSession(); defer { OIDURLSessionProvider.setSession(URLSession.shared); session.invalidateAndCancel() }
        TokenURLProtocol.reset(invalid: true)
        let config = try configuration(), credentials = MemoryCredentials()
        try await save(state(config), config: config, store: credentials)
        let owner = GoogleAuthentication(credentials: credentials, revokeTransport: OfflineRevocation())
        await #expect(throws: MailFailure.authenticationExpired) { try await owner.accessToken(for: config, forceRefresh: false) }
        #expect(try await owner.disconnect(config, revoke: true) == false)
        #expect(await credentials.read(CredentialReference(accountID: config.accountID, purpose: .oauthRefreshToken)) == nil)
        await #expect(throws: MailFailure.authenticationExpired) { try await owner.accessToken(for: config, forceRefresh: false) }
    }
    @Test func sdkGeneratesUniqueStateAndS256PKCEWithoutClientSecret() throws {
        let first = request(try configuration()), second = request(try configuration())
        #expect(first.state != second.state && first.state?.isEmpty == false)
        #expect(first.codeChallengeMethod == "S256" && first.codeVerifier?.isEmpty == false)
        #expect(first.codeVerifier != first.codeChallenge && first.clientSecret == nil)
    }
    @Test func sdkRejectsWrongStateAndCancellationWithoutTokenExchange() async throws {
        let session = fakeSession(); defer { OIDURLSessionProvider.setSession(URLSession.shared); session.invalidateAndCancel() }
        TokenURLProtocol.reset()
        let authRequest = request(try configuration())
        let rejected: Bool = await withCheckedContinuation { continuation in
            let flow = OIDAuthorizationService.present(authRequest, externalUserAgent: SyntheticUserAgent()) { response, error in
                continuation.resume(returning: response == nil && error != nil)
            }
            #expect(throws: NSError.self) { try flow.resumeExternalUserAgentFlow(URL(string: "com.googleusercontent.apps.1234567890-synthetic:/other?code=synthetic&state=incorrect")!) }
            _ = try? flow.resumeExternalUserAgentFlow(URL(string: "com.googleusercontent.apps.1234567890-synthetic:/oauthredirect?code=synthetic&state=incorrect")!)
        }
        #expect(rejected)
        let cancelled: Bool = await withCheckedContinuation { continuation in
            let flow = OIDAuthorizationService.present(authRequest, externalUserAgent: SyntheticUserAgent()) { _, error in
                continuation.resume(returning: GoogleAuthentication.safeAuthorizationFailure(error) == .cancelled)
            }
            flow.cancel()
        }
        #expect(cancelled && TokenURLProtocol.requests == 0)
    }
    private func fakeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TokenURLProtocol.self]
        let session = URLSession(configuration: config); OIDURLSessionProvider.setSession(session); return session
    }
    private func configuration() throws -> GmailConfiguration { try GmailConfiguration(accountID: AccountID(), clientID: "1234567890-synthetic.apps.googleusercontent.com", permission: .readOnly) }
    private func request(_ config: GmailConfiguration) -> OIDAuthorizationRequest {
        OIDAuthorizationRequest(configuration: OIDServiceConfiguration(authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!, tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!),
            clientId: config.clientID, scopes: [config.permission.scope], redirectURL: URL(string: "com.googleusercontent.apps.1234567890-synthetic:/oauthredirect")!, responseType: OIDResponseTypeCode, additionalParameters: nil)
    }
    private func state(_ config: GmailConfiguration) throws -> OIDAuthState {
        let request = request(config)
        let response = OIDAuthorizationResponse(request: request, parameters: ["code": "synthetic-code" as NSString, "state": request.state! as NSString])
        let tokenRequest = try #require(response.tokenExchangeRequest())
        let token = OIDTokenResponse(request: tokenRequest, parameters: ["access_token": "synthetic-old-access" as NSString, "refresh_token": "synthetic-old-refresh" as NSString, "token_type": "Bearer" as NSString, "expires_in": NSNumber(value: -60), "scope": config.permission.scope as NSString])
        let state = OIDAuthState(authorizationResponse: response, tokenResponse: token); state.setNeedsTokenRefresh(); return state
    }
    private func save(_ state: OIDAuthState, config: GmailConfiguration, store: MemoryCredentials) async throws {
        try await store.save(NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true), for: CredentialReference(accountID: config.accountID, purpose: .oauthRefreshToken))
    }
}
