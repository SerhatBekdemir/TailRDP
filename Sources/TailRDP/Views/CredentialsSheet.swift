import SwiftUI

/// One-time (or on-demand) username + password entry for a host.
struct CredentialsSheet: View {
    let hostName: String
    let message: String?
    @Binding var username: String
    @Binding var password: String
    var connectLabel: String = "Save & Connect"
    var onConfirm: () -> Void
    var onCancel: () -> Void

    @FocusState private var focused: Field?

    private enum Field { case username, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in to \(hostName)")
                .font(.title2.bold())

            if let message, !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Enter your remote desktop username and password once. TailRDP stores them securely on this Mac and won't ask again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .focused($focused, equals: .username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focused, equals: .password)
            }
            .formStyle(.grouped)
            .frame(minWidth: 360, minHeight: 160)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(connectLabel, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConfirm)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { focused = username.isEmpty ? .username : .password }
    }

    private var canConfirm: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }
}
