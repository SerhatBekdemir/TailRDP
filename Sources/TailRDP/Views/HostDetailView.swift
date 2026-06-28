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

    /// Short-lived banners (connect ack, validation) — not stored on the profile.
    private struct TransientBanner: Identifiable {
        let id = UUID()
        let text: String
        let style: BannerStyle
    }

    @State private var tab: Tab = .connection
    @State private var transientBanner: TransientBanner?
    @State private var isConnecting = false

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
        .onChange(of: store.ephemeralBanner) { _, flash in
            guard let flash, flash.hostID == profile.id else { return }
            transientBanner = TransientBanner(text: flash.text, style: .success)
            store.clearEphemeralBanner(hostID: profile.id)
        }
        .onAppear {
            if let flash = store.ephemeralBanner, flash.hostID == profile.id {
                transientBanner = TransientBanner(text: flash.text, style: .success)
                store.clearEphemeralBanner(hostID: profile.id)
            }
        }
        .onChange(of: launcher.sessionEndNotice) { _, notice in
            guard notice?.profileID == profile.id else { return }
            transientBanner = nil
        }
        .onChange(of: profile.stickyBanner) { _, sticky in
            if sticky != nil { transientBanner = nil }
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
                if let last = profile.lastWorking {
                    Text("Last good: \(last.settings.connectSummary)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if profile.health.usingSafeFallback || profile.health.consecutiveFailures >= 2 {
                    Text("Using safe fallback until a session succeeds")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
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
                } else if profile.stickyBanner?.actionLabel != nil {
                    Label(profile.stickyBanner!.actionLabel!, systemImage: "play.fill")
                        .frame(minWidth: 90)
                } else {
                    Label("Connect", systemImage: "play.fill").frame(minWidth: 90)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(profile.address.isEmpty || !profile.online || isConnecting)
            .help(connectHelp)
        }
    }

    private var connectHelp: String {
        if !profile.online { return "Machine is offline" }
        if profile.stickyBanner?.style == .paused { return "Resume your paused session" }
        if profile.stickyBanner?.style == .error { return "Reconnect after the last problem" }
        if profile.lastWorking != nil { return "Connect using your last good settings" }
        return "Connect"
    }

    @ViewBuilder private var bannerView: some View {
        if let sticky = profile.stickyBanner {
            bannerContent(
                text: sticky.text,
                detail: sticky.detail,
                style: sticky.style,
                actionLabel: sticky.actionLabel,
                onDismiss: { store.clearStickyBanner(profileID: profile.id) }
            )
        } else if let transient = transientBanner {
            bannerContent(
                text: transient.text,
                detail: nil,
                style: transient.style,
                actionLabel: nil,
                onDismiss: { transientBanner = nil }
            )
        }
    }

    @ViewBuilder
    private func bannerContent(
        text: String,
        detail: String?,
        style: HostStatusBanner.Style,
        actionLabel: String?,
        onDismiss: @escaping () -> Void
    ) -> some View {
        bannerContent(
            text: text,
            detail: detail,
            style: bannerStyle(for: style),
            actionLabel: actionLabel,
            onDismiss: onDismiss
        )
    }

    private enum BannerStyle {
        case success, paused, error

        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .paused: return "pause.circle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .success: return .green
            case .paused: return Color(red: 0.2, green: 0.45, blue: 0.85)
            case .error: return .red
            }
        }
    }

    private func bannerStyle(for style: HostStatusBanner.Style) -> BannerStyle {
        style == .paused ? .paused : .error
    }

    @ViewBuilder
    private func bannerContent(
        text: String,
        detail: String?,
        style: BannerStyle,
        actionLabel: String?,
        onDismiss: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: style.icon)
                Text(text).lineLimit(3)
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            if let detail {
                Text(detail).font(.caption).opacity(0.9)
            }
            if let action = actionLabel {
                HStack {
                    Spacer()
                    Button(action) { connect() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(10)
        .background(style.color)
    }

    private func connect() {
        guard CredentialStore.shared.hasPassword(for: profile.id) else {
            tab = .connection
            transientBanner = TransientBanner(
                text: "Set a password in the Connection tab first.",
                style: .error
            )
            return
        }
        let resuming = profile.stickyBanner?.style == .paused
        transientBanner = nil
        isConnecting = true
        Task {
            defer { isConnecting = false }
            let result = await SessionCoordinator.connect(
                profileID: profile.id,
                store: store,
                launcher: launcher,
                resumingPaused: resuming
            )
            if let updated = store.profile(id: profile.id) {
                profile = updated
            }
            if result.isError {
                transientBanner = TransientBanner(text: result.message, style: .error)
            } else {
                store.clearStickyBanner(profileID: profile.id)
                transientBanner = TransientBanner(
                    text: resuming ? "Resuming your paused session…" : result.message,
                    style: resuming ? .paused : .success
                )
            }
        }
    }
}
