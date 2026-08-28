import SwiftUI
import ErrorToast

struct ToastView: View {
    static let contentWidth: CGFloat = 380

    let content: ToastContent
    let pointerCenterX: CGFloat?
    let onAction: () -> Void
    let onDismiss: () -> Void
    var showsDismissButton = true

    var body: some View {
        VStack(spacing: -1) {
            if let pointerCenterX {
                ZStack(alignment: .leading) {
                    ToastPointer()
                        .frame(width: 20, height: 9)
                        .offset(x: pointerCenterX - 10)
                }
                .frame(width: Self.contentWidth, height: 9)
            }

            card
        }
        .frame(width: Self.contentWidth, alignment: .leading)
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

            if showsDismissButton {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
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

private struct ToastPointer: View {
    var body: some View {
        ToastPointerShape()
            .fill(.clear)
            .background {
                VisualEffectBackground()
            }
            .clipShape(ToastPointerShape())
    }
}

private struct ToastPointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.minX + 4, y: rect.maxY),
            control2: CGPoint(x: rect.midX - 4, y: rect.minY + 2)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control1: CGPoint(x: rect.midX + 4, y: rect.minY + 2),
            control2: CGPoint(x: rect.maxX - 4, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_: NSVisualEffectView, context: Context) {}
}
