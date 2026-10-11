import AppKit
import XCTest
@testable import ThemeKit

/// `ThemedWindowChrome` on a real window (#162): a theme switch changes colours and the
/// drawn bar only. The style mask, and with it the frame, stay as they are, so the
/// Settings window does not move when the theme changes while it is open.
@MainActor
final class ThemedWindowChromeTests: XCTestCase {
    private let size = NSSize(width: 520, height: 258)
    private let mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: size),
            styleMask: mask,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Settings"
        return window
    }

    /// Lets AppKit lay the titlebar out, and `apply` finish the pass it queues.
    private func settle(_ window: NSWindow) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.superview?.layoutSubtreeIfNeeded()
    }

    /// The traffic lights in window coordinates: close, minimise, zoom.
    private func trafficLights(of window: NSWindow) -> [NSRect] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { kind in
            guard let button = window.standardWindowButton(kind) else { return nil }
            return button.convert(button.bounds, to: nil)
        }
    }

    func testAThemeSwitchNeverChangesTheFrameOrTheStyleMask() {
        let window = makeWindow()
        defer { window.close() }
        let chrome = ThemedWindowChrome(window: window)

        chrome.apply(.classic, background: ThemeTokens.classic.colors.settingsSurface)
        settle(window)
        let frame = window.frame
        let styleMask = window.styleMask

        var frames: [NSRect] = []
        let observers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { _ in
                MainActor.assumeIsolated { frames.append(window.frame) }
            }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }

        for tokens in [ThemeTokens.midnight, .classic, .midnight, .classic] {
            chrome.apply(tokens, background: tokens.colors.settingsSurface)
            settle(window)
            XCTAssertEqual(window.frame, frame, tokens.theme.rawValue)
            XCTAssertEqual(window.styleMask, styleMask, tokens.theme.rawValue)
        }
        XCTAssertEqual(frames, [], "the window moved or resized on a theme switch")
    }

    /// One mask in both themes: the content runs under a transparent titlebar, so the
    /// frame is the content, whichever theme is on.
    func testBothThemesRunTheContentUnderTheTitlebar() {
        let window = makeWindow()
        defer { window.close() }
        let chrome = ThemedWindowChrome(window: window)

        for tokens in [ThemeTokens.classic, .midnight, .classic] {
            chrome.apply(tokens, background: tokens.colors.settingsSurface)
            settle(window)
            let theme = tokens.theme.rawValue
            XCTAssertTrue(window.styleMask.contains(.fullSizeContentView), theme)
            XCTAssertTrue(window.titlebarAppearsTransparent, theme)
            XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, window.frame.size, theme)
        }
    }

    /// Classic shows the system title; Midnight hides it for its drawn bar and is dark.
    func testTitleAndAppearanceFollowTheTheme() {
        let window = makeWindow()
        defer { window.close() }
        let chrome = ThemedWindowChrome(window: window)

        chrome.apply(.midnight, background: ThemeTokens.midnight.colors.settingsSurface)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.appearance?.name, .darkAqua)

        chrome.apply(.classic, background: ThemeTokens.classic.colors.settingsSurface)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertNil(window.appearance)
    }

    /// Classic's traffic lights sit exactly where the system puts them in a plain titled
    /// window of the same size: on first apply, and after a round trip through Midnight,
    /// which moved them down into its taller bar. Checked right after `apply` as well as
    /// after a run-loop pass: AppKit lays the titlebar out again on that pass and would
    /// hide a restore that left them in the wrong place.
    func testClassicTrafficLightsSitWhereThePlainWindowHasThem() {
        let plain = makeWindow()
        defer { plain.close() }
        // Same frame as the themed window, which runs its content under the titlebar.
        plain.setFrame(NSRect(origin: NSPoint(x: 200, y: 200), size: size), display: false)
        settle(plain)
        let expected = trafficLights(of: plain)
        XCTAssertEqual(expected.count, 3)

        let window = makeWindow()
        defer { window.close() }
        let chrome = ThemedWindowChrome(window: window)
        window.setFrame(NSRect(origin: NSPoint(x: 200, y: 200), size: size), display: false)

        chrome.apply(.classic, background: ThemeTokens.classic.colors.settingsSurface)
        XCTAssertEqual(trafficLights(of: window), expected, "first apply")
        settle(window)
        XCTAssertEqual(trafficLights(of: window), expected, "first apply, laid out")

        chrome.apply(.midnight, background: ThemeTokens.midnight.colors.settingsSurface)
        let midnight = trafficLights(of: window)
        XCTAssertNotEqual(midnight, expected, "Midnight centres them in its own bar")
        // Centred in the drawn bar: as far below the window's top as above the bar's bottom.
        if let close = midnight.first {
            let barBottom = window.frame.height - ThemeTokens.midnight.sizes.titlebar
            XCTAssertEqual(window.frame.height - close.maxY, close.minY - barBottom, accuracy: 0.5)
        }
        // No run-loop pass here, as in the open window, which keeps them centred until the
        // switch: a pass lays the titlebar of this off-screen window out again.

        chrome.apply(.classic, background: ThemeTokens.classic.colors.settingsSurface)
        XCTAssertEqual(trafficLights(of: window), expected, "back from Midnight")
        settle(window)
        XCTAssertEqual(trafficLights(of: window), expected, "back from Midnight, laid out")
    }
}
