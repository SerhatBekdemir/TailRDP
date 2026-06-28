import SwiftUI

/// Shown when multiple remote Wayland sessions exist — pick which to resume.
struct RemoteSessionPickerSheet: View {
    let sessionIDs: [String]
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Multiple Remote Sessions")
                .font(.title2.bold())
            Text("Several remote desktop sessions are active on this host. Choose which session to resume — the others will be ended.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(sessionIDs, id: \.self) { sid in
                Button {
                    onSelect(sid)
                } label: {
                    HStack {
                        Image(systemName: "display")
                        Text("Session \(sid)")
                        Spacer()
                        Text("Resume")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 120, maxHeight: 220)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
