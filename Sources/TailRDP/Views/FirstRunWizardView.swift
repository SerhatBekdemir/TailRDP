import SwiftUI

struct FirstRunWizardView: View {
    @EnvironmentObject var tailscale: TailscaleService
    @EnvironmentObject var store: ProfileStore
    @Binding var isPresented: Bool

    @AppStorage(AppSettingsKey.defaultUsername) private var defaultUsername = ""
    @AppStorage(AppSettingsKey.freerdpBinaryPath) private var freerdpOverride = ""
    @AppStorage(AppSettingsKey.hasCompletedFirstRun) private var hasCompletedFirstRun = false

    @State private var step = 0
    @State private var tailscaleSkipped = false
    @State private var freerdpSkipped = false

    private let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            progressBar
            Divider()
            ScrollView {
                stepContent
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 480)
        .interactiveDismissDisabled(!hasCompletedFirstRun)
    }

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case 0: welcomeStep
        case 1: tailscaleStep
        case 2: freerdpStep
        case 3: usernameStep
        default: tailnetStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to TailRDP").font(.title).bold()
            Text("TailRDP connects to machines on your Tailscale network using FreeRDP. You need both installed separately on this Mac.")
            Label("Tailscale — discovers machines on your tailnet", systemImage: "network")
            Label("FreeRDP (sdl-freerdp) — opens the remote desktop window", systemImage: "desktopcomputer")
            Text("File transfer and Linux session auto-recovery need SSH key auth to each host. RDP alone does not require SSH.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var tailscaleStep: some View {
        let status = DependencyChecker.tailscale(
            override: UserDefaults.standard.string(forKey: AppSettingsKey.tailscaleBinaryPath)
        )
        return VStack(alignment: .leading, spacing: 16) {
            Text("Tailscale").font(.title2).bold()
            dependencyRow(
                found: status.found || tailscaleSkipped,
                label: status.found ? "Found at \(status.path ?? "")" : "Not found"
            )
            if !status.found {
                Text("Install from [tailscale.com](https://tailscale.com/download) or `brew install tailscale`, then sign in.")
                    .font(.callout)
            }
            Button("Refresh tailnet") { tailscale.refresh() }
                .disabled(tailscale.isRefreshing || !status.found)
        }
    }

    private var freerdpStep: some View {
        let status = DependencyChecker.freerdp(override: freerdpOverride.isEmpty ? nil : freerdpOverride)
        return VStack(alignment: .leading, spacing: 16) {
            Text("FreeRDP").font(.title2).bold()
            dependencyRow(
                found: status.found || freerdpSkipped,
                label: status.found ? "Found at \(status.path ?? "")" : "Not found"
            )
            TextField("Override path (optional)", text: $freerdpOverride, prompt: Text("auto-detect"))
            if !status.found {
                Text("Install with `brew install freerdp` on Apple Silicon.")
                    .font(.callout)
            }
        }
    }

    private var usernameStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Default username").font(.title2).bold()
            Text("Applied to newly discovered tailnet machines and manual hosts.")
                .foregroundStyle(.secondary)
            TextField("Your username", text: $defaultUsername, prompt: Text("e.g. jane"))
                .textFieldStyle(.roundedBorder)
            if defaultUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Required to continue.").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var tailnetStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your tailnet").font(.title2).bold()
            if tailscale.isRefreshing {
                ProgressView("Scanning…")
            } else if let err = tailscale.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                let count = tailscale.peers.filter { !$0.isSelf }.count
                Label("\(count) machine\(count == 1 ? "" : "s") discovered", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("All tailnet peers appear in the sidebar. Configure RDP only on hosts that run a remote desktop server.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Refresh now") { tailscale.refresh() }
                .disabled(tailscale.isRefreshing)
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Spacer()
            if step == 1, !DependencyChecker.tailscale().found {
                Button("Skip") {
                    tailscaleSkipped = true
                    step += 1
                }
            }
            if step == 2, !DependencyChecker.freerdp(override: freerdpOverride.isEmpty ? nil : freerdpOverride).found {
                Button("Skip") {
                    freerdpSkipped = true
                    step += 1
                }
            }
            if step < totalSteps - 1 {
                Button("Continue") { step += 1 }
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == 3 && defaultUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button("Finish") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(defaultUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }

    private func dependencyRow(found: Bool, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: found ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(found ? .green : .red)
            Text(label)
        }
    }

    private func finish() {
        if !tailscale.peers.isEmpty { store.merge(peers: tailscale.peers) }
        hasCompletedFirstRun = true
        isPresented = false
    }
}
