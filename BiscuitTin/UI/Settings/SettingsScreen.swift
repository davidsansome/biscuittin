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
                Button("Remove \(viewModel.freeUpSpacePlan.count) Items From \(DeviceName.current)",
                       role: .destructive) {
                    viewModel.performFreeUpSpace()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Frees \(viewModel.freeUpSpacePlan.formattedBytes). These items stay on "
                     + "your Immich server.")
            }
            .task { viewModel.refreshSyncStatus() }
            .fullScreenCover(isPresented: $viewModel.showsSignInFlow) {
                SignInFlowView(model: viewModel.makeSignInFlowModel())
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var serverSection: some View {
        Section {
            if viewModel.isSignedIn {
                accountRow
            } else {
                Button {
                    viewModel.showsSignInFlow = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.isExpired ? "Sign In Again" : "Connect to Immich")
                                .foregroundStyle(.primary)
                            if viewModel.isExpired, let url = viewModel.serverURL {
                                Text("Your session on \(ImmichServerInfo.displayHost(for: url)) has expired.")
                                    .font(.caption)
                                    // Plain `.secondary` inside a button is a faded tint.
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: viewModel.isExpired
                              ? "exclamationmark.arrow.circlepath" : "server.rack")
                    }
                }
            }

            if viewModel.isWorking {
                HStack {
                    ProgressView()
                    Text(viewModel.statusMessage ?? "Working…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { viewModel.cancelSignIn() }
                        .buttonStyle(.borderless)
                }
                if let progress = viewModel.syncProgress {
                    Text(Self.progressText(progress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.isSignedIn {
                Button("Sign Out", role: .destructive) { viewModel.signOut() }
            }
        } header: {
            Text("Immich Server")
        } footer: {
            if !viewModel.isSignedIn {
                Text("Optional. Biscuit Tin works fully offline with just the photos on this \(DeviceName.current).")
            }
        }
    }

    /// A partner's library can dwarf the user's own and arrives in the same download, so it is
    /// counted too — otherwise a long sign-in sync reads "0 items" throughout.
    static func progressText(_ progress: SyncProgress) -> String {
        let own = "\(progress.assets.formatted()) items catalogued"
        guard progress.partnerAssets > 0 else { return own }
        return "\(own), plus \(progress.partnerAssets.formatted()) shared with you"
    }

    private var accountRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.accountDescription)
                    .font(.headline)
                if let url = viewModel.serverURL {
                    Text([ImmichServerInfo.displayHost(for: url), viewModel.serverVersion].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// Requirement 14: the backup toggle, its scope, and progress.
    @ViewBuilder
    private var syncSection: some View {
        Section {
            Toggle("Back Up This \(DeviceName.current)", isOn: Binding(
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
            Text("Uploads photos and videos from this \(DeviceName.current) to your Immich server.")
        }
    }

    private var scopeDescription: String {
        guard let anchor = viewModel.syncScope.anchor else { return "All items" }
        return "New items only, since \(anchor.formatted(date: .abbreviated, time: .omitted))"
    }

    @ViewBuilder
    private var connectedSection: some View {
        Section("Library") {
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
            Text("Removes these items from this \(DeviceName.current) only. They stay on your Immich server "
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
