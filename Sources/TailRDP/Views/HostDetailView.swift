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
    @State private var isConnecting = false
    @State private var isEndingRemote = false
    @State private var sessionPickerIDs: [String]?
    @State private var showSessionPicker = false
    @State private var pendingResuming = false
    @State private var showCredentialsSheet = false
    @State private var credentialsMessage: String?
    @State private var sheetUsername = ""
    @State private var sheetPassword = ""
    @State private var connectAfterCredentials = false
    @State private var pauseClearTask: Task<Void, Never>?

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
        .onChange(of: profile) { _, _ in store.scheduleSave() }
        .onChange(of: launcher.isActive(profile.id)) { _, active in
            pauseClearTask?.cancel()
            pauseClearTask = nil
            if active {
                store.clearFlashBanner(profileID: profile.id)
                pauseClearTask = Task {
                    try? await Task.sleep(for: .seconds(SessionHealth.establishedSessionThreshold))
                    guard !Task.isCancelled, launcher.isActive(profile.id) else { return }
                    store.clearPausedSession(profileID: profile.id)
                    syncProfileFromStore()
                }
            }
        }
        .safeAreaInset(edge: .bottom) { bannerView }
        .sheet(isPresented: $showSessionPicker) {
            if let ids = sessionPickerIDs {
                RemoteSessionPickerSheet(
                    sessionIDs: ids,
                    onSelect: { sid in
                        showSessionPicker = false
                        sessionPickerIDs = nil
                        performConnect(resuming: pendingResuming, keepSessionID: sid)
                    },
                    onCancel: {
                        showSessionPicker = false
                        sessionPickerIDs = nil
                        isConnecting = false
                    }
                )
            }
        }
        .sheet(isPresented: $showCredentialsSheet) {
            CredentialsSheet(
                hostName: profile.displayName,
                message: credentialsMessage,
                username: $sheetUsername,
                password: $sheetPassword,
                connectLabel: connectAfterCredentials ? "Save & Connect" : "Save",
                onConfirm: confirmCredentials,
                onCancel: cancelCredentials
            )
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .connection:
            ConnectionSettingsView(profile: $profile) {
                presentCredentials(message: nil, connectAfter: false)
            }
        case .files:
            FileTransferView(profile: $profile)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Image(systemName: profile.os == "windows" ? "pc" : "desktopcomputer")
                .font(.largeTitle)
                .foregroundStyle(profile.online ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName).font(.title2).bold()
                HStack(spacing: 4) {
                    Text("\(profile.address.isEmpty ? "no address" : profile.address):\(profile.rdpPort)  ·  \(profile.rdpUsername)")
                    if !profile.online, !profile.address.isEmpty {
                        Image(systemName: "wifi.slash")
                            .foregroundStyle(.orange)
                            .help("Offline — connecting via saved address")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if profile.usesSafeFallback {
                    Text("Using safe fallback until a session succeeds")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if let last = profile.lastWorking {
                    Text("Last good: \(last.settings.connectSummary)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
                } else if let actionLabel = profile.stickyBanner?.actionLabel, !profile.stickyBanner!.needsCredentials {
                    Label(actionLabel, systemImage: "play.fill")
                        .frame(minWidth: 90)
                } else {
                    Label("Connect", systemImage: "play.fill").frame(minWidth: 90)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(profile.address.isEmpty || isConnecting || isEndingRemote)
            .help(connectHelp)
        }
    }

    private var connectHelp: String {
        if !profile.online, !profile.address.isEmpty {
            return "Tailscale reports offline — connect anyway using the saved address"
        }
        if !profile.online { return "Set an address to connect" }
        if profile.stickyBanner?.style == .paused { return "Resume your paused session" }
        if profile.stickyBanner?.needsCredentials == true { return "Update your saved sign-in" }
        if profile.stickyBanner?.style == .error { return "Reconnect after the last problem" }
        if profile.lastWorking != nil { return "Connect using your last good settings" }
        return "Connect"
    }

    @ViewBuilder private var bannerView: some View {
        Group {
            if let sticky = profile.stickyBanner {
                if sticky.style == .paused {
                    StatusBannerView(
                        text: stickyDisplayText(sticky),
                        style: .paused,
                        actionLabel: isEndingRemote ? "Ending…" : "Disconnect",
                        onAction: isEndingRemote ? nil : disconnectRemoteSession,
                        dismissable: false
                    )
                } else {
                    StatusBannerView(
                        text: stickyDisplayText(sticky),
                        style: StatusBannerView.Style(hostStatus: sticky.style),
                        actionLabel: sticky.actionLabel,
                        onAction: sticky.needsCredentials
                            ? { presentCredentials(message: sticky.text, connectAfter: true) }
                            : (sticky.actionLabel != nil ? connect : nil),
                        onDismiss: { store.clearStickyBanner(profileID: profile.id) }
                    )
                }
            } else if let flash = store.flashBanner(for: profile.id) {
                StatusBannerView(
                    text: flash.text,
                    style: StatusBannerView.Style(flash: flash.style),
                    onDismiss: { store.clearFlashBanner(profileID: profile.id) }
                )
            }
        }
        .animation(.easeOut(duration: 0.35), value: store.flashBanner(for: profile.id)?.text)
        .animation(.easeOut(duration: 0.35), value: profile.stickyBanner?.text)
    }

    private func stickyDisplayText(_ sticky: HostStatusBanner) -> String {
        guard let detail = sticky.detail, !detail.isEmpty else { return sticky.text }
        return "\(sticky.text) \(detail)"
    }

    private func disconnectRemoteSession() {
        isEndingRemote = true
        Task {
            defer { isEndingRemote = false }
            let result = await SessionCoordinator.disconnectRemotePausedSession(
                profileID: profile.id,
                store: store
            )
            syncProfileFromStore()
            if result.isError {
                store.setFlashBanner(
                    profileID: profile.id,
                    banner: HostFlashBanner(text: result.message, style: .error)
                )
            }
        }
    }

    /// Pull store-side mutations (banners, health) back into the bound profile.
    private func syncProfileFromStore() {
        if let updated = store.profile(id: profile.id) {
            profile = updated
        }
    }

    private func connect() {
        if profile.stickyBanner?.needsCredentials == true {
            presentCredentials(message: profile.stickyBanner?.text, connectAfter: true)
            return
        }
        guard hasSavedCredentials else {
            presentCredentials(message: nil, connectAfter: true)
            return
        }
        proceedToConnect()
    }

    private var hasSavedCredentials: Bool {
        CredentialStore.shared.hasPassword(for: profile.id)
            && !profile.rdpUsernameForConnect.isEmpty
    }

    private func presentCredentials(message: String?, connectAfter: Bool) {
        credentialsMessage = message
        connectAfterCredentials = connectAfter
        sheetUsername = profile.rdpUsername
        sheetPassword = ""
        showCredentialsSheet = true
    }

    private func confirmCredentials() {
        var p = profile
        p.rdpUsername = sheetUsername
        p.normalizeCredentials()
        profile = p
        store.update(id: profile.id, immediate: true) { stored in
            stored.rdpUsername = p.rdpUsername
            stored.sshUsername = p.sshUsername
            if stored.stickyBanner?.needsCredentials == true {
                stored.sessionHealth = SessionHealth()
                stored.stickyBanner = nil
            }
        }
        guard CredentialStore.shared.set(sheetPassword, for: profile.id) else {
            credentialsMessage = "Could not save sign-in."
            return
        }
        showCredentialsSheet = false
        credentialsMessage = nil
        syncProfileFromStore()
        if connectAfterCredentials {
            proceedToConnect()
        }
    }

    private func cancelCredentials() {
        showCredentialsSheet = false
        credentialsMessage = nil
        connectAfterCredentials = false
        isConnecting = false
    }

    private func proceedToConnect() {
        let resuming = profile.stickyBanner?.style == .paused
            || profile.health.lastEndKind == .paused

        if resuming, profile.isLinux {
            pendingResuming = true
            isConnecting = true
            let p = profile
            Task {
                let report = await Task.detached {
                    RemoteDisplayRecovery.inspect(p)
                }.value
                if case .success(let r) = report, r.remoteSessionIDs.count > 1 {
                    sessionPickerIDs = r.remoteSessionIDs
                    showSessionPicker = true
                } else {
                    performConnect(resuming: true, keepSessionID: nil)
                }
            }
            return
        }

        performConnect(resuming: resuming, keepSessionID: nil)
    }

    private func performConnect(resuming: Bool, keepSessionID: String?) {
        store.clearFlashBanner(profileID: profile.id)
        isConnecting = true
        let p = profile
        Task {
            defer { isConnecting = false }
            if let keepSessionID {
                _ = await Task.detached {
                    RemoteDisplayRecovery.terminateRemoteSessions(p, exceptSessionID: keepSessionID)
                }.value
            }
            let result = await SessionCoordinator.connect(
                profileID: profile.id,
                store: store,
                launcher: launcher,
                resumingPaused: resuming
            )
            syncProfileFromStore()
            if result.isError {
                if result.message.contains("No saved sign-in") {
                    presentCredentials(message: nil, connectAfter: true)
                } else {
                    store.setFlashBanner(
                        profileID: profile.id,
                        banner: HostFlashBanner(text: result.message, style: .error)
                    )
                }
            } else {
                store.setFlashBanner(
                    profileID: profile.id,
                    banner: HostFlashBanner(
                        text: resuming ? "Resuming your paused session…" : result.message,
                        style: resuming ? .paused : .success
                    )
                )
            }
        }
    }
}
