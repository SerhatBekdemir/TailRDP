import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var tailscale: TailscaleService
    @EnvironmentObject var launcher: RDPLauncher
    @State private var selection: String?

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
        .onChange(of: tailscale.peers) { _, peers in
            store.merge(peers: peers)
            if selection == nil { selectDefault() }
        }
        .onAppear {
            store.merge(peers: tailscale.peers)
            if selection == nil { selectDefault() }
        }
        .onChange(of: launcher.sessionEndNotice) { _, notice in
            guard let notice else { return }
            // Show the correct banner right away — don't leave the green connect ack
            // sitting on top until the Linux SSH check finishes (~1 s later).
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
                let outcome = await SessionCoordinator.handleSessionEnd(
                    notice: notice,
                    duration: notice.durationSeconds,
                    store: store,
                    launcher: launcher
                )
                store.applySessionOutcome(profileID: notice.profileID, outcome: outcome)
                launcher.clearSessionEndNotice(for: notice.profileID)
            }
        }
    }

    private func selectDefault() {
        selection = store.profiles.first(where: { $0.online })?.id ?? store.profiles.first?.id
    }
}
