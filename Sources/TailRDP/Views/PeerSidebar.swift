import SwiftUI

struct PeerSidebar: View {
    @Binding var selection: String?
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var tailscale: TailscaleService
    @EnvironmentObject var launcher: RDPLauncher

    var body: some View {
        List(selection: $selection) {
            Section("Tailnet Machines") {
                ForEach(store.profiles) { profile in
                    row(profile).tag(profile.id)
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Tailscale settings (⌘,)")
            }
            ToolbarItem {
                Button {
                    tailscale.refresh()
                } label: {
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
            }
        }
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
            }
        }
        .padding(.vertical, 2)
    }
}
