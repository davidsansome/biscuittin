import Foundation

/// Owns the Immich connection: server URL, access token, and session state (DESIGN.md D7).
///
/// The password is used once, to exchange for a token, and is never persisted. Because of that
/// a 401 cannot be recovered silently — it surfaces as `.expired`, and the user signs in again.
/// An API key, when the user chose one instead, is stored in the token's Keychain slot.
final class ImmichAuthSession: @unchecked Sendable {

    enum State: Equatable {
        case signedOut
        case signedIn(email: String, serverVersion: String?)
        case expired
    }

    /// Minimum supported server (D8). Immich v3 renamed and stabilised the routes this app uses.
    static let minimumServerMajor = 3

    private enum Key {
        static let token = "immich.accessToken"
        static let baseURL = "immich.baseURL"
        static let email = "immich.email"
        static let serverVersion = "immich.serverVersion"
        static let deviceID = "immich.deviceId"
        /// Absent for a session token, which is what every install before API keys stored.
        static let credentialKind = "immich.credentialKind"
        static let apiKeyKind = "apiKey"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cachedState: State
    private var _onStateChange: ((State) -> Void)?

    /// Fires whenever sign-in state changes, so the UI and sync engine can react.
    var onStateChange: ((State) -> Void)? {
        get { lock.withLock { _onStateChange } }
        set { lock.withLock { _onStateChange = newValue } }
    }

    /// Posted on every state change, for the several screens that show an expired session.
    /// It can be posted from any thread: a 401 is noticed wherever the request ran.
    static let stateDidChangeNotification = Notification.Name("ImmichAuthSession.stateDidChange")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if Keychain.get(Key.token) != nil, let email = defaults.string(forKey: Key.email) {
            cachedState = .signedIn(email: email,
                                    serverVersion: defaults.string(forKey: Key.serverVersion))
        } else {
            cachedState = .signedOut
        }
    }

    // MARK: - State

    var state: State {
        lock.withLock { cachedState }
    }

    var isConfigured: Bool {
        lock.withLock {
            defaults.string(forKey: Key.baseURL) != nil && Keychain.get(Key.token) != nil
        }
    }

    var baseURL: URL? {
        guard let string = defaults.string(forKey: Key.baseURL) else { return nil }
        return URL(string: string)
    }

    var email: String? { defaults.string(forKey: Key.email) }

    /// Identifies whose server data a cache holds: the same account on the same server.
    var cacheOwner: String? {
        guard let baseURL, let email else { return nil }
        return "\(email.lowercased()) \(baseURL.absoluteString)"
    }

    var credential: ImmichCredential? {
        lock.withLock { currentCredentialLocked() }
    }

    var usesAPIKey: Bool {
        lock.withLock { defaults.string(forKey: Key.credentialKind) == Key.apiKeyKind }
    }

    /// Stable per-install identifier sent with uploads, so our own uploads link back to their
    /// local asset without waiting for a checksum pass (D5).
    var deviceID: String {
        lock.withLock {
            if let existing = defaults.string(forKey: Key.deviceID) { return existing }
            let generated = UUID().uuidString
            defaults.set(generated, forKey: Key.deviceID)
            return generated
        }
    }

    private func currentCredentialLocked() -> ImmichCredential? {
        guard let secret = Keychain.get(Key.token) else { return nil }
        return defaults.string(forKey: Key.credentialKind) == Key.apiKeyKind
            ? .apiKey(secret) : .accessToken(secret)
    }

    // MARK: - Sign in / out

    /// Password login. The server has already been identified and version-checked by
    /// `ImmichServerProbe`, from public endpoints — `/api/server/about` needs a token, which is
    /// why the gate used to run only after the password had been sent.
    func signIn(server: ImmichServerInfo, email: String, password: String) async throws {
        let client = ImmichClient(baseURL: server.baseURL, credentialProvider: { nil })
        let response: Immich.LoginResponse
        do {
            response = try await client.login(email: email, password: password)
        } catch ImmichError.unauthorized {
            // A 401 from the login endpoint itself means the credentials are wrong, which is a
            // different thing from an expired token.
            throw ImmichError.invalidCredentials
        }
        store(.accessToken(response.accessToken), email: response.userEmail ?? email,
              server: server)
    }

    /// API-key login. There is nothing to exchange; the key is checked by using it.
    func signIn(server: ImmichServerInfo, apiKey: String) async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = ImmichClient(baseURL: server.baseURL, credentialProvider: { .apiKey(key) })
        let user: Immich.UserResponse
        do {
            user = try await client.me()
        } catch ImmichError.unauthorized {
            // 401 for an unknown key, 403 for one lacking `user.read`; the fix is the same.
            throw ImmichError.invalidAPIKey
        }
        store(.apiKey(key), email: user.email ?? user.name ?? "API key", server: server)
    }

    /// First leg of OAuth: asks the server for the identity provider's URL, bound to a fresh
    /// state and PKCE challenge.
    func beginOAuth(server: ImmichServerInfo) async throws -> OAuthAttempt {
        let pkce = OAuthPKCE()
        let client = ImmichClient(baseURL: server.baseURL, credentialProvider: { nil })
        let response = try await client.oauthAuthorize(redirectURI: OAuthAttempt.redirectURI,
                                                       state: pkce.state,
                                                       codeChallenge: pkce.codeChallenge)
        guard let url = URL(string: response.url) else { throw ImmichError.invalidURL }
        return OAuthAttempt(authorizationURL: url, state: pkce.state, codeVerifier: pkce.codeVerifier)
    }

    /// Second leg: hands the provider's redirect back to the server, which exchanges the code.
    func completeOAuth(server: ImmichServerInfo, attempt: OAuthAttempt, callbackURL: URL) async throws {
        let parameters = Self.formDecodedQuery(of: callbackURL)
        if let error = parameters["error"] {
            throw ImmichError.oauthFailed(parameters["error_description"] ?? error)
        }
        // Checked here as well as by the server, so a mismatched redirect never reaches it.
        guard parameters["state"] == attempt.state else {
            throw ImmichError.oauthFailed(nil)
        }

        let client = ImmichClient(baseURL: server.baseURL, credentialProvider: { nil })
        let response: Immich.LoginResponse
        do {
            response = try await client.oauthCallback(url: callbackURL, state: attempt.state,
                                                      codeVerifier: attempt.codeVerifier)
        } catch let ImmichError.rejected(message) {
            throw ImmichError.oauthFailed(message)
        }
        store(.accessToken(response.accessToken), email: response.userEmail ?? "", server: server)
    }

    /// OAuth redirects are form-encoded (RFC 6749 §4.1.2.1), where `+` is a space.
    /// `URLComponents` decodes by RFC 3986, which leaves `+` alone, so a provider's
    /// "User+declined" would otherwise reach the screen verbatim.
    static func formDecodedQuery(of url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []
        var result: [String: String] = [:]
        for item in items {
            guard let raw = item.value else { continue }
            result[item.name] = raw.replacingOccurrences(of: "+", with: "%20").removingPercentEncoding
        }
        return result
    }

    private func store(_ credential: ImmichCredential, email: String, server: ImmichServerInfo) {
        let newState = State.signedIn(email: email, serverVersion: server.version.description)
        let handler: ((State) -> Void)? = lock.withLock {
            switch credential {
            case let .accessToken(token):
                Keychain.set(token, for: Key.token)
                defaults.removeObject(forKey: Key.credentialKind)
            case let .apiKey(key):
                Keychain.set(key, for: Key.token)
                defaults.set(Key.apiKeyKind, forKey: Key.credentialKind)
            }
            defaults.set(server.baseURL.absoluteString, forKey: Key.baseURL)
            defaults.set(email, forKey: Key.email)
            defaults.set(server.version.description, forKey: Key.serverVersion)
            cachedState = newState
            return _onStateChange
        }
        notifyStateChange(newState, handler: handler)
    }

    func signOut() {
        let handler: ((State) -> Void)? = lock.withLock {
            clearCredentialsLocked(removeBaseURL: false)
            cachedState = .signedOut
            return _onStateChange
        }
        notifyStateChange(.signedOut, handler: handler)
    }

    /// Called when a request comes back 401: the token is dead and cannot be renewed without
    /// the password, which is never stored.
    ///
    /// When `rejected` is supplied, expiration only takes effect if the session still holds that
    /// exact credential, preventing a stale 401 from wiping a newer sign-in.
    func markExpired(ifCredentialMatches rejected: ImmichCredential? = nil) {
        let result: (expired: Bool, handler: ((State) -> Void)?) = lock.withLock {
            guard case .signedIn = cachedState else { return (false, nil) }
            if let rejected, currentCredentialLocked() != rejected {
                return (false, nil)
            }
            Keychain.remove(Key.token)
            cachedState = .expired
            return (true, _onStateChange)
        }
        guard result.expired else { return }
        notifyStateChange(.expired, handler: result.handler)
    }

    func forgetServer() {
        let handler: ((State) -> Void)? = lock.withLock {
            clearCredentialsLocked(removeBaseURL: true)
            cachedState = .signedOut
            return _onStateChange
        }
        notifyStateChange(.signedOut, handler: handler)
    }

    private func clearCredentialsLocked(removeBaseURL: Bool) {
        Keychain.remove(Key.token)
        defaults.removeObject(forKey: Key.credentialKind)
        defaults.removeObject(forKey: Key.email)
        defaults.removeObject(forKey: Key.serverVersion)
        if removeBaseURL {
            defaults.removeObject(forKey: Key.baseURL)
        }
    }

    private func notifyStateChange(_ new: State, handler: ((State) -> Void)?) {
        handler?(new)
        NotificationCenter.default.post(name: Self.stateDidChangeNotification, object: self)
    }

    // MARK: - Version gate (D8)

    static func validate(version: String) throws {
        guard let major = majorVersion(of: version), major >= minimumServerMajor else {
            throw ImmichError.serverTooOld(found: version, required: "v\(minimumServerMajor).0")
        }
    }

    /// Immich reports versions as "v3.1.0"; older builds and some proxies drop the "v". Parse
    /// the leading integer rather than assuming either shape.
    static func majorVersion(of version: String) -> Int? {
        let digits = version
            .drop { !$0.isNumber }
            .prefix { $0.isNumber }
        return Int(digits)
    }

    /// Normalises what a user types into a usable base URL. Accepts bare hosts, adds a scheme,
    /// and strips a trailing `/api` since every client path already carries it.
    static func normalizeServerURL(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix("/api") { text = String(text.dropLast(4)) }

        guard let url = URL(string: text), let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    /// True when plain HTTP is being used to a non-local host, which needs an explicit warning
    /// because ATS permits it (D14) and credentials would cross the internet in the clear.
    static func isInsecureNonLocal(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else {
            return false
        }
        if host == "localhost" || host.hasSuffix(".local") { return false }
        if host == "127.0.0.1" || host == "::1" { return false }
        // RFC1918 ranges.
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return false }
        if host.hasPrefix("172.") {
            let second = Int(host.split(separator: ".").dropFirst().first.map(String.init) ?? "") ?? 0
            if (16...31).contains(second) { return false }
        }
        return true
    }
}
