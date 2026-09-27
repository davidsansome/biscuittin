import AuthenticationServices
import SwiftUI

/// Full-screen Immich sign-in (DESIGN.md §13.4). Connecting is optional, so every page before
/// sign-in completes can be closed without consequence. Pages close through the model: the
/// environment's `dismiss` inside a pushed page pops the page rather than closing the flow.
struct SignInFlowView: View {
    @StateObject private var model: SignInFlowModel
    @Environment(\.dismiss) private var dismiss

    init(model: @autoclosure @escaping () -> SignInFlowModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        NavigationStack(path: $model.path) {
            ServerPage(model: model)
                .navigationDestination(for: SignInFlowModel.Page.self) { page in
                    switch page {
                    case .credentials: CredentialsPage(model: model)
                    case .backup: BackupPage(model: model)
                    }
                }
        }
        .onChange(of: model.isFinished) { _, finished in
            if finished { dismiss() }
        }
        .onAppear { model.start() }
    }
}

// MARK: - Page 1: server

private struct ServerPage: View {
    @ObservedObject var model: SignInFlowModel
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @FocusState private var fieldFocused: Bool

    var body: some View {
        SignInPageLayout(title: "Connect to Immich",
                         subtitle: "Enter the address you use to open Immich in a browser.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    SignInField(symbol: "globe") {
                        // No `textContentType`: nothing useful completes a server address, and
                        // any suggestion strip over the keyboard pushes the field out of view.
                        TextField("photos.example.com", text: $model.serverText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.continue)
                            .focused($fieldFocused)
                            .onSubmit { model.submitServer(webAuthenticate: webAuthenticate) }
                    }

                    if model.serverText.isEmpty {
                        PasteButton(payloadType: String.self) { strings in
                            if let text = strings.first { model.serverText = text }
                        }
                        .buttonBorderShape(.capsule)
                        .labelStyle(.iconOnly)
                    }
                }

                status

                if let server = model.server, server.isInsecureNonLocal {
                    insecureWarning
                }

                Text("An account is optional. Biscuit Tin works fully with just the photos on "
                     + "this \(DeviceName.current).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        } actions: {
            SignInPrimaryButton(title: model.server?.isInsecureNonLocal == true
                                    ? "Connect Anyway" : "Continue",
                                isLoading: model.serverStatus == .checking
                                    || model.isAuthenticating) {
                model.submitServer(webAuthenticate: webAuthenticate)
            }
            .disabled(model.serverText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Not Now") { model.close() }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(trigger: model.serverStatus) { _, status in
            switch status {
            case .found: return .success
            case .failed: return .error
            default: return nil
            }
        }
        .onAppear {
            // Straight to the keyboard for a new server; a remembered one is probably right.
            if model.serverText.isEmpty { fieldFocused = true }
        }
    }

    private func webAuthenticate(_ url: URL) async throws -> URL {
        try await webAuthenticationSession.authenticateWithImmich(url)
    }

    @ViewBuilder
    private var status: some View {
        switch model.serverStatus {
        case .idle:
            SignInStatusLine(text: "A hostname, IP address or full URL.")
        case .checking:
            SignInStatusLine(text: "Looking for Immich…", showsProgress: true)
        case let .found(server):
            SignInStatusLine(text: "Immich \(server.version.description)",
                             symbol: "checkmark.circle.fill", tone: .success)
        case let .failed(message):
            SignInStatusLine(text: message, symbol: "exclamationmark.circle.fill", tone: .failure)
        }
    }

    /// D14: plain HTTP off the local network needs an explicit decision, made here where the
    /// address was chosen rather than after credentials are typed.
    private var insecureWarning: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.open.fill").foregroundStyle(.orange)
            Text("This server uses http:// and isn’t on your local network, so your password and "
                 + "photos would be sent unencrypted.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Page 2: credentials

private struct CredentialsPage: View {
    @ObservedObject var model: SignInFlowModel
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    private enum Field { case email, password, apiKey }
    @FocusState private var focus: Field?

    var body: some View {
        SignInPageLayout(title: "Sign In",
                         subtitle: "to \(model.server?.displayHost ?? "your server")") {
            VStack(alignment: .leading, spacing: 14) {
                if let message = model.loginPageMessage {
                    Text(message)
                        .font(.subheadline)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                switch model.credentialMethod {
                case .password where model.offersPassword:
                    passwordFields
                case .password:
                    Text("This server signs in through its identity provider.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                case .apiKey:
                    apiKeyField
                }

                if let error = model.credentialError {
                    SignInStatusLine(text: error, symbol: "exclamationmark.circle.fill",
                                     tone: .failure)
                }

                alternatives
            }
        } actions: {
            primaryAction
        }
        .toolbar {
            // Trailing: the leading edge already holds the back button.
            ToolbarItem(placement: .topBarTrailing) {
                Button("Not Now") { model.close() }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.error, trigger: model.credentialError) { _, new in new != nil }
        .onAppear { focus = initialFocus }
        .onChange(of: model.credentialMethod) { _, _ in focus = initialFocus }
    }

    private var initialFocus: Field? {
        switch model.credentialMethod {
        case .password where model.offersPassword: return model.email.isEmpty ? .email : .password
        case .password: return nil
        case .apiKey: return .apiKey
        }
    }

    private var passwordFields: some View {
        VStack(spacing: 12) {
            SignInField(symbol: "envelope") {
                TextField("Email", text: $model.email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .email)
                    .onSubmit { focus = .password }
            }
            SignInField(symbol: "lock") {
                SecureField("Password", text: $model.password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focus, equals: .password)
                    .onSubmit { model.submitCredentials() }
            }
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 10) {
            SignInField(symbol: "key") {
                SecureField("API Key", text: $model.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focus, equals: .apiKey)
                    .onSubmit { model.submitCredentials() }
            }
            Text("Create one in the Immich web app under Account Settings → API Keys. "
                 + "Choosing “All” permissions lets Biscuit Tin browse, back up and edit.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The OAuth button leads only when there is nothing to type; otherwise it is an
    /// alternative beneath the form.
    private var oauthLeads: Bool {
        model.offersOAuth && model.credentialMethod == .password && !model.offersPassword
    }

    /// Only the primary action is pinned: with the keyboard up, anything more covers the
    /// fields it acts on.
    @ViewBuilder
    private var primaryAction: some View {
        if oauthLeads {
            SignInPrimaryButton(title: model.oauthButtonTitle, isLoading: model.isAuthenticating) {
                model.signInWithOAuth(webAuthenticate: webAuthenticate)
            }
        } else {
            SignInPrimaryButton(title: "Sign In",
                                isLoading: model.isAuthenticating && !model.isAuthenticatingWithOAuth) {
                model.submitCredentials()
            }
            .disabled(!model.canSubmitCredentials)
        }
    }

    @ViewBuilder
    private var alternatives: some View {
        VStack(spacing: 14) {
            if model.offersOAuth && !oauthLeads {
                HStack(spacing: 12) {
                    VStack { Divider() }
                    Text("or").font(.subheadline).foregroundStyle(.secondary)
                    VStack { Divider() }
                }
                SignInPrimaryButton(title: model.oauthButtonTitle,
                                    isLoading: model.isAuthenticatingWithOAuth, prominent: false) {
                    model.signInWithOAuth(webAuthenticate: webAuthenticate)
                }
                .disabled(model.isAuthenticating)
            }

            switch model.credentialMethod {
            case .password:
                Button("Use an API Key Instead") { model.credentialMethod = .apiKey }
            case .apiKey where model.offersPassword:
                Button("Use Email and Password Instead") { model.credentialMethod = .password }
            case .apiKey:
                EmptyView()
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
        .disabled(model.isAuthenticating)
        .padding(.top, 8)
    }

    private func webAuthenticate(_ url: URL) async throws -> URL {
        try await webAuthenticationSession.authenticateWithImmich(url)
    }
}

private extension WebAuthenticationSession {
    func authenticateWithImmich(_ url: URL) async throws -> URL {
        try await authenticate(
            using: url,
            callbackURLScheme: OAuthAttempt.callbackScheme,
            // Shared, so a user already signed in to their identity provider in Safari is not
            // asked again.
            preferredBrowserSession: .shared)
    }
}

// MARK: - Page 3: backup

private struct BackupPage: View {
    @ObservedObject var model: SignInFlowModel

    var body: some View {
        SignInPageLayout(symbol: "arrow.up.circle",
                         title: "Back Up This \(DeviceName.current)?",
                         subtitle: "Biscuit Tin can upload photos and videos from this \(DeviceName.current) to "
                            + "\(model.server?.displayHost ?? "your server").") {
            VStack(spacing: 12) {
                SignInChoiceCard(symbol: "photo.on.rectangle.angled",
                                 title: "All Photos & Videos",
                                 detail: allDetail,
                                 isSelected: model.backupChoice == .all) {
                    model.backupChoice = .all
                }
                SignInChoiceCard(symbol: "sparkles",
                                 title: "New Items Only",
                                 detail: "Photos and videos taken from today. You can include "
                                    + "older items later.",
                                 isSelected: model.backupChoice == .newOnly) {
                    model.backupChoice = .newOnly
                }
                SignInChoiceCard(symbol: "eye",
                                 title: "Just Browse",
                                 detail: "See your Immich library here without uploading anything. "
                                    + "You can turn on backup in Settings.",
                                 isSelected: model.backupChoice == .notNow) {
                    model.backupChoice = .notNow
                }
            }
        } actions: {
            SignInPrimaryButton(title: model.backupChoice == .notNow ? "Done" : "Start Backup") {
                model.finishBackup()
            }
        }
        .navigationBarBackButtonHidden()
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: model.backupChoice)
        .onAppear { model.backupAppeared() }
    }

    private var allDetail: String {
        guard let count = model.localItemCount, count > 0 else {
            return "Everything in your photo library."
        }
        return "Everything in your photo library — \(count.formatted()) items."
    }
}
