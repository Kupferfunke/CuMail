import AppKit
import Foundation
@preconcurrency import AppAuth
import MailDomain
import MailApplication

/// AppAuth owns PKCE, state verification, code exchange and token refresh.
/// This owner confines SDK state to the main actor and persists only in the app's Keychain service.
@MainActor public final class GoogleAuthentication: GoogleTokenSource {
    public static var defaultClientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "CuMailGoogleClientID") as? String) ?? ""
    }
    private let credentials: any CredentialStore
    private let revokeTransport: any ProviderTransport
    private var states: [AccountID: OIDAuthState] = [:]
    private var refreshes: [AccountID: Task<String, Error>] = [:]
    private var refreshConfigurations: [AccountID: GmailConfiguration] = [:]
    private var epochs: [AccountID: Int] = [:]
    private var authorizationFlow: (any OIDExternalUserAgentSession)?
    private var browserRedirect: URL?
    private var flowID: UUID?
    private var authorizationTimedOut = false
    private var interactive = false
    public init(credentials: any CredentialStore, revokeTransport: any ProviderTransport = GmailTransport()) {
        self.credentials = credentials; self.revokeTransport = revokeTransport
    }

    public func authorize(configuration: GmailConfiguration, expectedEmail: String?, useDefaultBrowser: Bool = true) async throws -> GmailProfile {
        guard !interactive, refreshes[configuration.accountID] == nil else { throw GmailFailure.busy }
        let userAgent: any OIDExternalUserAgent
        if useDefaultBrowser {
            // Opening the system browser does not require an active app window.
            // Accessibility actions can arrive while neither key nor main is set.
            userAgent = OIDExternalUserAgentMac()
        } else {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { throw GmailFailure.cancelled }
            userAgent = OIDExternalUserAgentMac(presenting: window.sheetParent ?? window)
        }
        interactive = true
        authorizationTimedOut = false
        let identifier = UUID(); flowID = identifier
        defer { authorizationFlow?.cancel(); authorizationFlow = nil; browserRedirect = nil; flowID = nil; interactive = false }
        let state = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OIDAuthState, Error>) in
                let scheme = configuration.clientID.split(separator: ".").reversed().joined(separator: ".")
                guard let url = URL(string: scheme + ":/oauthredirect") else { continuation.resume(throwing: GmailFailure.invalidClient); return }
                browserRedirect = useDefaultBrowser ? url : nil
                let request = OIDAuthorizationRequest(configuration: Self.endpoints, clientId: configuration.clientID,
                    scopes: [configuration.permission.scope], redirectURL: url, responseType: OIDResponseTypeCode,
                    additionalParameters: ["access_type": "offline", "prompt": "consent", "login_hint": expectedEmail ?? ""])
                authorizationFlow = OIDAuthState.authState(byPresenting: request, externalUserAgent: userAgent) { state, error in
                    if let state, state.isAuthorized { continuation.resume(returning: state) }
                    else { continuation.resume(throwing: self.authorizationTimedOut ? GmailFailure.timeout : Self.safeAuthorizationFailure(error)) }
                }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(300))
                    if self?.flowID == identifier { self?.authorizationTimedOut = true; self?.cancel() }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
        try Task.checkCancellation()
        try validate(state, configuration: configuration)
        guard let token = state.lastTokenResponse?.accessToken, state.refreshToken != nil else { throw MailFailure.authenticationExpired }
        // Verify identity before replacing an existing account's saved grant.
        let probe = GmailClient(configuration: configuration, tokens: SingleToken(value: token))
        let profile = try await probe.profile()
        if let expectedEmail, profile.email.caseInsensitiveCompare(expectedEmail) != .orderedSame { throw ComposeFailure.accountMismatch }
        try Task.checkCancellation()
        try await persist(state, account: configuration.accountID)
        epochs[configuration.accountID, default: 0] += 1
        states[configuration.accountID] = state
        return profile
    }
    public func cancel() { authorizationFlow?.cancel() }
    /// Only an active browser flow may consume this exact redirect. AppAuth verifies state and PKCE.
    @discardableResult public func resumeBrowserAuthorization(_ url: URL) -> Bool {
        guard interactive, let expected = browserRedirect, let authorizationFlow,
              url.absoluteString.utf8.count <= 8192,
              url.scheme == expected.scheme, url.host == expected.host, url.path == expected.path,
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil else { return false }
        do { try authorizationFlow.resumeExternalUserAgentFlow(url); return true }
        catch { return false }
    }
    public static func configureNetworkSession() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
        OIDURLSessionProvider.setSession(URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil))
    }
    nonisolated static func safeAuthorizationFailure(_ error: Error?) -> GmailFailure {
        let error = error as NSError?
        if error?.domain == OIDGeneralErrorDomain, [-3, -4].contains(error?.code ?? 0) { return .cancelled }
        let response = error?.userInfo[OIDOAuthErrorResponseErrorKey] as? [String: Any]
        if let description = response?[OIDOAuthErrorFieldErrorDescription] as? String,
           description.lowercased().contains("client_secret") { return .clientSecretRequired }
        if let code = response?[OIDOAuthErrorFieldError] as? String,
           ["invalid_client", "unauthorized_client", "invalid_request"].contains(code) { return .invalidClient }
        return .authenticationFailed
    }

    public func accessToken(for configuration: GmailConfiguration, forceRefresh: Bool = false) async throws -> String {
        let account = configuration.accountID
        if let running = refreshes[account] {
            guard refreshConfigurations[account] == configuration else { throw MailFailure.authenticationExpired }
            return try await running.value
        }
        let epoch = epochs[account, default: 0]
        let task = Task { @MainActor [self] () throws -> String in
            let state: OIDAuthState
            if let cached = states[account] { state = cached }
            else {
                guard let data = try await credentials.read(CredentialReference(accountID: account, purpose: .oauthRefreshToken)), data.count <= 65536,
                      let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
                else { throw MailFailure.authenticationExpired }
                state = decoded
            }
            guard epochs[account, default: 0] == epoch else { throw CancellationError() }
            try validate(state, configuration: configuration)
            if forceRefresh { state.setNeedsTokenRefresh() }
            let token: String = try await withCheckedThrowingContinuation { continuation in
                state.performAction { accessToken, _, _ in
                    if let accessToken { continuation.resume(returning: accessToken) }
                    else { continuation.resume(throwing: MailFailure.authenticationExpired) }
                }
            }
            try Task.checkCancellation()
            guard epochs[account, default: 0] == epoch else { throw CancellationError() }
            try await persist(state, account: account)
            states[account] = state
            return token
        }
        refreshes[account] = task
        refreshConfigurations[account] = configuration
        defer { refreshes[account] = nil; refreshConfigurations[account] = nil }
        return try await task.value
    }
    /// Always removes local access, even when Google's revoke endpoint is offline.
    /// The returned flag distinguishes remote revocation from local sign-out.
    public func disconnect(_ configuration: GmailConfiguration, revoke: Bool) async throws -> Bool {
        let account = configuration.accountID
        epochs[account, default: 0] += 1
        refreshes[account]?.cancel()
        _ = try? await refreshes[account]?.value
        refreshes[account] = nil
        var state = states.removeValue(forKey: account)
        if state == nil, let data = try await credentials.read(CredentialReference(accountID: account, purpose: .oauthRefreshToken)) {
            state = try? NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
        }
        try await credentials.delete(CredentialReference(accountID: account, purpose: .oauthRefreshToken))
        guard revoke, let token = state?.refreshToken else { return !revoke }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        var components = URLComponents(); components.queryItems = [URLQueryItem(name: "token", value: token)]
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        do { let (_, response) = try await revokeTransport.data(for: request, maximumBytes: 65536); return response.statusCode == 200 }
        catch { return false }
    }
    private func validate(_ state: OIDAuthState, configuration: GmailConfiguration) throws {
        let request = state.lastAuthorizationResponse.request
        let scopes = Set((state.scope ?? "").split(separator: " ").map(String.init))
        guard state.isAuthorized, request.clientID == configuration.clientID,
              request.configuration.tokenEndpoint == Self.endpoints.tokenEndpoint,
              scopes.contains(configuration.permission.scope) || (configuration.permission == .readOnly && scopes.contains(GmailPermission.manageMail.scope))
        else { throw MailFailure.authenticationExpired }
    }
    private func persist(_ state: OIDAuthState, account: AccountID) async throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
        guard data.count <= 65536 else { throw GmailFailure.tooLarge }
        try await credentials.save(data, for: CredentialReference(accountID: account, purpose: .oauthRefreshToken))
    }
    private static var endpoints: OIDServiceConfiguration {
        OIDServiceConfiguration(authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                                tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!)
    }
}
private struct SingleToken: GoogleTokenSource {
    let value: String
    func accessToken(for configuration: GmailConfiguration, forceRefresh: Bool) async throws -> String {
        guard !forceRefresh else { throw MailFailure.authenticationExpired }; return value
    }
}
