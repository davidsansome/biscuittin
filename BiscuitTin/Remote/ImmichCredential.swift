import Foundation

/// How requests authenticate to Immich. A session token and an API key are interchangeable for
/// every endpoint this app calls; they differ only in the header that carries them.
enum ImmichCredential: Equatable, Sendable {
    /// From password or OAuth login; revoked when the user signs out elsewhere.
    case accessToken(String)
    /// Created by the user in Immich's account settings. Scoped by the permissions chosen there.
    case apiKey(String)

    var headerField: String {
        switch self {
        case .accessToken: return "Authorization"
        case .apiKey: return "x-api-key"
        }
    }

    var headerValue: String {
        switch self {
        case let .accessToken(token): return "Bearer \(token)"
        case let .apiKey(key): return key
        }
    }
}
