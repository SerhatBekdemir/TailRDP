import SwiftUI

@main
struct TailRPDApp: App {
    @StateObject private var store = ProfileStore()
    @StateObject private var tailscale = TailscaleService()
    @StateObject private var launcher = RDPLauncher()

    var body: some Scene {
        WindowGroup("TailRPD") {
            ContentView()
                .environmentObject(store)
                .environmentObject(tailscale)
                .environmentObject(launcher)
                .frame(minWidth: 940, minHeight: 620)
                .onAppear { tailscale.refresh() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Refresh Tailnet") { tailscale.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
