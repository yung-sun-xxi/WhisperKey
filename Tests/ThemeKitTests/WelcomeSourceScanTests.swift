import Foundation
import XCTest

/// No hard-coded colour or size in the welcome window (#185), and its wiring.
///
/// The same scan as `UsageBreakdownSourceScanTests`. The drawn view, the default button
/// and the window chrome live in ThemeKit; the app's part, `WhisperKey/WelcomeWindow.swift`,
/// hosts the view in the chrome and keeps the window's behaviour. The application target
/// has no test bundle, so that file is read from the source.
final class WelcomeSourceScanTests: XCTestCase {
    private static let drawn = "Sources/ThemeKit/ThemedWelcomeView.swift"
    private static let controls = "Sources/ThemeKit/ThemedControls.swift"
    private static let chrome = "Sources/ThemeKit/ThemedSurfaceWindow.swift"
    private static let app = "WhisperKey/WelcomeWindow.swift"
    private static let hook = "WhisperKey/WelcomeSnapshotHook.swift"

    private static func source(_ path: String) throws -> String {
        try SettingsSourceScanTests.wholeFile(path).text
            .components(separatedBy: "\n").map(SettingsSourceScanTests.code(in:)).joined(separator: "\n")
    }

    private static func raw(_ path: String) throws -> String {
        try String(contentsOf: SettingsSourceScanTests.repositoryURL().appendingPathComponent(path), encoding: .utf8)
    }

    func testTheWindowHoldsNoLiteralColourOrSize() throws {
        var regions: [SettingsSourceScanTests.Region] = []
        var missing: [String] = []
        for path in [Self.drawn, Self.controls, Self.chrome, Self.app] {
            do { regions.append(try SettingsSourceScanTests.wholeFile(path)) } catch { missing.append("\(path): missing") }
        }
        let violations = missing + SettingsSourceScanTests.violations(in: regions)
        XCTAssertTrue(
            violations.isEmpty,
            "\(violations.count) literal colours or sizes:\n" + violations.joined(separator: "\n")
        )
    }

    /// The app's part holds no number but 0 and 1 beyond the text: every size is the
    /// tokens', and the general scan misses a size in an `NSRect` such as the old 390 × 148.
    /// Halving (`/ 2`) is the centring the window had and stays.
    func testTheAppsPartHoldsNoNumber() throws {
        let regex = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])[0-9][0-9_]*(?:\.[0-9]+)?(?![A-Za-z0-9_])"#)
        var violations: [String] = []
        let code = try Self.source(Self.app).replacingOccurrences(of: "/ 2", with: "/ half")
        for (offset, line) in code.components(separatedBy: "\n").enumerated() {
            for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                let text = String(line[Range(match.range, in: line)!])
                if Double(text) != 0 && Double(text) != 1 { violations.append("\(offset + 1): \(line.trimmingCharacters(in: .whitespaces))") }
            }
        }
        XCTAssertTrue(violations.isEmpty, "numbers:\n" + violations.joined(separator: "\n"))
    }

    /// The window is the drawn view under a `ThemedRoot`, sized to its fitting size, in the
    /// shared surface chrome that follows the theme while the window is kept; the old look
    /// is gone.
    func testTheWindowIsBuiltFromTheDrawnViewInTheSurfaceChrome() throws {
        let app = try Self.source(Self.app)
        let raw = try Self.raw(Self.app)
        XCTAssertTrue(raw.contains("ThemedRoot(\"welcome\") {"))
        XCTAssertTrue(app.contains("ThemedWelcomeView(goToSettings: goToSettings, doLater: doLater)"))
        XCTAssertTrue(app.contains("contentRect: NSRect(origin: .zero, size: hostingView.fittingSize)"))
        XCTAssertTrue(app.contains("window.setContentSize(hostingView.fittingSize)"))
        XCTAssertTrue(app.contains("ThemedSurfaceWindow.configure(window, tokens: ThemeTokensSource.shared.tokens)"))
        XCTAssertTrue(app.contains("themeFollower = ThemedSurfaceWindow.follow(ThemeTokensSource.shared, window: window)"))
        XCTAssertTrue(app.contains("themeFollower = nil"), "the follower outlives the window")
        for old in ["windowBackgroundColor", "struct WelcomeView", "backgroundColor"] {
            XCTAssertFalse(app.contains(old), "the window still uses \(old)")
        }
        for drawing in [#"\.font\("#, #"\.foregroundStyle\("#, #"\.foregroundColor\("#, #"\.background\("#, #"\bButton\("#, #"\bText\("#] {
            XCTAssertNil(app.range(of: drawing, options: .regularExpression), "the app's part draws on its own: \(drawing)")
        }
    }

    /// Behaviour kept: the title, the style, the spaces it joins, the disabled zoom and
    /// minimise, centring, presenting, the logs, and closing it as "Later" unless an action
    /// closed it.
    func testTheWindowKeepsTodaysBehaviour() throws {
        let app = try Self.source(Self.app)
        let raw = try Self.raw(Self.app)
        XCTAssertTrue(raw.contains("window.title = \"Welcome to WhisperKey\""))
        XCTAssertTrue(app.contains("styleMask: [.titled, .closable]"))
        XCTAssertTrue(app.contains("window.isReleasedWhenClosed = false"))
        XCTAssertTrue(app.contains("window.delegate = self"))
        XCTAssertTrue(app.contains("window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]"))
        XCTAssertTrue(app.contains("window.standardWindowButton(.zoomButton)?.isEnabled = false"))
        XCTAssertTrue(app.contains("window.standardWindowButton(.miniaturizeButton)?.isEnabled = false"))
        XCTAssertTrue(app.contains("ThemeTokensSource.shared.follow(coordinator.settings)"))
        XCTAssertTrue(app.contains("center(window)"))
        XCTAssertTrue(app.contains("present(window)"))
        XCTAssertTrue(app.contains("NSApp.activate(ignoringOtherApps: true)"))
        XCTAssertTrue(app.contains("window.orderFrontRegardless()"))
        XCTAssertTrue(app.contains("self?.complete(openSettings: true)"), "Go to Settings no longer opens Settings")
        XCTAssertTrue(app.contains("self?.complete(openSettings: false)"), "Later no longer completes without Settings")
        XCTAssertNotNil(
            app.range(of: #"if !completingFromAction \{\s*coordinator\.completeWelcome\(openSettings: false\)"#, options: .regularExpression),
            "closing the window no longer completes the welcome"
        )
        for log in [
            "\"creating welcome window\"",
            "\"show existing welcome window visible=",
            "\"present welcome window begin active=",
            "\"present welcome window deferred active=",
            "\"welcome window will close completingFromAction=",
        ] {
            XCTAssertTrue(raw.contains(log), "the log \(log) is gone")
        }
    }

    /// The drawn view keeps the texts and their order, reads its tokens, and puts "Go to
    /// Settings" first as the default button with Return, then "Later" as a push button.
    func testTheDrawnViewKeepsTheTextsAndTheButtons() throws {
        let drawn = try Self.source(Self.drawn)
        let raw = try Self.raw(Self.drawn)
        let heading = try XCTUnwrap(raw.range(of: "Text(\"Welcome to WhisperKey!\")"), "the heading is gone")
        let line = try XCTUnwrap(raw.range(of: "Text(\"Go to Settings to set up your preferences, or you can do it later\")"), "the line is gone")
        let goToSettings = try XCTUnwrap(raw.range(of: "ThemedDefaultButton(\"Go to Settings\", action: goToSettings)"), "Go to Settings is not the default button")
        let later = try XCTUnwrap(raw.range(of: "ThemedPushButton(\"Later\", action: doLater)"), "Later is not the push button")
        XCTAssertLessThan(heading.lowerBound, line.lowerBound, "the heading is not above the line")
        XCTAssertLessThan(line.lowerBound, goToSettings.lowerBound, "the line is not above the buttons")
        XCTAssertLessThan(goToSettings.lowerBound, later.lowerBound, "Go to Settings is not first")
        XCTAssertNotNil(
            raw.range(of: #"ThemedDefaultButton\("Go to Settings", action: goToSettings\)\s*\.keyboardShortcut\(\.defaultAction\)"#, options: .regularExpression),
            "Go to Settings lost Return"
        )
        XCTAssertEqual(raw.components(separatedBy: ".keyboardShortcut(").count - 1, 1, "another button takes a shortcut")
        XCTAssertTrue(drawn.contains("tokens.welcome"), "the view does not read its token group")
        XCTAssertTrue(drawn.contains("tokens.type.title.font"), "the heading is not 13/600")
        XCTAssertTrue(drawn.contains("tokens.type.body.font"), "the line is not the body")
        XCTAssertTrue(drawn.contains("tokens.type.bodyLineHeight"), "the line does not take the body's line height")
        XCTAssertTrue(drawn.contains("tokens.colors.primaryText.color"), "the texts are not 08")
        XCTAssertFalse(drawn.contains("secondaryText"), "the line is 08 in the design, not 07")
        XCTAssertTrue(drawn.contains("tokens.colors.surface.color"), "the body is not 02")
        XCTAssertTrue(drawn.contains("tokens.colors.divider.color"), "the line under the titlebar is not 03")
        XCTAssertTrue(drawn.contains(".multilineTextAlignment(.center)"), "the texts are not centred")
    }

    /// The default button: the push button's box in `brand`, its label `defaultButton` in
    /// `onBrand`, `brandHover` while pressed.
    func testTheDefaultButtonIsTheBrandedPushButton() throws {
        let controls = try Self.source(Self.controls)
        let start = try XCTUnwrap(controls.range(of: "public struct ThemedDefaultButton"), "no ThemedDefaultButton")
        let tail = String(controls[start.lowerBound...])
        let end = tail.range(of: "// MARK: -")?.lowerBound ?? tail.endIndex
        let button = String(tail[..<end])
        for part in [
            "tokens.type.defaultButton.font",
            "colors.onBrand",
            "colors.brand",
            "colors.brandHover",
            "tokens.sizes.control",
            "tokens.controlMetrics.horizontalPadding",
            ".drawnControlBox(tokens,",
            ".lineLimit(1)",
        ] {
            XCTAssertTrue(button.contains(part), "the default button lost \(part)")
        }
    }

    /// The Debug-only snapshot hook is started with the others and never completes the
    /// welcome or marks it shown.
    func testTheSnapshotHookIsStartedAndLeavesTheWelcomeAlone() throws {
        let controller = try Self.source("WhisperKey/MenuBarController.swift")
        XCTAssertTrue(controller.contains("WelcomeSnapshotHook.startIfRequested(settings: coordinator.settings)"))
        let hook = try Self.raw(Self.hook)
        XCTAssertTrue(hook.hasPrefix("#if DEBUG"), "the hook is not Debug-only")
        let code = try Self.source(Self.hook)
        XCTAssertTrue(code.contains("WelcomeWindowController.makeWindow("), "the hook does not shoot the app's window")
        for write in ["completeWelcome", "markInstallWelcomePresented", "removeItem("] {
            XCTAssertFalse(code.contains(write), "the hook may change the welcome state: \(write)")
        }
    }
}
