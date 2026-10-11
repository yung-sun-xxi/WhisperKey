#if DEBUG
import AppKit
import os
import SettingsStore

/// Debug-only: renders the Settings window to PNG files, every theme times every pane,
/// so its look can be compared without Screen Recording permission.
///
///     open -a "WhisperKey Dev" --args -WKSettingsSnapshotDir /some/dir
///
/// Once launched, the app opens Settings and writes `settings-<theme>-<tab>.png` for
/// each pair, plus `settings-<theme>-quickPaste-on.png` when Quick paste is off (it is
/// switched on for that shot only). The image is the window's frame view, titlebar
/// included, at @2x whatever the screen's scale. The theme and Quick paste setting are put
/// back, Settings closes, and `done.txt` lists what was written.
@MainActor
enum SettingsSnapshotHook {
    static let directoryArgument = "WKSettingsSnapshotDir"

    /// Long enough for a pane switch, the window resize and a theme change to settle.
    private static let settleNanoseconds: UInt64 = 700_000_000

    private static let renderScale: CGFloat = 2

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
        var log: [String] = []
        let settings = coordinator.settings
        let originalTheme = settings.theme
        let originalQuickPaste = settings.quickPasteEnabled

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log.append("error: cannot create \(directory.path): \(error.localizedDescription)")
        }

        // Let the launch finish its own window work before Settings appears.
        await settle()
        await ensureWindowOpen(coordinator: coordinator)

        for theme in AppTheme.allCases {
            settingsWindowLog.info("hook theme=\(theme.rawValue, privacy: .public)")
            settings.theme = theme
            await settle()

            for tab in SettingsWindowController.tabIdentifiers {
                await ensureWindowOpen(coordinator: coordinator)
                log.append(await shoot(tab: tab, name: "settings-\(theme.rawValue)-\(tab)", in: directory))
            }

            if !settings.quickPasteEnabled, let quickPaste = SettingsWindowController.tabIdentifiers.first(where: { $0 == "quickPaste" }) {
                settings.quickPasteEnabled = true
                await ensureWindowOpen(coordinator: coordinator)
                log.append(await shoot(tab: quickPaste, name: "settings-\(theme.rawValue)-\(quickPaste)-on", in: directory))
                settings.quickPasteEnabled = originalQuickPaste
                await settle()
            }
        }

        settings.theme = originalTheme
        settings.quickPasteEnabled = originalQuickPaste
        await settle()
        SettingsWindowController.hide()

        log.append("restored theme=\(originalTheme.rawValue) quickPasteEnabled=\(originalQuickPaste)")
        let report = log.joined(separator: "\n") + "\n"
        try? report.write(to: directory.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
    }

    /// Opens Settings when it is not open, and takes it out of the click-outside
    /// dismissal for the run: a click anywhere else would otherwise close it mid-way.
    private static func ensureWindowOpen(coordinator: AppCoordinator) async {
        guard SettingsWindowController.relatedWindow?.isVisible != true else { return }

        coordinator.openSettingsWindow()
        TransientWindowStack.shared.unregister(id: "settings")
        await settle()
    }

    private static func shoot(tab: String, name: String, in directory: URL) async -> String {
        settingsWindowLog.info("hook select=\(tab, privacy: .public) for=\(name, privacy: .public)")
        guard SettingsWindowController.selectTab(identifier: tab) else {
            return "error: \(name): no pane \(tab) or no window"
        }
        await settle()

        guard let window = SettingsWindowController.relatedWindow else {
            return "error: \(name): no settings window"
        }
        // The window draws its titlebar and controls in their active state only while
        // the app is active and the window is key.
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

        settingsWindowLog.info("hook shot=\(name, privacy: .public) frame=\(Int(window.frame.width), privacy: .public)x\(Int(window.frame.height), privacy: .public)")
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
        // Always @2x, whatever screen the window is on, so the shots compare with the
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
        frameView.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func settle() async {
        try? await Task.sleep(nanoseconds: settleNanoseconds)
    }
}
#endif
