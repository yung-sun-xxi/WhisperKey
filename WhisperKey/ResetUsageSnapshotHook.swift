#if DEBUG
import AppKit
import os
import SettingsStore
import ThemeKit
import TranscriptionProvider
import UsageStatsStore

/// Debug-only: renders the Reset usage window and its confirmation alert to PNG files,
/// each theme, so the look can be compared without Screen Recording permission.
///
///     open -a "WhisperKey Dev" --args -WKResetUsageSnapshotDir /some/dir
///
/// For each theme the hook opens the window with the model in use and one more ticked
/// (`reset-usage-<theme>.png`), then with nothing ticked (`reset-usage-<theme>-empty.png`),
/// and renders the alert for two models and for one (`reset-usage-alert-<theme>.png`,
/// `reset-usage-alert-<theme>-one.png`). With the window open it also switches to the
/// other theme, logging the frame before and after and every move or resize on the way.
/// Nothing is reset: the window's Reset only logs. The theme is put back, and `done.txt`
/// lists what happened.
@MainActor
enum ResetUsageSnapshotHook {
    static let directoryArgument = "WKResetUsageSnapshotDir"

    private static let log = Logger(subsystem: "WhisperKey", category: "ResetUsageSnapshot")

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

        let openAI = OpenAIProvider.Model.allCases.map(\.rawValue)
        let current = ProviderModelKey(providerID: TranscriptionProviderID.openai.rawValue, modelID: openAI.first ?? "")
        let other = ProviderModelKey(providerID: TranscriptionProviderID.openai.rawValue, modelID: openAI.dropFirst().first ?? "")
        let states: [(selection: Set<ProviderModelKey>, suffix: String)] = [
            ([current, other], ""),
            ([], "-empty"),
        ]

        for theme in AppTheme.allCases {
            settings.theme = theme
            await settle()
            for state in states {
                UsageResetWindowController.show(
                    currentKey: current,
                    initialSelection: state.selection,
                    parent: nil,
                    onReset: { keys in log.info("hook reset tapped for \(keys.count) models") }
                )
                await settle()
                guard let window = UsageResetWindowController.openWindow else {
                    lines.append("error: no reset window")
                    continue
                }
                if state.suffix.isEmpty, let other = AppTheme.allCases.first(where: { $0 != theme }) {
                    lines += await switchTheme(to: other, settings: settings, window: window)
                    lines += await switchTheme(to: theme, settings: settings, window: window)
                }
                lines.append(await shoot(window, name: "reset-usage-\(theme.rawValue)\(state.suffix)", in: directory))
                UsageResetWindowController.hide()
                await settle()
            }
            for (count, suffix) in [(2, ""), (1, "-one")] {
                lines.append(renderAlert(count: count, theme: theme, name: "reset-usage-alert-\(theme.rawValue)\(suffix)", in: directory))
            }
        }

        settings.theme = originalTheme
        lines.append("restored theme=\(originalTheme.rawValue); window closed")
        let report = lines.joined(separator: "\n") + "\n"
        try? report.write(to: directory.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
    }

    /// The alert's own view, drawn in the theme's appearance. macOS draws the real one on
    /// a sheet; this is the same `NSAlert`, laid out and rendered off screen.
    private static func renderAlert(count: Int, theme: AppTheme, name: String, in directory: URL) -> String {
        let alert = UsageResetConfirmation.makeAlert(prompt: UsageResetPrompt(modelCount: count))
        alert.window.appearance = ThemeTokensSource.shared.tokens.windowAppearance.nsAppearance
        alert.layout()
        guard let frameView = alert.window.contentView?.superview,
              let png = png(of: frameView)
        else { return "error: \(name): could not render the alert" }

        let url = directory.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
            return "wrote \(url.lastPathComponent) title=\(alert.messageText)"
        } catch {
            return "error: \(name): \(error.localizedDescription)"
        }
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
        return png(of: frameView)
    }

    private static func png(of frameView: NSView) -> Data? {
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
