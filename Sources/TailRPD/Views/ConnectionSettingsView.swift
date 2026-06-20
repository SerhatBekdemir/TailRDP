import SwiftUI

struct ConnectionSettingsView: View {
    @Binding var profile: HostProfile
    @EnvironmentObject var launcher: RDPLauncher

    @State private var password = ""
    @State private var hasStoredPassword = false

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
                HStack {
                    TextField("RDP username", text: $profile.rdpUsername)
                    Stepper("Port \(profile.rdpPort)", value: $profile.rdpPort, in: 1...65535)
                        .fixedSize()
                }
                SecureField("Password", text: $password)
                HStack(spacing: 12) {
                    Button("Save to Keychain") {
                        KeychainService.setPassword(password, account: profile.id)
                        hasStoredPassword = !password.isEmpty
                        password = ""
                    }
                    .disabled(password.isEmpty)
                    if hasStoredPassword {
                        Label("Stored", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green).font(.caption)
                        Button("Remove") {
                            KeychainService.deletePassword(account: profile.id)
                            hasStoredPassword = false
                        }
                        .font(.caption)
                    }
                    Spacer()
                }
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
            }

            Section("SSH (for file transfer)") {
                TextField("SSH username", text: $profile.sshUsername)
            }

            Section("Launch command") {
                Text(launcher.previewCommand(for: profile))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
                Text("Password is fed over stdin — never shown here or in the process list.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hasStoredPassword = KeychainService.hasPassword(account: profile.id)
            password = ""
        }
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
}
