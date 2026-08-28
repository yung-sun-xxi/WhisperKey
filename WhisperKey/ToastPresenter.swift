import AppKit
import Foundation
import ErrorToast

@MainActor
final class ToastPresenter {
    private static let lifeDuration: TimeInterval = 5.0
    private static let fadeDuration: TimeInterval = 0.15

    private var window: ToastWindow?
    private var dismissTask: Task<Void, Never>?
    private var anchorProvider: (() -> NSRect?)?

    func setAnchorProvider(_ provider: @escaping () -> NSRect?) {
        anchorProvider = provider
    }

    func show(content: ToastContent, onAction: @escaping () -> Void) {
        dismissTask?.cancel()
        dismissTask = nil
        if let existing = window {
            existing.close()
            window = nil
        }

        let anchor = anchorProvider?()

        let panel = ToastWindow(
            content: content,
            anchor: anchor,
            onAction: { [weak self] in
                guard let self else { return }
                self.dismiss(animated: true)
                onAction()
            },
            onDismiss: { [weak self] in
                self?.dismiss(animated: true)
            }
        )
        window = panel
        panel.fadeIn(duration: Self.fadeDuration, anchor: anchor)

        let panelRef = panel
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.lifeDuration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.window === panelRef else { return }
            self.dismiss(animated: true)
        }
    }

    func dismiss(animated: Bool) {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel = window else { return }
        window = nil
        if animated {
            panel.fadeOut(duration: Self.fadeDuration) {
                Task { @MainActor in panel.close() }
            }
        } else {
            panel.close()
        }
    }
}
