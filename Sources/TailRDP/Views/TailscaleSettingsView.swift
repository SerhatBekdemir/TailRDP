import SwiftUI

struct TailscaleSettingsView: View {
    @EnvironmentObject var tailscale: TailscaleService
    @AppStorage(AppSettingsKey.tailscaleBinaryPath) private var binaryOverride = ""
    @AppStorage(AppSettingsKey.defaultUsername) private var defaultUsername = "aegis"

    var body: some View {
        Form {
            Section("Tailscale CLI") {
                LabeledContent("Detected", value: tailscale.detectedPath ?? "not found")
                TextField("Override path", text: $binaryOverride, prompt: Text("auto-detect"))
                LabeledContent("Effective", value: tailscale.binaryPath ?? "none — discovery off")
            }

            Section("Tailnet") {
                if let me = tailscale.selfPeer {
                    LabeledContent("This machine", value: me.hostName)
                    LabeledContent("Tailscale IP", value: me.ipv4)
                }
                LabeledContent("Machines online",
                               value: "\(tailscale.peers.filter(\.online).count) / \(tailscale.peers.count)")
                if let err = tailscale.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("Refresh now") { tailscale.refresh() }
                    .disabled(tailscale.isRefreshing)
            }

            Section("New machines") {
                TextField("Default username", text: $defaultUsername, prompt: Text("aegis"))
                Text("Applied as the RDP + SSH username when a new tailnet machine is discovered.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 430)
        .onAppear {
            if !binaryOverride.isEmpty,
               !FileManager.default.isExecutableFile(atPath: binaryOverride) {
                binaryOverride = ""
            }
            if tailscale.selfPeer == nil, !tailscale.isRefreshing {
                tailscale.refresh()
            }
        }
    }
}
