import AuthenticationServices
import Foundation

/// Drives the full-screen Immich sign-in flow (DESIGN.md §13.4): server → credentials → backup.
///
/// Each page verifies what it can before the next is shown, so a mistyped address is reported
/// on the page where it was typed rather than after a password has been entered.
@MainActor
final class SignInFlowModel: ObservableObject {

    enum Page: Hashable {
        case credentials
        case backup
    }

    enum ServerStatus: Equatable {
        case idle
        case checking
        case found(ImmichServerInfo)
        case failed(String)
    }

    enum CredentialMethod: Equatable {
        case password
        case apiKey
    }

    enum BackupChoice: Hashable {
        case all
        case newOnly
        case notNow
    }

    @Published var path: [Page] = []
    @Published var serverText: String {
        didSet { if serverText != oldValue { serverTextChanged() } }
    }
    @Published private(set) var serverStatus: ServerStatus = .idle

    @Published var email: String
    @Published var password = ""
    @Published var apiKey = ""
    @Published var credentialMethod: CredentialMethod = .password {
        didSet { if credentialMethod != oldValue { credentialError = nil } }
    }
    @Published private(set) var isAuthenticating = false
    /// Which button shows the spinner: the provider can take a while, and the one tapped
    /// should be the one that looks busy.
    @Published private(set) var isAuthenticatingWithOAuth = false
    @Published private(set) var credentialError: String?

    @Published var backupChoice: BackupChoice = .all
    @Published private(set) var localItemCount: Int?
    /// Set when the flow has nothing left to ask; the view dismisses itself on it.
    @Published private(set) var isFinished = false

    private let session: ImmichAuthSession
    private let asksForBackupScope: Bool
    private let countLocalItems: () async -> Int
    private let onSignedIn: () -> Void
    private let onBackupChosen: (SyncScope?) -> Void

    private var probeTask: Task<Void, Never>?
    private var authTask: Task<Void, Never>?
    private var hasAutoLaunchedOAuth = false

    /// Probing waits for typing to pause, so each keystroke does not start a network round.
    private static let probeDebounce: Duration = .milliseconds(600)

    init(session: ImmichAuthSession,
         asksForBackupScope: Bool,
         countLocalItems: @escaping () async -> Int,
         onSignedIn: @escaping () -> Void,
         onBackupChosen: @escaping (SyncScope?) -> Void) {
        self.session = session
        self.asksForBackupScope = asksForBackupScope
        self.countLocalItems = countLocalItems
        self.onSignedIn = onSignedIn
        self.onBackupChosen = onBackupChosen
        self.serverText = session.baseURL.map(Self.editableText(for:)) ?? ""
        self.email = session.email ?? ""
        if session.usesAPIKey { credentialMethod = .apiKey }
    }

    /// Re-signing in after expiry should not make the user retype a server they already
    /// confirmed: probe it straight away, and go to credentials if it still answers.
    func start() {
        guard !serverText.isEmpty, case .idle = serverStatus else { return }
        let resumesExpiredSession = session.state == .expired
        probe(after: .zero) { [weak self] in
            if resumesExpiredSession { self?.continueFromServer(webAuthenticate: nil) }
        }
    }

    // MARK: - Page 1: server

    var server: ImmichServerInfo? {
        if case let .found(info) = serverStatus { return info }
        return nil
    }

    var canContinueFromServer: Bool { server != nil }

    func submitServer(webAuthenticate: @escaping WebAuthenticate) {
        if server != nil {
            continueFromServer(webAuthenticate: webAuthenticate)
        } else {
            probe(after: .zero) { [weak self] in
                self?.continueFromServer(webAuthenticate: webAuthenticate)
            }
        }
    }

    /// `webAuthenticate` is nil when continuing without a user's tap (resuming an expired
    /// session as the flow opens): the provider's sheet cannot be presented while the flow
    /// itself is still animating in, so auto-launch is left for the button.
    func continueFromServer(webAuthenticate: WebAuthenticate? = nil) {
        guard let server else { return }
        if !server.features.passwordLogin, credentialMethod == .password, !server.features.oauth {
            // Nothing to type a password into; an API key is the only way in.
            credentialMethod = .apiKey
        }
        credentialError = nil

        // The admin's "auto launch" setting means the provider is the expected way in, so go
        // straight there, once. Launching from this page's tap rather than from the next
        // page's appearance matters: a web-auth session started during a navigation push
        // fails with `presentationContextNotProvided` (observed; the same call from a settled
        // page succeeds). Anything but success lands on the credentials page, where the
        // alternatives are.
        if let webAuthenticate, server.features.oauth, server.features.oauthAutoLaunch,
           !hasAutoLaunchedOAuth {
            hasAutoLaunchedOAuth = true
            signInWithOAuth(webAuthenticate: webAuthenticate,
                            onFailure: { [weak self] in self?.path = [.credentials] })
            return
        }
        path = [.credentials]
    }

    private func serverTextChanged() {
        probeTask?.cancel()
        serverStatus = .idle
        guard !serverText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        probe(after: Self.probeDebounce)
    }

    private func probe(after delay: Duration, then onFound: (() -> Void)? = nil) {
        probeTask?.cancel()
        let input = serverText
        probeTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            self?.serverStatus = .checking
            do {
                let info = try await ImmichServerProbe.probe(input)
                guard !Task.isCancelled else { return }
                self?.serverStatus = .found(info)
                onFound?()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self?.serverStatus = .failed(Self.message(for: error))
            }
        }
    }

    // MARK: - Page 2: credentials

    var canSubmitCredentials: Bool {
        guard !isAuthenticating else { return false }
        switch credentialMethod {
        case .password: return !email.isEmpty && !password.isEmpty
        case .apiKey: return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var offersPassword: Bool { server?.features.passwordLogin ?? true }
    var offersOAuth: Bool { server?.features.oauth ?? false }

    var oauthButtonTitle: String {
        let text = server?.config.oauthButtonText?.trimmingCharacters(in: .whitespaces) ?? ""
        return text.isEmpty ? "Sign In with OAuth" : text
    }

    var loginPageMessage: String? {
        let text = server?.config.loginPageMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    func submitCredentials() {
        guard canSubmitCredentials, let server else { return }
        switch credentialMethod {
        case .password:
            let (email, password) = (email, password)
            authenticate { session in
                try await session.signIn(server: server, email: email, password: password)
            }
        case .apiKey:
            let key = apiKey
            authenticate { session in try await session.signIn(server: server, apiKey: key) }
        }
    }

    /// Presents the identity provider and returns its redirect. It comes from the view's
    /// environment, which is the only place SwiftUI exposes it.
    typealias WebAuthenticate = (URL) async throws -> URL

    func signInWithOAuth(webAuthenticate: @escaping WebAuthenticate,
                         onFailure: (() -> Void)? = nil) {
        guard !isAuthenticating, let server else { return }
        isAuthenticatingWithOAuth = true
        authenticate(onFailure: onFailure) { session in
            let attempt = try await session.beginOAuth(server: server)
            let callback = try await webAuthenticate(attempt.authorizationURL)
            try await session.completeOAuth(server: server, attempt: attempt, callbackURL: callback)
        }
    }

    /// Leaves without signing in. Anything in flight is abandoned, not completed behind the
    /// user's back after they chose not to connect.
    func close() {
        probeTask?.cancel()
        authTask?.cancel()
        isAuthenticating = false
        isAuthenticatingWithOAuth = false
        isFinished = true
    }

    private func authenticate(onFailure: (() -> Void)? = nil,
                              _ work: @escaping (ImmichAuthSession) async throws -> Void) {
        credentialError = nil
        isAuthenticating = true
        authTask?.cancel()
        authTask = Task { [weak self, session] in
            do {
                try await work(session)
                guard let self, !Task.isCancelled else { return }
                self.password = ""
                self.apiKey = ""
                self.isAuthenticating = false
                self.isAuthenticatingWithOAuth = false
                self.onSignedIn()
                if self.asksForBackupScope {
                    self.path.append(.backup)
                } else {
                    self.isFinished = true
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isAuthenticating = false
                self.isAuthenticatingWithOAuth = false
                if !Self.isUserCancellation(error) {
                    self.credentialError = Self.message(for: error)
                }
                onFailure?()
            }
        }
    }

    // MARK: - Page 3: backup

    func backupAppeared() {
        guard localItemCount == nil else { return }
        Task { [weak self, countLocalItems] in
            let count = await countLocalItems()
            self?.localItemCount = count
        }
    }

    func finishBackup() {
        switch backupChoice {
        case .all: onBackupChosen(.all)
        case .newOnly: onBackupChosen(.newOnly(anchor: Date()))
        case .notNow: onBackupChosen(nil)
        }
        isFinished = true
    }

    // MARK: - Helpers

    /// Shows a stored base URL the way a person would type it.
    static func editableText(for url: URL) -> String {
        url.scheme == "https"
            ? String(url.absoluteString.dropFirst("https://".count))
            : url.absoluteString
    }

    static func message(for error: Error) -> String {
        if error is ASWebAuthenticationSessionError {
            // The framework's own descriptions are codes, not sentences.
            return "Couldn’t open the sign-in page. Try again."
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Closing the provider's sheet is a choice, not a failure worth a red message.
    static func isUserCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
    }
}
