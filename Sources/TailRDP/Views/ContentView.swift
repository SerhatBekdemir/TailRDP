import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var tailscale: TailscaleService
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
    }

    private func selectDefault() {
        selection = store.profiles.first(where: { $0.online })?.id ?? store.profiles.first?.id
    }
}
