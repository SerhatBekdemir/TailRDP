import SwiftUI

/// Bottom status strip — fixed height for success (green), paused (blue), and error (red).
struct StatusBannerView: View {
    enum Style: Equatable {
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

    let text: String
    let style: Style
    var actionLabel: String?
    var onAction: (() -> Void)?
    var dismissable: Bool = true
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: style.icon)
                .font(.body)
                .frame(width: 18, height: 18)
            Text(text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionLabel, let onAction {
                Button(actionLabel, action: onAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.white)
            }
            if dismissable, let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .background(style.color)
    }
}

extension StatusBannerView.Style {
    init(hostStatus: HostStatusBanner.Style) {
        self = hostStatus == .paused ? .paused : .error
    }

    init(flash: HostFlashBanner.Style) {
        switch flash {
        case .success: self = .success
        case .paused: self = .paused
        case .error: self = .error
        }
    }
}
