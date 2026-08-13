import SwiftUI

struct ConnectionSettingsView: View {
    @Binding var profile: HostProfile
    var onManageCredentials: () -> Void
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var launcher: RDPLauncher

    @State private var hasStoredPassword = false
    @State private var advancedStatus: String?
    @State private var isAdvancedBusy = false
    @State private var showAdvanced = false

    private let resolutions: [(label: String, w: Int, h: Int, recommended: Bool)] = [
        ("1280 × 720", 1280, 720, false),
        ("1600 × 900", 1600, 900, false),
        ("1920 × 1080", 1920, 1080, true),
        ("2560 × 1440", 2560, 1440, false),
        ("3840 × 2160", 3840, 2160, false)
    ]

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Display name", text: $profile.displayName)
                TextField("Address", text: $profile.address)
                    .textContentType(.URL)
                Stepper("Port: \(profile.rdpPort)", value: $profile.rdpPort, in: 1...65535)
            }

            Section {
                if hasStoredPassword {
                    Label("Sign-in saved on this Mac", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Text("First Connect will ask for your username and password once.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Change sign-in…", action: onManageCredentials)
            } header: {
                Text("Sign-in")
            }

            Section {
                if profile.usesSafeFallback {
                    LabeledContent("Used when you Connect") {
                        Text(RDPSettings.safeFallback.connectSummary).foregroundStyle(.orange)
                    }
                    Text("TailRDP is using safe fallback settings after recent failures. A successful session will restore your preferred settings.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let last = profile.lastWorking {
                    LabeledContent("Used when you Connect") {
                        Text(last.settings.connectSummary).foregroundStyle(.secondary)
                    }
                    Text("Saved \(last.savedAt.formatted(date: .abbreviated, time: .shortened)) after a good session.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Connect will use the settings below. After a successful session, TailRDP remembers them automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Use current settings on next Connect") {
                    SessionCoordinator.promoteCurrentSettings(profileID: profile.id, store: store)
                    if let updated = store.profile(id: profile.id) { profile = updated }
                }
                .disabled(settingsMatchLastWorking)
            } header: {
                Text("Connect settings")
            }

            Section {
                Picker("Display mode", selection: displayModeBinding) {
                    ForEach(RDPDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text(profile.settings.displayMode.helpText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if profile.settings.displayMode != .resizable {
                    Picker("Resolution", selection: resolutionBinding) {
                        ForEach(resolutions, id: \.label) { res in
                            Text(res.recommended ? "\(res.label) — recommended" : res.label).tag(res.label)
                        }
                        if !isKnownResolution {
                            Text(customResolutionLabel).tag(customResolutionLabel)
                        }
                    }
                }

                if profile.settings.displayMode == .window {
                    Toggle("Span multiple monitors", isOn: $profile.settings.multiMonitor)
                }

                Picker("Color depth", selection: $profile.settings.bpp) {
                    Text("32-bit").tag(32)
                    Text("24-bit").tag(24)
                    Text("16-bit").tag(16)
                }
            } header: {
                Text("Display")
            }

            Section {
                Picker("Codec", selection: $profile.settings.codec) {
                    ForEach(GFXCodec.allCases) { Text($0.label).tag($0) }
                }
                Picker("Network profile", selection: $profile.settings.network) {
                    ForEach(NetworkType.allCases) { Text($0.label).tag($0) }
                }
                Text("AVC420 is the best default over Tailscale. Use AVC444 if you have bandwidth to spare.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Performance")
            }

            Section("Behavior") {
                Toggle("Clipboard sharing", isOn: $profile.settings.clipboard)
                Toggle("Audio", isOn: $profile.settings.sound)
                Toggle("Map ⌘ to Ctrl (fixes ⌘C / ⌘V over RDP)", isOn: $profile.settings.mapCmdToCtrl)
                Toggle("Auto-reconnect on drop", isOn: $profile.settings.autoReconnect)
                Toggle("Fix remote host on crash", isOn: $profile.settings.smartReconnect)
                Text("Closing the RDP window pauses the session — your work keeps running. TailRDP only fixes the remote host after an unexpected crash, and never reconnects automatically.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if profile.isLinux {
                Section {
                    DisclosureGroup("Advanced troubleshooting", isExpanded: $showAdvanced) {
                        if let advancedStatus {
                            Text(advancedStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Button("Check remote host") { checkRemoteStatus() }
                            .disabled(isAdvancedBusy || profile.address.isEmpty)
                        Button("Full remote session reset") { resetRemoteSession() }
                            .disabled(isAdvancedBusy || profile.address.isEmpty)
                    }
                }
            }

            Section("SSH (for file transfer)") {
                TextField("SSH username", text: $profile.sshUsername)
            }

            Section("Launch command") {
                TextEditor(text: commandLineBinding)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(minHeight: 72, maxHeight: 120)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary)
                    }

                HStack {
                    Label(
                        profile.launchCommandOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Generated from settings"
                            : "Custom command is active",
                        systemImage: profile.launchCommandOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "wand.and.stars"
                            : "pencil"
                    )
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to generated") {
                        profile.launchCommandOverride = ""
                    }
                    .disabled(profile.launchCommandOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let launchCommandValidationError {
                    Label(launchCommandValidationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text("Edit the full FreeRDP command. The saved password is inserted securely when you Connect and is never stored in this field.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            profile.settings.normalizeDisplayOptions()
            refreshStoredState()
        }
        .onChange(of: profile.id) { _, _ in refreshStoredState() }
    }

    private func refreshStoredState() {
        hasStoredPassword = CredentialStore.shared.hasPassword(for: profile.id)
    }

    private var settingsMatchLastWorking: Bool {
        profile.lastWorking?.settings == profile.settings
    }

    private var displayModeBinding: Binding<RDPDisplayMode> {
        Binding(
            get: { profile.settings.displayMode },
            set: { mode in
                profile.settings.apply(displayMode: mode)
            }
        )
    }

    private var isKnownResolution: Bool {
        resolutions.contains { $0.w == profile.settings.width && $0.h == profile.settings.height }
    }

    private var customResolutionLabel: String {
        "\(profile.settings.width) × \(profile.settings.height)"
    }

    private var launchCommandValidationError: String? {
        launcher.commandLineValidationError(for: profile.profileForConnect())
    }

    private var commandLineBinding: Binding<String> {
        Binding(
            get: {
                launcher.previewCommand(for: profile.profileForConnect())
            },
            set: { value in
                let normalized = FreeRDPCommandLine.sanitized(value) ?? value
                let generated = launcher.generatedPreviewCommand(for: profile.profileForConnect())
                profile.launchCommandOverride = normalized == generated ? "" : normalized
            }
        )
    }

    private var resolutionBinding: Binding<String> {
        Binding(
            get: {
                resolutions.first { $0.w == profile.settings.width && $0.h == profile.settings.height }?.label
                    ?? customResolutionLabel
            },
            set: { label in
                if let r = resolutions.first(where: { $0.label == label }) {
                    profile.settings.width = r.w
                    profile.settings.height = r.h
                }
            }
        )
    }

    private func checkRemoteStatus() {
        isAdvancedBusy = true
        let p = profile
        Task.detached(priority: .userInitiated) {
            let result = RemoteDisplayRecovery.inspect(p)
            await MainActor.run {
                isAdvancedBusy = false
                switch result {
                case .failure(let err):
                    advancedStatus = err.message
                case .success(let report):
                    advancedStatus = [
                        "Layout: \(report.layoutSummary)",
                        report.remoteSessionIDs.isEmpty
                            ? "No active remote sessions."
                            : "Remote sessions: \(report.remoteSessionIDs.joined(separator: ", "))"
                    ].joined(separator: "\n")
                }
            }
        }
    }

    private func resetRemoteSession() {
        isAdvancedBusy = true
        let p = profile
        Task.detached(priority: .userInitiated) {
            let result = RemoteDisplayRecovery.recover(p)
            await MainActor.run {
                isAdvancedBusy = false
                switch result {
                case .failure(let err):
                    advancedStatus = err.message
                case .success(let summary):
                    advancedStatus = "Reset complete: \(summary)."
                }
            }
        }
    }
}
