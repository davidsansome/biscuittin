import Foundation

extension Error {
    /// User-facing error text, preferring `LocalizedError.errorDescription` over `localizedDescription`.
    var userMessage: String {
        (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}
