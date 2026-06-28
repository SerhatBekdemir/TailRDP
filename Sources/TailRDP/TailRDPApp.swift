import SwiftUI

@main
struct TailRDPApp: App {
    @StateObject private var store = ProfileStore()
    @StateObject private var tailscale = TailscaleService()
    @StateObject private var launcher = RDPLauncher()

    init() {
        if CommandLine.arguments.contains("--verify-session") {
            let failures = SessionEndClassifier.runBuiltInChecks()
            exit(failures == 0 ? 0 : 1)
        }
    }

    var body: some Scene {
        WindowGroup("TailRDP") {
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
            CommandGroup(replacing: .appInfo) {
                Button("About TailRDP") {
                    NotificationCenter.default.post(name: .showAboutWindow, object: nil)
                }
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh Tailnet") { tailscale.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            TailscaleSettingsView()
                .environmentObject(tailscale)
                .environmentObject(store)
        }

        Window("About TailRDP", id: "about") {
            AboutView()
                .environmentObject(tailscale)
                .environmentObject(launcher)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
