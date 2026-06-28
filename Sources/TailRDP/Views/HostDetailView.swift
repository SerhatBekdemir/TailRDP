import SwiftUI

struct HostDetailView: View {
    @Binding var profile: HostProfile
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var launcher: RDPLauncher

    enum Tab: String, CaseIterable, Identifiable {
        case connection = "Connection"
        case files = "Files"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .connection
    @State private var banner: Banner?
    @State private var showDisplayRecoveryAction = false
    @State private var isConnecting = false

    struct Banner: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(.vertical, 8)
            Divider()
            content
        }
        .onChange(of: profile) { _, _ in store.save() }
        .onChange(of: launcher.sessionEndNotice) { _, notice in
            guard let notice, notice.profileID == profile.id else { return }
            banner = Banner(text: notice.message, isError: true)
            showDisplayRecoveryAction = notice.suggestDisplayRecovery
            launcher.clearSessionEndNotice(for: profile.id)
        }
        .safeAreaInset(edge: .bottom) { bannerView }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .connection: ConnectionSettingsView(profile: $profile)
        case .files:      FileTransferView(profile: $profile)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Image(systemName: profile.os == "windows" ? "pc" : "desktopcomputer")
                .font(.largeTitle)
                .foregroundStyle(profile.online ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName).font(.title2).bold()
                Text("\(profile.address.isEmpty ? "no address" : profile.address):\(profile.rdpPort)  ·  \(profile.rdpUsername)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            connectButton
        }
        .padding()
    }

    @ViewBuilder private var connectButton: some View {
        if launcher.isActive(profile.id) {
            Button(role: .destructive) {
                launcher.disconnect(profileID: profile.id)
            } label: {
                Label("Disconnect", systemImage: "stop.circle.fill").frame(minWidth: 90)
            }
            .controlSize(.large)
        } else {
            Button {
                connect()
            } label: {
                if isConnecting {
                    ProgressView().controlSize(.small).frame(minWidth: 90)
                } else {
                    Label("Connect", systemImage: "play.fill").frame(minWidth: 90)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(profile.address.isEmpty || !profile.online || isConnecting)
            .help(profile.online ? "Launch RDP session" : "Machine is offline")
        }
    }

    @ViewBuilder private var bannerView: some View {
        if let banner {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: banner.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    Text(banner.text).lineLimit(3)
                    Spacer()
                    Button {
                        self.banner = nil
                        showDisplayRecoveryAction = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                if showDisplayRecoveryAction, profile.os == "linux", !launcher.isActive(profile.id) {
                    Button("Reset remote display & reconnect") {
                        resetDisplayAndConnect()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isConnecting)
                }
            }
            .font(.callout)
            .foregroundStyle(.white)
            .padding(10)
            .background(banner.isError ? Color.red : Color.green)
        }
    }

    private func connect() {
        guard CredentialStore.shared.hasPassword(for: profile.id) else {
            tab = .connection
            banner = Banner(text: "Set a password in the Connection tab first.", isError: true)
            return
        }
        showDisplayRecoveryAction = false
        isConnecting = true
        Task {
            defer { isConnecting = false }
            if profile.os == "linux", profile.settings.autoRecoverDisplay {
                switch RemoteDisplayRecovery.recoverIfNeeded(profile) {
                case .failure(let err):
                    banner = Banner(text: "Display check failed: \(err.message)", isError: true)
                    return
                case .success(let summary):
                    if let summary {
                        banner = Banner(text: "Auto-reset remote display (\(summary)). Connecting…", isError: false)
                    }
                }
            }
            launchSession()
        }
    }

    private func resetDisplayAndConnect() {
        guard CredentialStore.shared.hasPassword(for: profile.id) else { return }
        showDisplayRecoveryAction = false
        isConnecting = true
        Task {
            defer { isConnecting = false }
            switch RemoteDisplayRecovery.recover(profile) {
            case .failure(let err):
                banner = Banner(text: "Display reset failed: \(err.message)", isError: true)
                return
            case .success(let summary):
                banner = Banner(text: "Display reset (\(summary)). Connecting…", isError: false)
            }
            launchSession()
        }
    }

    @MainActor
    private func launchSession() {
        if let err = launcher.launch(profile: profile) {
            banner = Banner(text: err, isError: true)
        } else {
            banner = Banner(text: "Launching \(profile.displayName)…", isError: false)
        }
    }
}
