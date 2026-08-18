import SwiftUI

/// Immich server settings (requirement 13, DESIGN.md §13.4).
struct SettingsScreen: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                if viewModel.isSignedIn { connectedSection }
                if let error = viewModel.errorMessage { errorSection(error) }
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Connection isn’t private", isPresented: $viewModel.showsInsecureWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Connect anyway") { viewModel.confirmInsecureAndSignIn() }
            } message: {
                Text("This server uses http:// and isn’t on your local network, so your "
                     + "password and photos would be sent unencrypted.")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var serverSection: some View {
        Section {
            if viewModel.isSignedIn {
                LabeledContent("Server", value: viewModel.serverURLText)
                LabeledContent("Account", value: viewModel.email)
            } else {
                TextField("https://immich.example.com", text: $viewModel.serverURLText)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("Email", text: $viewModel.email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Password", text: $viewModel.password)
                    .textContentType(.password)
            }
        } header: {
            Text("Immich Server")
        } footer: {
            Text("Optional. OnlyDaves works fully offline with just the photos on this iPhone.")
        }

        Section {
            if viewModel.isWorking {
                HStack {
                    ProgressView()
                    Text(viewModel.statusMessage ?? "Working…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { viewModel.cancelSignIn() }
                        .buttonStyle(.borderless)
                }
                if let count = viewModel.syncedCount {
                    Text("\(count) items catalogued")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.isSignedIn {
                Button("Sign Out", role: .destructive) { viewModel.signOut() }
            } else {
                Button("Sign In") { viewModel.signIn() }
                    .disabled(!viewModel.canSignIn)
            }
        }
    }

    private var connectedSection: some View {
        Section("Library") {
            if let version = viewModel.serverVersion {
                LabeledContent("Server version", value: version)
            }
            if let date = viewModel.lastSyncDate {
                LabeledContent("Last refreshed",
                               value: date.formatted(date: .abbreviated, time: .shortened))
            }
            Button("Refresh Now") { viewModel.refreshNow() }
                .disabled(viewModel.isWorking)

            Button("Remove Server Data", role: .destructive) { viewModel.removeServerData() }
                .disabled(viewModel.isWorking)
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version",
                           value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
        } footer: {
            Text("Signing out keeps catalogued server photos browsable offline. "
                 + "Remove Server Data clears them.")
        }
    }
}
