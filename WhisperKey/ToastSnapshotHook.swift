#if DEBUG
import AppKit
import ErrorToast
import os
import SettingsStore
import ThemeKit

/// Debug-only: renders the toast to PNG files, the five toasts of the design's mockup in
/// each theme plus one with the close disc showing, so their look can be compared without
/// Screen Recording permission and without making anything fail.
///
///     open -a "WhisperKey Dev" --args -WKToastSnapshotDir /some/dir
///
/// The toasts carry fixed, invented content: the mockup's texts, never a real error. They
/// are built as `ToastPresenter` builds them and placed off every screen, so nothing
/// appears on the desktop. With all five open, the hook switches to each theme, logs
/// every window's frame before and after, and writes `toast-<theme>-<n>.png`: the window's
/// content view, margin included, at @2x whatever the screen's scale. Then
/// `toast-midnight-hovered.png`, the first toast in Midnight with its close disc shown.
/// The blur behind the window does not render this way; the shell's 95% fill does. The
/// theme is put back and `done.txt` lists what happened.
@MainActor
enum ToastSnapshotHook {
    static let directoryArgument = "WKToastSnapshotDir"

    private static let log = Logger(subsystem: "WhisperKey", category: "ToastSnapshot")

    /// Long enough for the windows to draw and a theme change to settle.
    private static let settleNanoseconds: UInt64 = 700_000_000

    /// The output resolution: pixels per point, @2x like the mockups.
    private static let pixelsPerPoint = 2

    /// Off every screen, so the windows draw without showing.
    private static let offscreenOrigin = NSPoint(x: -20_000, y: -20_000)

    /// The mockup's five toasts (`docs/design/mockups/toast.png`), top to bottom, with
    /// the final full stop where the app's message has one: the toast drops it.
    private static let samples: [ToastContent] = [
        ToastContent(
            message: "No response from OpenAI within 30 seconds. It may be your network or OpenAI; no response arrived, so WhisperKey cannot tell which.",
            action: .retry,
            style: .warning
        ),
        ToastContent(message: "Microphone access is required to record", action: .openSettings, style: .warning),
        ToastContent(message: "No speech detected", action: .none, style: .information),
        ToastContent(
            message: "Can’t paste here right now — macOS is blocking input from other apps. Try again in a moment, or paste into a different field.",
            action: .none,
            style: .warning,
            lifetime: .transient
        ),
        ToastContent(
            message: "Couldn’t copy the entry, so nothing was pasted. Try again.",
            action: .none,
            style: .warning,
            lifetime: .transient
        ),
    ]

    private static var started = false

    static func startIfRequested(settings: SettingsStore) {
        guard !started,
              let path = UserDefaults.standard.string(forKey: directoryArgument),
              !path.isEmpty
        else { return }

        started = true
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        Task { @MainActor in
            await run(settings: settings, directory: directory)
        }
    }

    private static func run(settings: SettingsStore, directory: URL) async {
        var lines: [String] = []
        let originalTheme = settings.theme
        ThemeTokensSource.shared.follow(settings)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            lines.append("error: cannot create \(directory.path): \(error.localizedDescription)")
        }

        // Let the launch finish its own window work first.
        await settle()
        await settle()

        let windows = samples.map { open($0, hovered: false) }
        await settle()
        for theme in AppTheme.allCases {
            log.info("hook theme=\(theme.rawValue, privacy: .public)")
            lines += await switchTheme(to: theme, settings: settings, windows: windows)
            for (index, window) in windows.enumerated() {
                lines.append(await shoot(window, name: "toast-\(theme.rawValue)-\(index + 1)", in: directory))
            }
        }
        windows.forEach(close)

        lines += await switchTheme(to: .midnight, settings: settings, windows: [])
        let hovered = open(samples[0], hovered: true)
        await settle()
        lines.append(await shoot(hovered, name: "toast-midnight-hovered", in: directory))
        close(hovered)

        settings.theme = originalTheme
        lines.append("restored theme=\(originalTheme.rawValue)")
        let report = lines.joined(separator: "\n") + "\n"
        try? report.write(to: directory.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
    }

    /// The window as `ToastPresenter` builds it, off screen and doing nothing when used.
    private static func open(_ content: ToastContent, hovered: Bool) -> ToastWindow {
        let window = ToastWindow(
            content: content,
            onAction: {},
            onDismiss: {},
            onHoverChanged: { _ in },
            startsHovered: hovered
        )
        window.setFrameOrigin(offscreenOrigin)
        window.orderFrontRegardless()
        return window
    }

    private static func close(_ window: ToastWindow) {
        window.orderOut(nil)
        window.close()
    }

    /// Switches the theme with the windows open and reports, for each, whether its frame
    /// moved.
    private static func switchTheme(to theme: AppTheme, settings: SettingsStore, windows: [NSWindow]) async -> [String] {
        let before = windows.map(\.frame)
        settings.theme = theme
        await settle()
        guard !windows.isEmpty else { return ["switch to \(theme.rawValue)"] }
        return zip(windows, before).enumerated().map { index, pair in
            let (window, before) = pair
            let after = window.frame
            let line = "switch to \(theme.rawValue): toast \(index + 1) frame \(describe(before)) -> \(describe(after)) \(before == after ? "kept" : "CHANGED")"
            log.info("hook \(line, privacy: .public)")
            return line
        }
    }

    private static func describe(_ frame: NSRect) -> String {
        "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
    }

    private static func shoot(_ window: NSWindow, name: String, in directory: URL) async -> String {
        // A hosting view hands `cacheDisplay` what it drew for the previous request, so
        // the first render only asks SwiftUI to draw the current state; the second one
        // is kept.
        _ = png(of: window)
        await settle()
        guard let png = png(of: window) else {
            return "error: \(name): could not render the toast"
        }

        log.info("hook shot=\(name, privacy: .public) frame=\(Int(window.frame.width), privacy: .public)x\(Int(window.frame.height), privacy: .public)")
        let url = directory.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
            return "wrote \(url.lastPathComponent) \(Int(window.frame.width))x\(Int(window.frame.height))pt"
        } catch {
            return "error: \(name): \(error.localizedDescription)"
        }
    }

    private static func png(of window: NSWindow) -> Data? {
        guard let view = window.contentView else { return nil }

        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width) * pixelsPerPoint,
            pixelsHigh: Int(bounds.height) * pixelsPerPoint,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func settle() async {
        try? await Task.sleep(nanoseconds: settleNanoseconds)
    }
}
#endif
