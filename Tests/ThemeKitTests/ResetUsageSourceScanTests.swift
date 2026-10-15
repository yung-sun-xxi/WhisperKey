import Foundation
import XCTest

/// No hard-coded colour or size in the Reset usage window (#183), and its wiring.
///
/// The same scan as `HistoryReaderSourceScanTests`. The application target has no test
/// bundle, so the app's part of the window (`UsageResetView`, `UsageResetWindowController`,
/// the confirmation) sits between `// MARK: - Themed Reset usage begin` and `… end`
/// markers in `SettingsView.swift` and is read from the source; the drawn view and the
/// window chrome live in ThemeKit.
final class ResetUsageSourceScanTests: XCTestCase {
    private static let beginMarker = "// MARK: - Themed Reset usage begin"
    private static let endMarker = "// MARK: - Themed Reset usage end"
    private static let drawn = "Sources/ThemeKit/ThemedResetUsageView.swift"
    private static let chrome = "Sources/ThemeKit/ThemedResetUsageWindow.swift"
    private static let hook = "WhisperKey/ResetUsageSnapshotHook.swift"

    private static func appRegions() throws -> [SettingsSourceScanTests.Region] {
        try SettingsSourceScanTests.markedRegions(
            in: "WhisperKey/SettingsView.swift", begin: beginMarker, end: endMarker
        )
    }

    private static func appSource() throws -> String {
        try appRegions().map(\.text).joined(separator: "\n")
            .components(separatedBy: "\n").map(SettingsSourceScanTests.code(in:)).joined(separator: "\n")
    }

    private static func appRaw() throws -> String {
        try appRegions().map(\.text).joined(separator: "\n")
    }

    private static func source(_ path: String) throws -> String {
        try SettingsSourceScanTests.wholeFile(path).text
            .components(separatedBy: "\n").map(SettingsSourceScanTests.code(in:)).joined(separator: "\n")
    }

    private static func raw(_ path: String) throws -> String {
        try String(contentsOf: SettingsSourceScanTests.repositoryURL().appendingPathComponent(path), encoding: .utf8)
    }

    func testTheAppsPartIsMarkedAndHoldsTheWindow() throws {
        let regions = try Self.appRegions()
        XCTAssertGreaterThanOrEqual(regions.count, 1, "no \(Self.beginMarker) … \(Self.endMarker) section")
        let code = regions.map(\.text).joined(separator: "\n")
        for name in ["enum UsageResetWindowController", "struct UsageResetView", "enum UsageResetConfirmation"] {
            XCTAssertTrue(code.contains(name), "\(name) is outside the themed Reset usage section")
        }
        XCTAssertFalse(code.contains("CurrentModelBadge"), "the old badge is still drawn")
    }

    func testTheWindowHoldsNoLiteralColourOrSize() throws {
        var regions = try Self.appRegions()
        var missing: [String] = []
        for path in [Self.drawn, Self.chrome] {
            do { regions.append(try SettingsSourceScanTests.wholeFile(path)) } catch { missing.append("\(path): missing") }
        }
        let violations = missing + SettingsSourceScanTests.violations(in: regions)
        XCTAssertTrue(
            violations.isEmpty,
            "\(violations.count) literal colours or sizes:\n" + violations.joined(separator: "\n")
        )
    }

    /// The app's part holds no number but 0 and 1 beyond the text: the window's size is the
    /// tokens', and the general scan misses a size in an `NSSize` or `setContentSize`.
    func testTheAppsPartHoldsNoNumber() throws {
        let regex = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])[0-9][0-9_]*(?:\.[0-9]+)?(?![A-Za-z0-9_])"#)
        var violations: [String] = []
        for (offset, rawLine) in try Self.appSource().components(separatedBy: "\n").enumerated() {
            // Centring the window over its parent halves a size; it is not a size.
            let line = rawLine.replacingOccurrences(of: "/ 2", with: "")
            for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                let text = String(line[Range(match.range, in: line)!])
                if Double(text) != 0 && Double(text) != 1 { violations.append("\(offset + 1): \(line.trimmingCharacters(in: .whitespaces))") }
            }
        }
        XCTAssertTrue(violations.isEmpty, "numbers:\n" + violations.joined(separator: "\n"))
    }

    /// "Reset selected…" asks first; only the alert's Reset button reaches `onReset`.
    func testResetSelectedAsksBeforeResetting() throws {
        let app = try Self.appSource()
        XCTAssertTrue(app.contains("onRequestReset: { keys in"), "the view does not hand the selection to the controller to confirm")
        XCTAssertTrue(app.contains("UsageResetConfirmation.present("), "the controller does not show the alert")
        XCTAssertNotNil(
            try Self.appRaw().range(of: #"completion:\s*\{\s*confirmed in\s*guard confirmed else \{ return \}\s*onReset\(keys\)"#, options: .regularExpression),
            "onReset is not gated on the alert's Reset button"
        )
        XCTAssertEqual(app.components(separatedBy: "onReset(").count - 1, 1, "onReset is called from somewhere else: only the confirmed path may call it")
        XCTAssertTrue(app.contains("response == .alertFirstButtonReturn"), "the alert's Reset is not its first button")
        XCTAssertTrue(app.contains("UsageResetPrompt(modelCount:"), "the alert's words are not the prompt's")
        XCTAssertTrue(app.contains("hasDestructiveAction = true"))
        let rawApp = try Self.appRaw()
        XCTAssertTrue(rawApp.contains("alert.buttons.first?.keyEquivalent = \"\\r\""), "Reset is not Return")
        XCTAssertTrue(rawApp.contains("alert.buttons.dropFirst().first?.keyEquivalent = \"\\u{1b}\""), "Cancel is not Esc")
    }

    /// The chrome follows the shared token source and the view is a `ThemedRoot`.
    func testTheWindowFollowsTheThemeAndDrawsTheDrawnView() throws {
        let app = try Self.appSource()
        let rawApp = try Self.appRaw()
        XCTAssertTrue(app.contains("ThemedResetUsageWindow.configure(window, tokens: ThemeTokensSource.shared.tokens)"))
        XCTAssertTrue(app.contains("ThemedResetUsageWindow.follow(ThemeTokensSource.shared, window: window)"))
        XCTAssertTrue(rawApp.contains("ThemedRoot(\"resetUsage\") {"))
        XCTAssertTrue(app.contains("ThemedResetUsageView("))
        for drawing in ["backgroundColor", ".appearance", "NSSize(", ".font(", ".foregroundStyle(", "Button {", "Toggle("] {
            XCTAssertFalse(app.contains(drawing), "the app's part draws or sizes on its own: \(drawing)")
        }
    }

    /// The drawn view: Cancel then "Reset selected…", both grey push buttons, the second
    /// off while nothing is ticked; the pill a keycap; the card from the tokens.
    func testTheDrawnViewKeepsTheDesignsParts() throws {
        let drawn = try Self.source(Self.drawn)
        let raw = try Self.raw(Self.drawn)
        XCTAssertTrue(drawn.contains("tokens.resetUsage"), "the view does not read its token group")
        XCTAssertNotNil(raw.range(of: #"ThemedPushButton\("Cancel", action: onCancel\)\s*\.keyboardShortcut\(\.cancelAction\)"#, options: .regularExpression), "Cancel lost Esc or is not first")
        XCTAssertNotNil(raw.range(of: #"ThemedPushButton\("Reset selected…"\)[^}]*\}\s*(?:\.keyboardShortcut\(\.defaultAction\)\s*)?\.disabled\(selection\.isEmpty\)"#, options: .regularExpression), "Reset selected… is not off with nothing ticked")
        XCTAssertFalse(drawn.contains("role: .destructive"), "Reset selected… is drawn as a destructive button")
        XCTAssertTrue(drawn.contains("tokens.colors.card.color"), "the card is not 03")
        XCTAssertTrue(drawn.contains("RoundedRectangle(cornerRadius: tokens.radii.card"), "the card's radius is not the card token")
        XCTAssertTrue(drawn.contains("tokens.colors.raisedControl.color"), "the Current pill is not the keycap's 04")
        XCTAssertTrue(drawn.contains("tokens.radii.checkbox"), "the checkbox radius is not its token")
        XCTAssertTrue(drawn.contains("tokens.sizes.checkbox"), "the checkbox size is not its token")
        XCTAssertTrue(drawn.contains("tokens.colors.checkboxFill.color"))
    }

    /// The Debug-only snapshot hook is started with the others.
    func testTheSnapshotHookIsStarted() throws {
        let controller = try Self.source("WhisperKey/MenuBarController.swift")
        XCTAssertTrue(controller.contains("ResetUsageSnapshotHook.startIfRequested(settings: coordinator.settings)"))
        let hook = try Self.raw(Self.hook)
        XCTAssertTrue(hook.hasPrefix("#if DEBUG"), "the hook is not Debug-only")
    }
}
