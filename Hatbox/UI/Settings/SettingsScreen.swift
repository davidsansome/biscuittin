import SwiftUI

/// Immich server settings (requirement 13, DESIGN.md §13.4).
struct SettingsScreen: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var backupStatus: BackupStatusStore

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        self.backupStatus = viewModel.backupStatus
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                if viewModel.isSignedIn { syncSection }
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
            .confirmationDialog("What should be backed up?",
                                isPresented: $viewModel.showsScopePrompt,
                                titleVisibility: .visible) {
                Button("Back Up All Photos & Videos") { viewModel.chooseScope(.all) }
                Button("Back Up New Items Only") { viewModel.chooseScope(.newOnly(anchor: Date())) }
                Button("Not Now", role: .cancel) { viewModel.cancelScopePrompt() }
            } message: {
                Text("“New items only” backs up things captured from now on. "
                     + "You can switch to backing up everything later.")
            }
            .confirmationDialog("Free up space?",
                                isPresented: $viewModel.showsFreeUpSpaceConfirmation,
                                titleVisibility: .visible) {
                Button("Remove \(viewModel.freeUpSpacePlan.count) Items From iPhone",
                       role: .destructive) {
                    viewModel.performFreeUpSpace()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Frees \(viewModel.freeUpSpacePlan.formattedBytes). These items stay on "
                     + "your Immich server.")
            }
            .task { viewModel.refreshSyncStatus() }
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
            Text("Optional. Hatbox works fully offline with just the photos on this iPhone.")
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

    /// Requirement 14: the backup toggle, its scope, and progress.
    @ViewBuilder
    private var syncSection: some View {
        Section {
            Toggle("Back Up This iPhone", isOn: Binding(
                get: { viewModel.syncEnabled },
                set: { viewModel.setSyncEnabled($0) }))

            if viewModel.syncEnabled {
                LabeledContent("Scope") {
                    Text(scopeDescription).foregroundStyle(.secondary)
                }
                if viewModel.syncScope.isNewOnly {
                    Button("Back Up Older Items Too") { viewModel.upgradeScopeToAll() }
                    if viewModel.outOfScopeCount > 0 {
                        Text("\(viewModel.outOfScopeCount) older items are currently excluded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Waiting to upload") {
                    Text("\(backupStatus.remainingCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("Uploads photos and videos from this iPhone to your Immich server.")
        }
    }

    private var scopeDescription: String {
        guard let anchor = viewModel.syncScope.anchor else { return "All items" }
        return "New items only, since \(anchor.formatted(date: .abbreviated, time: .omitted))"
    }

    @ViewBuilder
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

        // D18: distinct from delete — removes only local copies that the server verifiably has.
        Section {
            if viewModel.freeUpSpacePlan.isEmpty {
                Text("Nothing to free up yet.")
                    .foregroundStyle(.secondary)
            } else {
                Button("Free Up Space") { viewModel.showsFreeUpSpaceConfirmation = true }
                    .disabled(viewModel.isWorking)
                Text("\(viewModel.freeUpSpacePlan.formattedBytes) in "
                     + "\(viewModel.freeUpSpacePlan.count) items backed up to Immich")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Removes these items from this iPhone only. They stay on your Immich server "
                 + "and remain browsable here.")
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
