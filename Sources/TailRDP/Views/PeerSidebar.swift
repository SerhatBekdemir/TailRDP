import SwiftUI

struct PeerSidebar: View {
    @Binding var selection: String?
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var tailscale: TailscaleService
    @EnvironmentObject var launcher: RDPLauncher

    @AppStorage(AppSettingsKey.showOffline) private var showOffline = false
    @State private var showAddHost = false
    @State private var hostToDelete: HostProfile?
    @State private var addName = ""
    @State private var addAddress = ""
    @State private var addOS = "linux"
    @State private var addError: String?

    private var visible: [HostProfile] { store.visibleProfiles }

    var body: some View {
        List(selection: $selection) {
            Section("Tailnet Machines") {
                ForEach(visible) { profile in
                    row(profile).tag(profile.id)
                        .contextMenu {
                            Button("Delete Host…", role: .destructive) {
                                hostToDelete = profile
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    addName = ""
                    addAddress = ""
                    addOS = "linux"
                    addError = nil
                    showAddHost = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add host manually")
            }
            ToolbarItem {
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Settings (⌘,)")
            }
            ToolbarItem {
                Button { tailscale.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh tailnet (⌘R)")
                .disabled(tailscale.isRefreshing)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let err = tailscale.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if tailscale.isRefreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning tailnet…").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if !showOffline, store.profiles.contains(where: { !$0.online }) {
                Text("\(store.profiles.filter { !$0.online }.count) offline hidden")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showAddHost) { addHostSheet }
        .alert("Delete Host?", isPresented: Binding(
            get: { hostToDelete != nil },
            set: { if !$0 { hostToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { hostToDelete = nil }
            Button("Delete", role: .destructive) {
                if let id = hostToDelete?.id {
                    if selection == id { selection = nil }
                    store.remove(id: id)
                }
                hostToDelete = nil
            }
        } message: {
            if let h = hostToDelete {
                Text("Remove \"\(h.displayName)\" from TailRDP? Saved passwords are deleted.")
            }
        }
    }

    private var addHostSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Host").font(.headline)
            TextField("Display name", text: $addName)
            TextField("Address (IP or hostname)", text: $addAddress)
            Picker("OS", selection: $addOS) {
                Text("Linux").tag("linux")
                Text("Windows").tag("windows")
                Text("macOS").tag("macOS")
                Text("Other").tag("other")
            }
            if let addError {
                Text(addError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { showAddHost = false }
                Button("Add") {
                    if let err = store.addManualHost(displayName: addName, address: addAddress, os: addOS) {
                        addError = err
                    } else {
                        selection = addName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        showAddHost = false
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func row(_ profile: HostProfile) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(profile.online ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName).fontWeight(.medium)
                Text(profile.address.isEmpty ? profile.os : "\(profile.address) · \(profile.os)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if launcher.isActive(profile.id) {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.green)
                    .help("Session running")
            } else if profile.hasPausedSession {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(Color(red: 0.2, green: 0.45, blue: 0.85))
                    .help("Session paused — connect to resume")
            } else if profile.stickyBanner != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .help("Needs reconnect")
            }
        }
        .padding(.vertical, 2)
    }
}
