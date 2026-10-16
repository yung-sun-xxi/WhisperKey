#if DEBUG
import AppKit
import Combine
import os
import SettingsStore
import ThemeKit

/// Debug-only: renders the welcome window to PNG files, each theme, so the look can be
/// compared without Screen Recording permission.
///
///     open -a "WhisperKey Dev" --args -WKWelcomeSnapshotDir /some/dir
///
/// For each theme the hook builds the app's own welcome window
/// (`WelcomeWindowController.makeWindow`) with actions that do nothing, so the welcome
/// is neither completed nor marked shown, and writes `welcome-<theme>.png`. With the
/// window open it switches to the other theme, logging the frame before and after and
/// every move or resize on the way, and writes `welcome-<theme>-switched-to-<other>.png`.
/// The theme is put back, and `done.txt` lists what happened.
@MainActor
enum WelcomeSnapshotHook {
    static let directoryArgument = "WKWelcomeSnapshotDir"

    private static let log = Logger(subsystem: "WhisperKey", category: "WelcomeSnapshot")

    /// Long enough for the window to draw and a theme change to settle.
    private static let settleNanoseconds: UInt64 = 700_000_000

    /// The output resolution: pixels per point, @2x like the mockups.
    private static let pixelsPerPoint = 2

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

        for theme in AppTheme.allCases {
            settings.theme = theme
            await settle()
            let window = WelcomeWindowController.makeWindow(goToSettings: {}, doLater: {})
            let follower = ThemedSurfaceWindow.follow(ThemeTokensSource.shared, window: window)
            window.center()
            lines.append("\(theme.rawValue): content \(describe(window.contentLayoutRect))")
            // Shoot first: a switch is the riskiest step, and the shot must not wait on it.
            lines.append(await shoot(window, name: "welcome-\(theme.rawValue)", in: directory))
            if let other = AppTheme.allCases.first(where: { $0 != theme }) {
                lines += await switchTheme(to: other, settings: settings, window: window)
                lines.append(await shoot(window, name: "welcome-\(theme.rawValue)-switched-to-\(other.rawValue)", in: directory))
                lines += await switchTheme(to: theme, settings: settings, window: window)
            }
            follower.cancel()
            window.close()
            await settle()
        }

        settings.theme = originalTheme
        lines.append("restored theme=\(originalTheme.rawValue); window closed")
        let report = lines.joined(separator: "\n") + "\n"
        try? report.write(to: directory.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
    }

    /// Switches the theme with the window open and reports its frame and its close
    /// button's frame before and after, plus every frame it passed through on the way.
    private static func switchTheme(to theme: AppTheme, settings: SettingsStore, window: NSWindow) async -> [String] {
        guard settings.theme != theme else {
            return ["theme \(theme.rawValue) already; frame \(describe(window.frame))"]
        }
        let before = window.frame
        let closeBefore = closeButtonFrame(in: window)
        var steps: [NSRect] = []
        let center = NotificationCenter.default
        let observers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
            center.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { steps.append(window.frame) }
            }
        }
        settings.theme = theme
        await settle()
        observers.forEach(center.removeObserver)

        let after = window.frame
        let closeAfter = closeButtonFrame(in: window)
        var lines = [
            "switch to \(theme.rawValue): before \(describe(before)) after \(describe(after)) \(before == after ? "kept" : "CHANGED")",
            "  close button: before \(describe(closeBefore)) after \(describe(closeAfter)) \(closeBefore == closeAfter ? "same" : "MOVED")",
        ]
        lines += steps.map { "  step \(describe($0))" }
        for line in lines {
            log.info("hook \(line, privacy: .public)")
        }
        return lines
    }

    private static func closeButtonFrame(in window: NSWindow) -> NSRect {
        guard let button = window.standardWindowButton(.closeButton) else { return .zero }
        return button.convert(button.bounds, to: nil)
    }

    private static func describe(_ frame: NSRect) -> String {
        "origin=\(Int(frame.minX)),\(Int(frame.minY)) size=\(Int(frame.width))x\(Int(frame.height))"
    }

    private static func shoot(_ window: NSWindow, name: String, in directory: URL) async -> String {
        // The titlebar and controls draw in their active state only while the app is
        // active and the window key.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await settle()
        // A hosting view hands `cacheDisplay` what it drew for the previous request, so
        // the first render only asks SwiftUI to draw the current state; the second one
        // is kept.
        _ = pngOfFrameView(of: window)
        await settle()
        guard let png = pngOfFrameView(of: window) else {
            return "error: \(name): could not render the window"
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

    /// The frame view holds the titlebar and the content, so the shot is the whole window.
    private static func pngOfFrameView(of window: NSWindow) -> Data? {
        guard let frameView = window.contentView?.superview else { return nil }
        frameView.layoutSubtreeIfNeeded()
        let bounds = frameView.bounds
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
        frameView.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func settle() async {
        try? await Task.sleep(nanoseconds: settleNanoseconds)
    }
}
#endif
