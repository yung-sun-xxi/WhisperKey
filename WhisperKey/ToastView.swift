import SwiftUI
import ErrorToast

struct ToastView: View {
    static let contentWidth: CGFloat = 380
    /// Transparent room around the card for the close button, which overhangs the
    /// card's top-left corner the way the system's notification banners' does. The
    /// window is this much larger than the card on every side.
    static let margin: CGFloat = 10
    static let frameWidth: CGFloat = contentWidth + margin * 2
    private static let closeButtonDiameter: CGFloat = 20

    let content: ToastContent
    let onAction: () -> Void
    let onDismiss: () -> Void
    var showsDismissButton = true

    @State private var isHovered = false

    var body: some View {
        card
            .overlay(alignment: .topLeading) {
                if showsDismissButton {
                    closeButton
                        .offset(x: -Self.closeButtonDiameter / 2, y: -Self.closeButtonDiameter / 2)
                        .opacity(isHovered ? 1 : 0)
                        .animation(.easeOut(duration: 0.12), value: isHovered)
                }
            }
            .padding(Self.margin)
            .frame(width: Self.frameWidth, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }

    /// The system banner's close control: a small grey disc on the corner, shown only
    /// while the pointer is over the banner.
    private var closeButton: some View {
        Button(action: onDismiss) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                Circle()
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: Self.closeButtonDiameter, height: Self.closeButtonDiameter)
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }

    private var card: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.16))
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 7) {
                Text("WhisperKey")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(displayMessage)
                    .font(.system(.callout))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let title = actionTitle {
                    Button(title, action: onAction)
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                }
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Self.contentWidth, alignment: .leading)
        .background {
            VisualEffectBackground()
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
    }

    private var actionTitle: String? {
        switch content.action {
        case .retry: return "Retry"
        case .openSettings: return "Open Settings"
        case .none: return nil
        }
    }

    private var displayMessage: String {
        var message = content.message.trimmingCharacters(in: .whitespacesAndNewlines)
        while message.hasSuffix(".") {
            message.removeLast()
        }
        return message
    }

    private var iconName: String {
        switch content.style {
        case .warning:
            "exclamationmark.triangle.fill"
        case .information:
            "waveform.slash"
        }
    }

    private var iconColor: Color {
        switch content.style {
        case .warning:
            .orange
        case .information:
            .secondary
        }
    }
}
