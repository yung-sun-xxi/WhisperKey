#if DEBUG
import AppKit
import os
import SettingsStore

/// Debug-only: renders the menu bar popover to PNG files, one per theme, so its look can
/// be compared without Screen Recording permission.
///
///     open -a "WhisperKey Dev" --args -WKPopoverSnapshotDir /some/dir
///
/// Once launched, the app opens the popover, takes it out of the click-outside dismissal
/// for the run, and for each theme switches to it with the popover open, logging the
/// panel's frame before and after and every move or resize on the way, then writes
/// `popover-<theme>.png`: the panel's content view at @2x whatever the screen's scale.
/// The blur behind the window does not render this way; the shell's 95% fill does. The
/// theme is put back, the popover closes (`-WKPopoverSnapshotKeepOpen YES` leaves it
/// open), and `done.txt` lists what happened.
@MainActor
enum PopoverSnapshotHook {
    static let directoryArgument = "WKPopoverSnapshotDir"
    static let keepOpenArgument = "WKPopoverSnapshotKeepOpen"

    private static let log = Logger(subsystem: "WhisperKey", category: "PopoverSnapshot")

    /// Long enough for the popover to open and a theme change to settle.
    private static let settleNanoseconds: UInt64 = 700_000_000

    private static let renderScale: CGFloat = 2

    private static var started = false

    static func startIfRequested(controller: MenuBarController) {
        guard !started,
              let path = UserDefaults.standard.string(forKey: directoryArgument),
              !path.isEmpty
        else { return }

        started = true
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        Task { @MainActor in
            await run(controller: controller, directory: directory)
        }
    }

    private static func run(controller: MenuBarController, directory: URL) async {
        var lines: [String] = []
        let settings = controller.coordinator.settings
        let originalTheme = settings.theme

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            lines.append("error: cannot create \(directory.path): \(error.localizedDescription)")
        }

        // Let the launch finish its own window work before the popover opens.
        await settle()
        await settle()
        await ensureOpen(controller)

        for theme in AppTheme.allCases {
            log.info("hook theme=\(theme.rawValue, privacy: .public)")
            lines.append(contentsOf: await switchTheme(to: theme, settings: settings, window: controller.popoverWindow))
            await ensureOpen(controller)
            lines.append(await shoot(controller.popoverWindow, name: "popover-\(theme.rawValue)", in: directory))
        }

        lines.append(contentsOf: await switchTheme(to: originalTheme, settings: settings, window: controller.popoverWindow))
        if UserDefaults.standard.bool(forKey: keepOpenArgument) {
            lines.append("kept open")
        } else {
            controller.closePopover()
        }

        lines.append("restored theme=\(originalTheme.rawValue)")
        let report = lines.joined(separator: "\n") + "\n"
        try? report.write(to: directory.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
    }

    /// Opens the popover when it is not open, and takes it out of the click-outside
    /// dismissal for the run: a click anywhere else would otherwise close it mid-way.
    private static func ensureOpen(_ controller: MenuBarController) async {
        if !controller.popoverWindow.isVisible {
            controller.showPopover()
        }
        TransientWindowStack.shared.unregister(id: "menuBarPopover")
        await settle()
    }

    /// Switches the theme with the popover open and reports the panel's frame before and
    /// after, plus every frame it passed through (each move or resize AppKit announced).
    /// A switch that keeps the panel still reports no step at all.
    private static func switchTheme(to theme: AppTheme, settings: SettingsStore, window: NSWindow) async -> [String] {
        guard window.isVisible, settings.theme != theme else {
            settings.theme = theme
            await settle()
            return ["switch to \(theme.rawValue): \(window.isVisible ? "already on it" : "popover not open")"]
        }

        let before = window.frame
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
        let kept = before.minX == after.minX && before.maxY == after.maxY
        var lines = [
            "switch to \(theme.rawValue): before \(describe(before)) after \(describe(after)) topLeft \(kept ? "kept" : "MOVED") size \(before.size == after.size ? "kept" : "CHANGED")",
        ]
        lines += steps.map { "  step \(describe($0))" }
        for line in lines {
            log.info("hook \(line, privacy: .public)")
        }
        return lines
    }

    private static func describe(_ frame: NSRect) -> String {
        "origin=\(Int(frame.minX)),\(Int(frame.minY)) size=\(Int(frame.width))x\(Int(frame.height)) top=\(Int(frame.maxY))"
    }

    private static func shoot(_ window: NSWindow, name: String, in directory: URL) async -> String {
        // A hosting view hands `cacheDisplay` what it drew for the previous request, so
        // the first render only asks SwiftUI to draw the current state; the second one
        // is kept.
        _ = png(of: window)
        await settle()
        guard let png = png(of: window) else {
            return "error: \(name): could not render the popover"
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
        // Always @2x, whatever screen the panel is on, so the shots compare with the
        // @2x mockups.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * renderScale),
            pixelsHigh: Int(bounds.height * renderScale),
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
