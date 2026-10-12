import SwiftUI
import ErrorToast
import ThemeKit

/// The toast's content as the app words it, drawn by `ThemedToastView` (#167): the glyph
/// chosen by the style, the message without its final full stop, the action's title. The
/// close disc shows while the pointer is over the toast.
struct ToastView: View {
    let content: ToastContent
    let onAction: () -> Void
    let onDismiss: () -> Void
    var showsDismissButton = true

    @State private var isHovered: Bool

    /// `startsHovered` shows the close disc from the start, for the Debug build's
    /// snapshot hook; the pointer moves it as usual afterwards.
    init(
        content: ToastContent,
        onAction: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        startsHovered: Bool = false
    ) {
        self.content = content
        self.onAction = onAction
        self.onDismiss = onDismiss
        _isHovered = State(initialValue: startsHovered)
    }

    var body: some View {
        ThemedToastView(
            glyph: glyph,
            message: displayMessage,
            actionTitle: actionTitle,
            showsCloseButton: showsDismissButton,
            isCloseButtonVisible: isHovered,
            onAction: onAction,
            onDismiss: onDismiss
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
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

    /// The style alone chooses the glyph: the microphone for a warning, crossed out for
    /// information.
    private var glyph: ThemedToastView.Glyph {
        switch content.style {
        case .warning: .microphone
        case .information: .microphoneSlash
        }
    }
}
