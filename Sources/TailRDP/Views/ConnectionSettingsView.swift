import SwiftUI

struct ConnectionSettingsView: View {
    @Binding var profile: HostProfile
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var launcher: RDPLauncher

    @State private var password = ""
    @State private var showPassword = false
    @State private var hasStored = false
    @State private var justSaved = false
    @State private var advancedStatus: String?
    @State private var isAdvancedBusy = false
    @State private var showAdvanced = false

    private let resolutions: [(label: String, w: Int, h: Int)] = [
        ("1280 × 720", 1280, 720),
        ("1600 × 900", 1600, 900),
        ("1920 × 1080", 1920, 1080),
        ("2560 × 1440", 2560, 1440),
        ("3840 × 2160", 3840, 2160)
    ]

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Display name", text: $profile.displayName)
                TextField("Address", text: $profile.address)
                    .textContentType(.URL)
                Stepper("Port: \(profile.rdpPort)", value: $profile.rdpPort, in: 1...65535)
            }

            Section("Credentials") {
                TextField("Username", text: $profile.rdpUsername)
                HStack {
                    Group {
                        if showPassword {
                            TextField("Password", text: $password)
                        } else {
                            SecureField("Password", text: $password)
                        }
                    }
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showPassword ? "Hide" : "Show")
                }
                HStack(spacing: 12) {
                    Button("Save") {
                        CredentialStore.shared.set(password, for: profile.id)
                        hasStored = CredentialStore.shared.hasPassword(for: profile.id)
                        justSaved = true
                        if hasStored {
                            store.update(id: profile.id) { p in
                                p.sessionHealth = SessionHealth()
                                p.stickyBanner = nil
                            }
                            if let updated = store.profile(id: profile.id) { profile = updated }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    if justSaved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                    } else if hasStored {
                        Label("Stored", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                    Spacer()
                    Button("Clear") {
                        password = ""
                        CredentialStore.shared.remove(for: profile.id)
                        hasStored = false
                        justSaved = false
                    }
                    .font(.caption)
                    .disabled(password.isEmpty && !hasStored)
                }
                Text("Stored in macOS Keychain on this Mac only.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section {
                if profile.health.usingSafeFallback || profile.health.consecutiveFailures >= 2 {
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

            Section("Display") {
                Toggle("Dynamic resolution (follow window)", isOn: $profile.settings.dynamicResolution)
                if !profile.settings.dynamicResolution {
                    Picker("Resolution", selection: resolutionBinding) {
                        ForEach(resolutions, id: \.label) { Text($0.label).tag($0.label) }
                    }
                    Toggle("Fullscreen", isOn: $profile.settings.fullscreen)
                    Toggle("Span multiple monitors", isOn: $profile.settings.multiMonitor)
                }
                Picker("Color depth", selection: $profile.settings.bpp) {
                    Text("32-bit").tag(32)
                    Text("24-bit").tag(24)
                    Text("16-bit").tag(16)
                }
            }

            Section("Performance") {
                Picker("Codec", selection: $profile.settings.codec) {
                    ForEach(GFXCodec.allCases) { Text($0.label).tag($0) }
                }
                Picker("Network profile", selection: $profile.settings.network) {
                    ForEach(NetworkType.allCases) { Text($0.label).tag($0) }
                }
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

            if profile.os == "linux" {
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
                Text(launcher.previewCommand(for: profile.profileForConnect()))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
                Text("Shows what Connect will run (last good settings when available).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: password) { _, _ in justSaved = false }
        .onAppear {
            hasStored = CredentialStore.shared.hasPassword(for: profile.id)
            password = CredentialStore.shared.password(for: profile.id) ?? ""
            justSaved = false
        }
    }

    private var settingsMatchLastWorking: Bool {
        profile.lastWorking?.settings == profile.settings
    }

    private var resolutionBinding: Binding<String> {
        Binding(
            get: {
                resolutions.first { $0.w == profile.settings.width && $0.h == profile.settings.height }?.label
                    ?? "1920 × 1080"
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
