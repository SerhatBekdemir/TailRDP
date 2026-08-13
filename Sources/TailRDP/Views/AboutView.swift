import SwiftUI

struct AboutView: View {
    @EnvironmentObject var tailscale: TailscaleService
    @EnvironmentObject var launcher: RDPLauncher

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer.and.arrow.down")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text(AppIdentity.displayName).font(.title).bold()
            Text("Version \(AppIdentity.version)").foregroundStyle(.secondary)
            Text("Bundle ID: app.tailrdp")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Divider().padding(.horizontal, 40)
            VStack(alignment: .leading, spacing: 6) {
                depLine("Tailscale", DependencyChecker.tailscale(
                    override: UserDefaults.standard.string(forKey: AppSettingsKey.tailscaleBinaryPath)
                ).path)
                depLine("FreeRDP", launcher.binaryPath)
                depLine("SSH", DependencyChecker.sshFound() ? "/usr/bin/ssh" : nil)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 40)
            Text("See USER_GUIDE.md in the repository for setup help.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 360)
    }

    private func depLine(_ name: String, _ path: String?) -> some View {
        HStack {
            Image(systemName: path != nil ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(path != nil ? .green : .secondary)
            Text(name)
            Spacer()
            Text(path ?? "not found")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
