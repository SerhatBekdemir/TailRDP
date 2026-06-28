import SwiftUI

struct TailscaleSettingsView: View {
    @EnvironmentObject var tailscale: TailscaleService
    @EnvironmentObject var store: ProfileStore
    @AppStorage(AppSettingsKey.tailscaleBinaryPath) private var binaryOverride = ""
    @AppStorage(AppSettingsKey.freerdpBinaryPath) private var freerdpOverride = ""
    @AppStorage(AppSettingsKey.defaultUsername) private var defaultUsername = ""
    @AppStorage(AppSettingsKey.showOffline) private var showOffline = false

    @State private var showWizard = false

    var body: some View {
        Form {
            Section {
                Button("Open setup assistant…") { showWizard = true }
            }

            Section("Tailscale CLI") {
                LabeledContent("Detected", value: tailscale.detectedPath ?? "not found")
                TextField("Override path", text: $binaryOverride, prompt: Text("auto-detect"))
                LabeledContent("Effective", value: tailscale.binaryPath ?? "none — discovery off")
            }

            Section("FreeRDP") {
                let detected = DependencyChecker.freerdp(override: nil).path
                LabeledContent("Detected", value: detected ?? "not found")
                TextField("Override path", text: $freerdpOverride, prompt: Text("auto-detect"))
                let effective = DependencyChecker.freerdp(override: freerdpOverride.isEmpty ? nil : freerdpOverride).path
                LabeledContent("Effective", value: effective ?? "none — connect disabled")
            }

            Section("Tailnet") {
                if let me = tailscale.selfPeer {
                    LabeledContent("This machine", value: me.hostName)
                    LabeledContent("Tailscale IP", value: me.ipv4)
                }
                LabeledContent("Machines online",
                               value: "\(tailscale.peers.filter(\.online).count) / \(tailscale.peers.count)")
                Toggle("Show offline machines in sidebar", isOn: $showOffline)
                if let err = tailscale.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("Refresh now") { tailscale.refresh() }
                    .disabled(tailscale.isRefreshing)
            }

            Section("New machines") {
                TextField("Default username", text: $defaultUsername, prompt: Text("your username"))
                Text("Applied as the RDP + SSH username when a new tailnet machine is discovered.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section("SSH (optional)") {
                Label(
                    DependencyChecker.sshFound() ? "ssh found at /usr/bin/ssh" : "ssh not found",
                    systemImage: DependencyChecker.sshFound() ? "checkmark.circle" : "xmark.circle"
                )
                .font(.caption)
                Text("File transfer and Linux auto-recovery require passwordless SSH key auth. RDP does not.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
        .sheet(isPresented: $showWizard) {
            FirstRunWizardView(isPresented: $showWizard)
                .environmentObject(tailscale)
                .environmentObject(store)
        }
        .onAppear {
            if !binaryOverride.isEmpty,
               !FileManager.default.isExecutableFile(atPath: binaryOverride) {
                binaryOverride = ""
            }
            if !freerdpOverride.isEmpty,
               !FileManager.default.isExecutableFile(atPath: freerdpOverride) {
                freerdpOverride = ""
            }
            if tailscale.selfPeer == nil, !tailscale.isRefreshing {
                tailscale.refresh()
            }
        }
    }
}
