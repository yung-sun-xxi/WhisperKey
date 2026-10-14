#if DEBUG
import AppKit
import HistoryStore
import os
import SettingsStore
import ThemeKit

/// Debug-only: renders the full history window to PNG files, each theme with entries and
/// empty, so its look can be compared without Screen Recording permission.
///
///     open -a "WhisperKey Dev" --args -WKFullHistorySnapshotDir /some/dir
///
/// The window shows a throwaway store in a temporary folder holding fixed, invented
/// entries, one of them a "No speech detected" row with Retry; never the user's history.
/// For each theme the hook switches to it with the window open, logging the frame before
/// and after and every move or resize on the way, and writes `full-history-<theme>.png`:
/// the window's frame view, titlebar included, at @2x whatever the screen's scale. Then
/// the store is cleared and `full-history-<theme>-empty.png` written the same way. There
/// is no hovered shot: a row's hover follows the real pointer only, and a synthetic
/// mouse-moved event sent to the window does not reach it.
/// The theme is put back, the window closes (so the next Full history opens on the real
/// store), the temporary folder goes, and `done.txt` lists what happened.
@MainActor
enum FullHistorySnapshotHook {
    static let directoryArgument = "WKFullHistorySnapshotDir"

    private static let log = Logger(subsystem: "WhisperKey", category: "FullHistorySnapshot")

    /// Long enough for the window to draw and a theme change to settle.
    private static let settleNanoseconds: UInt64 = 700_000_000

    /// The output resolution: pixels per point, @2x like the mockups.
    private static let pixelsPerPoint = 2

    /// One invented entry: its text, or `nil` for a "No speech detected" row, and when it
    /// was made.
    private struct Sample {
        let text: String?
        let day: Int
        let hour: Int
        let minute: Int
    }

    /// Invented entries, oldest first, on two invented September days.
    private static let samples: [Sample] = [
        Sample(text: "Let's move the call to Thursday if that works for everyone", day: 17, hour: 18, minute: 5),
        Sample(text: "OK, I'll look through the list first and come back to this question afterwards", day: 17, hour: 19, minute: 42),
        Sample(text: "Sounds good, let's do it that way", day: 18, hour: 12, minute: 7),
        Sample(text: "The first vacancy, yes, we apply. That one we take", day: 18, hour: 12, minute: 8),
        Sample(text: "We just opened a new ticket for the redesign, so the mockups need to be ready by Monday and the token sheet has to follow them", day: 18, hour: 12, minute: 10),
        Sample(text: "It doesn't work the way you describe; there are too many items in that list when I open it", day: 18, hour: 12, minute: 15),
        Sample(text: nil, day: 18, hour: 12, minute: 15),
        Sample(text: "Doesn't the numpad close as soon as dictation starts? It should, I think", day: 18, hour: 12, minute: 18),
        Sample(text: "Got it, that will take far too long, I'll do it myself. Look, what you need to do is this", day: 18, hour: 12, minute: 21),
        Sample(text: "I don't really like the last paragraph of the summary. Or rather, it is only one sentence", day: 18, hour: 12, minute: 33),
        Sample(text: "The run has finished, I'm analysing it now", day: 18, hour: 12, minute: 34),
        Sample(text: "About their questions: there is one on dbt. Well, let's say yes. There is nothing much to add here really", day: 18, hour: 12, minute: 37),
    ]

    private static var started = false

    static func startIfRequested(coordinator: AppCoordinator) {
        guard !started,
              let path = UserDefaults.standard.string(forKey: directoryArgument),
              !path.isEmpty
        else { return }

        started = true
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        Task { @MainActor in
            await run(coordinator: coordinator, directory: directory)
        }
    }

    private static func run(coordinator: AppCoordinator, directory: URL) async {
        var lines: [String] = []
        let settings = coordinator.settings
        let originalTheme = settings.theme
        ThemeTokensSource.shared.follow(settings)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            lines.append("error: cannot create \(directory.path): \(error.localizedDescription)")
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperKeyFullHistorySnapshot-\(UUID().uuidString)", isDirectory: true)
        let store = HistoryStore(url: scratch.appendingPathComponent("history.json"))
        fill(store)
        lines.append("throwaway store: \(store.entries.count) entries in \(scratch.path)")

        // Let the launch finish its own window work first.
        await settle()
        await settle()
        HistoryFullWindowController.show(history: store, coordinator: coordinator)
        // Out of the click-outside dismissal for the run: a click elsewhere would close it.
        TransientWindowStack.shared.unregister(id: "fullHistory")
        await settle()

        guard let window = HistoryFullWindowController.relatedWindow else {
            lines.append("error: no full history window")
            finish(lines, settings: settings, theme: originalTheme, scratch: scratch, directory: directory)
            return
        }

        for theme in AppTheme.allCases {
            lines += await switchTheme(to: theme, settings: settings, window: window)
            lines.append(await shoot(window, name: "full-history-\(theme.rawValue)", in: directory))
        }

        store.clear()
        await settle()
        for theme in AppTheme.allCases {
            lines += await switchTheme(to: theme, settings: settings, window: window)
            lines.append(await shoot(window, name: "full-history-\(theme.rawValue)-empty", in: directory))
        }

        // Closed, not hidden: the controller keeps a hidden window, and the next Full
        // history would open it on this store.
        window.close()
        await settle()
        finish(lines, settings: settings, theme: originalTheme, scratch: scratch, directory: directory)
    }

    private static func finish(_ lines: [String], settings: SettingsStore, theme: AppTheme, scratch: URL, directory: URL) {
        var lines = lines
        settings.theme = theme
        try? FileManager.default.removeItem(at: scratch)
        lines.append("restored theme=\(theme.rawValue); window closed=\(HistoryFullWindowController.relatedWindow == nil); throwaway store removed")
        let report = lines.joined(separator: "\n") + "\n"
        try? report.write(to: directory.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
    }

    /// The invented entries, in the Mac's time zone so they read as written.
    private static func fill(_ store: HistoryStore) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        for sample in samples {
            let moment = calendar.date(from: DateComponents(year: 2026, month: 9, day: sample.day, hour: sample.hour, minute: sample.minute)) ?? Date()
            guard let text = sample.text else {
                // A recording that came back empty: its audio kept, so it offers Retry.
                if let pending = store.appendPendingRecognition(
                    audioData: Data([0, 1, 2, 3]),
                    fileExtension: "wav",
                    providerID: "openai",
                    language: "en",
                    audioDurationSeconds: 2,
                    model: nil,
                    now: moment
                ) {
                    store.markNoSpeechDetected(id: pending.id)
                }
                continue
            }
            store.append(text: text, providerID: "openai", language: "en", now: moment)
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
