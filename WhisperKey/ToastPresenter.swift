import AppKit
import Foundation
import ErrorToast
import os

@MainActor
final class ToastPresenter {
    private static let log = Logger(subsystem: "WhisperKey", category: "ToastPresenter")
    private static let transientLifeDuration: TimeInterval = 5.0
    private static let slideInDuration: TimeInterval = 0.22
    private static let slideOutDuration: TimeInterval = 0.18

    private var window: ToastWindow?
    private var content: ToastContent?
    private var dismissTask: Task<Void, Never>?

    func show(content: ToastContent, onAction: @escaping () -> Void) {
        dismissTask?.cancel()
        dismissTask = nil
        if let existing = window {
            existing.close()
            window = nil
        }

        let panel = ToastWindow(
            content: content,
            onAction: { [weak self] in
                guard let self else { return }
                self.dismiss(animated: true)
                onAction()
            },
            onDismiss: { [weak self] in
                self?.dismiss(animated: true)
            },
            onHoverChanged: { [weak self] isHovered in
                self?.hoverChanged(isHovered)
            }
        )
        window = panel
        self.content = content
        Self.log.info("show style=\(String(describing: content.style), privacy: .public) action=\(String(describing: content.action), privacy: .public) lifetime=\(String(describing: content.lifetime), privacy: .public) size=\(String(describing: panel.frame.size), privacy: .public)")
        panel.slideIn(duration: Self.slideInDuration)
        scheduleTransientDismissal()
    }

    func dismiss(animated: Bool) {
        dismissTask?.cancel()
        dismissTask = nil
        content = nil
        guard let panel = window else { return }
        window = nil
        if animated {
            panel.slideOut(duration: Self.slideOutDuration) {
                Task { @MainActor in panel.close() }
            }
        } else {
            panel.close()
        }
    }

    /// Only a `.transient` toast has a timer. A `.untilDismissed` one waits for the
    /// user: the close button, or its action.
    private func scheduleTransientDismissal() {
        dismissTask?.cancel()
        dismissTask = nil
        guard content?.lifetime == .transient, let panelRef = window else { return }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.transientLifeDuration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.window === panelRef else { return }
            self.dismiss(animated: true)
        }
    }

    /// The pointer over the toast holds it; leaving starts the full timer again, the way
    /// the system's own banners behave.
    private func hoverChanged(_ isHovered: Bool) {
        if isHovered {
            dismissTask?.cancel()
            dismissTask = nil
        } else {
            scheduleTransientDismissal()
        }
    }
}
