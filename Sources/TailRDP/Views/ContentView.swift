import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var tailscale: TailscaleService
    @EnvironmentObject var launcher: RDPLauncher
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var selection: String?
    @State private var sessionEndGeneration: [String: UInt64] = [:]
    @AppStorage(AppSettingsKey.hasCompletedFirstRun) private var hasCompletedFirstRun = false
    @AppStorage(AppSettingsKey.dismissedDependencyWarning) private var dismissedDepWarning = false
    @AppStorage(AppSettingsKey.freerdpBinaryPath) private var freerdpOverride = ""
    @State private var showWizard = false

    private var missingDependencyMessage: String? {
        var missing: [String] = []
        if !DependencyChecker.freerdp(override: freerdpOverride.isEmpty ? nil : freerdpOverride).found {
            missing.append("FreeRDP")
        }
        if !DependencyChecker.tailscale(override: nil).found {
            missing.append("Tailscale")
        }
        guard !missing.isEmpty else { return nil }
        return "\(missing.joined(separator: " and ")) not found — open Settings to configure paths or install dependencies."
    }

    var body: some View {
        NavigationSplitView {
            PeerSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
        } detail: {
            if let id = selection, let idx = store.profiles.firstIndex(where: { $0.id == id }) {
                HostDetailView(profile: $store.profiles[idx])
                    .id(id)
            } else {
                ContentUnavailableView(
                    "Select a machine",
                    systemImage: "desktopcomputer",
                    description: Text("Pick a Tailscale machine to configure and connect.")
                )
            }
        }
        .safeAreaInset(edge: .top) {
            if !dismissedDepWarning, let msg = missingDependencyMessage {
                StatusBannerView(
                    text: msg,
                    style: .error,
                    actionLabel: "Settings",
                    onAction: { openSettings() },
                    onDismiss: { dismissedDepWarning = true }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.3), value: missingDependencyMessage)
        .onChange(of: tailscale.peers) { _, peers in
            store.merge(peers: peers)
            if selection == nil { selectDefault() }
        }
        .onAppear {
            if !hasCompletedFirstRun {
                showWizard = true
            }
            if !tailscale.peers.isEmpty { store.merge(peers: tailscale.peers) }
            if selection == nil { selectDefault() }
        }
        .sheet(isPresented: $showWizard) {
            FirstRunWizardView(isPresented: $showWizard)
                .environmentObject(tailscale)
                .environmentObject(store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAboutWindow)) { _ in
            openWindow(id: "about")
        }
        .onChange(of: launcher.sessionEndNotice) { _, notice in
            guard let notice else { return }
            if !notice.userInitiated, notice.endKind != .loggedOut {
                store.applySessionOutcome(
                    profileID: notice.profileID,
                    outcome: SessionEndOutcome(
                        message: notice.message,
                        kind: notice.endKind,
                        actionLabel: notice.endKind == .crashed ? "Reconnect" : "Resume"
                    )
                )
            }
            Task {
                let gen = (sessionEndGeneration[notice.profileID] ?? 0) + 1
                sessionEndGeneration[notice.profileID] = gen
                let outcome = await SessionCoordinator.handleSessionEnd(
                    notice: notice,
                    duration: notice.durationSeconds,
                    store: store,
                    launcher: launcher
                )
                guard sessionEndGeneration[notice.profileID] == gen else { return }
                store.applySessionOutcome(profileID: notice.profileID, outcome: outcome)
                launcher.clearSessionEndNotice(for: notice.profileID)
            }
        }
    }

    private func selectDefault() {
        selection = store.profiles.first(where: { $0.online })?.id ?? store.profiles.first?.id
    }
}
