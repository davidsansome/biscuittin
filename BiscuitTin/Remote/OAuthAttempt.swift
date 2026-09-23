import CryptoKit
import Foundation

/// One in-flight OAuth login: where to send the user, and the secrets that prove the redirect
/// coming back belongs to this attempt.
struct OAuthAttempt: Sendable {
    /// Immich's own mobile redirect. The server special-cases exactly this string (it rewrites it
    /// to the admin's `mobileRedirectUri` when the provider cannot accept a custom scheme), and
    /// admins already register it with their identity provider for the official app. A Biscuit
    /// Tin scheme would work only after every admin added it. `ASWebAuthenticationSession`
    /// captures the redirect inside the session that started it, so it is never routed to the
    /// official app even when that is installed.
    static let redirectURI = "app.immich:///oauth-callback"
    static let callbackScheme = "app.immich"

    let authorizationURL: URL
    let state: String
    let codeVerifier: String
}

/// RFC 7636 PKCE values, generated on the device so the server never sees the verifier until the
/// code exchange.
struct OAuthPKCE {
    let state: String
    let codeVerifier: String
    let codeChallenge: String

    init() {
        state = Self.randomURLSafeString(byteCount: 16)
        codeVerifier = Self.randomURLSafeString(byteCount: 32)
        codeChallenge = Self.challenge(for: codeVerifier)
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
