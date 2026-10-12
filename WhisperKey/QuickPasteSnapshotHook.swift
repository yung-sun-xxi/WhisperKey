#if DEBUG
import AppKit
import ClipboardHistoryStore
import os
import QuickPaste
import SettingsStore
import ThemeKit

/// Debug-only: renders the quick paste popup to PNG files, one per theme plus one empty
/// state, so its look can be compared without Screen Recording permission and without
/// holding the trigger.
///
///     open -a "WhisperKey Dev" --args -WKQuickPasteSnapshotDir /some/dir
///
/// The panel shows fixed, invented entries, never the clipboard history: these pictures
/// go into pull requests. It is built the way the controller builds it — the metrics read
/// once from the tokens, the second row highlighted — and placed off every screen, so
/// nothing appears on the desktop. For each theme the hook switches to it with the panel
/// open, logs the panel's frame before and after, and writes `quick-paste-<theme>.png`:
/// the panel's content view at @2x whatever the screen's scale. Then
/// `quick-paste-empty.png`, an empty history in Midnight. The blur behind the window does
/// not render this way; the shell's 95% fill does. The theme is put back and `done.txt`
/// lists what happened.
@MainActor
enum QuickPasteSnapshotHook {
    static let directoryArgument = "WKQuickPasteSnapshotDir"

    private static let log = Logger(subsystem: "WhisperKey", category: "QuickPasteSnapshot")

    /// Long enough for the panel to draw and a theme change to settle.
    private static let settleNanoseconds: UInt64 = 700_000_000

    /// The output resolution: pixels per point, @2x like the mockups.
    private static let pixelsPerPoint = 2

    /// Off every screen, so the panel draws without showing.
    private static let offscreenOrigin = NSPoint(x: -20_000, y: -20_000)

    /// The second row, so the selection is not on the edge of the list.
    private static let highlightedIndex = 1

    /// Invented entries, newest first: dictated and copied mixed, the first one long
    /// enough to be cut at the tail.
    private static let sampleEntries: [ClipboardEntry] = {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        return [
            ("Evening readiness check for the release: notes from the call, the open questions about the rollout plan and who owns each of them", ClipboardEntryOrigin.whisperKey),
            ("https://example.com/jobs/search?keywords=product+analyst", .otherApplication),
            ("Remind me to send the draft before Friday", .whisperKey),
            ("SELECT name, started_at FROM sessions WHERE ended_at IS NULL", .otherApplication),
            ("Thanks, that works for me. Talk tomorrow.", .otherApplication),
        ].map { ClipboardEntry(text: $0.0, capturedAt: now, origin: $0.1) }
    }()

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

        let panel = open(entries: sampleEntries)
        await settle()
        for theme in AppTheme.allCases {
            log.info("hook theme=\(theme.rawValue, privacy: .public)")
            lines.append(await switchTheme(to: theme, settings: settings, window: panel))
            lines.append(await shoot(panel, name: "quick-paste-\(theme.rawValue)", in: directory))
        }
        close(panel)

        lines.append(await switchTheme(to: .midnight, settings: settings, window: nil))
        let empty = open(entries: [])
        await settle()
        lines.append(await shoot(empty, name: "quick-paste-empty", in: directory))
        close(empty)

        settings.theme = originalTheme
        lines.append("restored theme=\(originalTheme.rawValue)")
        let report = lines.joined(separator: "\n") + "\n"
        try? report.write(to: directory.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
    }

    /// The panel as the controller builds it, off screen.
    private static func open(entries: [ClipboardEntry]) -> QuickPastePanel {
        let metrics = ThemeTokensSource.shared.tokens.quickPasteMetrics
        let panel = QuickPastePanel(content: QuickPasteContent(entries: entries), metrics: metrics)
        if !entries.isEmpty {
            panel.setHighlightedIndex(highlightedIndex)
        }
        panel.setFrameOrigin(offscreenOrigin)
        panel.orderFrontRegardless()
        return panel
    }

    private static func close(_ panel: QuickPastePanel) {
        panel.orderOut(nil)
        panel.close()
    }

    /// Switches the theme, with the panel open when there is one, and reports whether the
    /// panel's frame moved.
    private static func switchTheme(to theme: AppTheme, settings: SettingsStore, window: NSWindow?) async -> String {
        let before = window?.frame
        settings.theme = theme
        await settle()
        guard let window, let before else { return "switch to \(theme.rawValue)" }
        let after = window.frame
        let line = "switch to \(theme.rawValue): size \(Int(before.width))x\(Int(before.height)) -> \(Int(after.width))x\(Int(after.height)) \(before == after ? "kept" : "CHANGED")"
        log.info("hook \(line, privacy: .public)")
        return line
    }

    private static func shoot(_ window: NSWindow, name: String, in directory: URL) async -> String {
        // A hosting view hands `cacheDisplay` what it drew for the previous request, so
        // the first render only asks SwiftUI to draw the current state; the second one
        // is kept.
        _ = png(of: window)
        await settle()
        guard let png = png(of: window) else {
            return "error: \(name): could not render the panel"
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
