import Foundation

/// Owns the Immich connection: server URL, access token, and session state (DESIGN.md D7).
///
/// The password is used once, to exchange for a token, and is never persisted. Because of that
/// a 401 cannot be recovered silently — it surfaces as `.expired`, and the user signs in again.
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
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cachedState: State

    /// Fires whenever sign-in state changes, so the UI and sync engine can react.
    var onStateChange: ((State) -> Void)?

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
        lock.lock(); defer { lock.unlock() }
        return cachedState
    }

    var isConfigured: Bool {
        baseURL != nil && Keychain.get(Key.token) != nil
    }

    var baseURL: URL? {
        guard let string = defaults.string(forKey: Key.baseURL) else { return nil }
        return URL(string: string)
    }

    var email: String? { defaults.string(forKey: Key.email) }

    var token: String? { Keychain.get(Key.token) }

    /// Stable per-install identifier sent with uploads, so our own uploads link back to their
    /// local asset without waiting for a checksum pass (D5).
    var deviceID: String {
        if let existing = defaults.string(forKey: Key.deviceID) { return existing }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: Key.deviceID)
        return generated
    }

    // MARK: - Sign in / out

    /// Validates the server version, exchanges credentials for a token, and stores it.
    func signIn(baseURL: URL, email: String, password: String) async throws {
        let probe = ImmichClient(baseURL: baseURL, tokenProvider: { nil })

        let about = try await probe.serverAbout()
        try Self.validate(version: about.version)

        let response = try await probe.login(email: email, password: password)

        Keychain.set(response.accessToken, for: Key.token)
        defaults.set(baseURL.absoluteString, forKey: Key.baseURL)
        defaults.set(response.userEmail ?? email, forKey: Key.email)
        defaults.set(about.version, forKey: Key.serverVersion)

        updateState(.signedIn(email: response.userEmail ?? email, serverVersion: about.version))
    }

    func signOut() {
        Keychain.remove(Key.token)
        defaults.removeObject(forKey: Key.email)
        defaults.removeObject(forKey: Key.serverVersion)
        // The base URL is kept so the settings form stays pre-filled for the next sign-in.
        updateState(.signedOut)
    }

    /// Called when a request comes back 401: the token is dead and cannot be renewed without
    /// the password, which is never stored.
    func markExpired() {
        guard case .signedIn = state else { return }
        Keychain.remove(Key.token)
        updateState(.expired)
    }

    func forgetServer() {
        signOut()
        defaults.removeObject(forKey: Key.baseURL)
    }

    private func updateState(_ new: State) {
        lock.lock()
        cachedState = new
        lock.unlock()
        onStateChange?(new)
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
    /// because ATS only exempts local networking (D14).
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
