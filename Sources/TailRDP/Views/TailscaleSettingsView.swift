import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TailscaleSettingsView: View {
    @EnvironmentObject var tailscale: TailscaleService
    @EnvironmentObject var store: ProfileStore
    @AppStorage(AppSettingsKey.tailscaleBinaryPath) private var binaryOverride = ""
    @AppStorage(AppSettingsKey.freerdpBinaryPath) private var freerdpOverride = ""
    @AppStorage(AppSettingsKey.defaultUsername) private var defaultUsername = ""
    @AppStorage(AppSettingsKey.showOffline) private var showOffline = false

    @State private var showWizard = false
    @State private var importExportMessage: String?

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

            Section("Profiles") {
                Text("Export saves connection settings only. Passwords stay on this Mac — re-enter them after import.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("Export…") { exportProfiles() }
                    Button("Import…") { importProfiles() }
                }
                if let importExportMessage {
                    Text(importExportMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 580)
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
        .onChange(of: binaryOverride) { _, _ in DependencyChecker.invalidateCache() }
        .onChange(of: freerdpOverride) { _, _ in DependencyChecker.invalidateCache() }
    }

    private func exportProfiles() {
        do {
            let data = try store.exportData()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "TailRDP-profiles.json"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                    importExportMessage = "Exported \(store.profiles.count) profile(s)."
                } catch {
                    importExportMessage = error.localizedDescription
                }
            }
        } catch {
            importExportMessage = error.localizedDescription
        }
    }

    private func importProfiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let result = try store.importData(data, merge: true)
                var msg = "Imported \(result.imported) profile(s)."
                if result.skipped > 0 { msg += " Skipped \(result.skipped) duplicate(s)." }
                if !result.needsPassword.isEmpty {
                    msg += " Re-enter passwords for: \(result.needsPassword.joined(separator: ", "))."
                }
                importExportMessage = msg
            } catch {
                importExportMessage = error.localizedDescription
            }
        }
    }
}
