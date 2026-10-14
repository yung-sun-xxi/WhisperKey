#if DEBUG
import AppKit
import HistoryStore
import os
import SettingsStore
import ThemeKit

/// Debug-only: renders the history entry reader to PNG files, each theme for a
/// recognised entry and for a failed one with Retry, so its look can be compared without
/// Screen Recording permission.
///
///     open -a "WhisperKey Dev" --args -WKHistoryReaderSnapshotDir /some/dir
///
/// The reader shows entries of a throwaway store in a temporary folder: an invented
/// recognised entry in English, and a "No speech detected" one whose audio is kept, so it
/// offers Retry; never the user's history. For each entry and each theme the hook
/// switches to the theme with the reader open, logging the frame before and after and
/// every move or resize on the way, and writes `history-reader-<theme>.png` (recognised)
/// or `history-reader-<theme>-failed.png`: the window's frame view, titlebar included, at
/// @2x whatever the screen's scale. Retry in the shot does nothing but log. The theme is
/// put back, the readers close, the temporary folder goes, and `done.txt` lists what
/// happened.
@MainActor
enum HistoryReaderSnapshotHook {
    static let directoryArgument = "WKHistoryReaderSnapshotDir"

    private static let log = Logger(subsystem: "WhisperKey", category: "HistoryReaderSnapshot")

    /// Long enough for the window to draw and a theme change to settle.
    private static let settleNanoseconds: UInt64 = 700_000_000

    /// The output resolution: pixels per point, @2x like the mockups.
    private static let pixelsPerPoint = 2

    /// An invented recognised entry, long enough to wrap.
    private static let sampleText = "Wait, why do we bring up sponsorship straight away? What if they are ready to hire on a B2B contract? I don't get it, to be honest. Let's keep that part for the second call."

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

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperKeyHistoryReaderSnapshot-\(UUID().uuidString)", isDirectory: true)
        let store = HistoryStore(url: scratch.appendingPathComponent("history.json"))
        let (recognized, failed) = fill(store)
        lines.append("throwaway store: \(store.entries.count) entries in \(scratch.path)")

        // Let the launch finish its own window work first.
        await settle()
        await settle()

        let shots: [(entry: HistoryEntry?, suffix: String, onRetry: (() -> Void)?)] = [
            (recognized, "", nil),
            (failed, "-failed", { log.info("hook retry tapped") }),
        ]
        for shot in shots {
            guard let entry = shot.entry else {
                lines.append("error: no entry for history-reader\(shot.suffix)")
                continue
            }
            lines.append("entry \(entry.status) language=\(entry.language ?? "nil") canRetry=\(entry.canRetryRecognition)")
            HistoryReadWindowController.show(entry: entry, onRetry: shot.onRetry)
            await settle()
            guard let window = HistoryReadWindowController.window(for: entry.id) else {
                lines.append("error: no reader window")
                continue
            }
            for theme in AppTheme.allCases {
                lines += await switchTheme(to: theme, settings: settings, window: window)
                lines.append(await shoot(window, name: "history-reader-\(theme.rawValue)\(shot.suffix)", in: directory))
            }
            HistoryReadWindowController.close(id: entry.id)
            await settle()
        }

        finish(lines, settings: settings, theme: originalTheme, scratch: scratch, directory: directory)
    }

    private static func finish(_ lines: [String], settings: SettingsStore, theme: AppTheme, scratch: URL, directory: URL) {
        var lines = lines
        settings.theme = theme
        try? FileManager.default.removeItem(at: scratch)
        lines.append("restored theme=\(theme.rawValue); readers closed; throwaway store removed")
        let report = lines.joined(separator: "\n") + "\n"
        try? report.write(to: directory.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
    }

    /// The invented entries: one recognised in English, one with no speech whose audio is
    /// kept, so it offers Retry.
    private static func fill(_ store: HistoryStore) -> (recognized: HistoryEntry?, failed: HistoryEntry?) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let moment = calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 9, minute: 22)) ?? Date()
        store.append(text: sampleText, providerID: "openai", language: "en", now: moment)
        let recognized = store.entries.first { $0.status == .recognized }

        var failed: HistoryEntry?
        if let pending = store.appendPendingRecognition(
            audioData: Data([0, 1, 2, 3]),
            fileExtension: "wav",
            providerID: "openai",
            language: "en",
            audioDurationSeconds: 2,
            model: nil,
            now: moment
        ) {
            failed = store.markNoSpeechDetected(id: pending.id)
        }
        return (recognized, failed)
    }

    /// Switches the theme with the reader open and reports its frame and its close
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
