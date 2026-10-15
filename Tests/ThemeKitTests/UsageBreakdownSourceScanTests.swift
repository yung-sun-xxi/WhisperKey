import Foundation
import XCTest

/// No hard-coded colour or size in the Usage by model window (#184), and its wiring.
///
/// The same scan as `ResetUsageSourceScanTests`. The drawn view and the window chrome
/// live in ThemeKit; the app's part, `WhisperKey/UsageBreakdownWindow.swift`, maps the
/// usage store into plain rows and hosts the view with the popover's period picker. The
/// application target has no test bundle, so that file is read from the source.
final class UsageBreakdownSourceScanTests: XCTestCase {
    private static let drawn = "Sources/ThemeKit/ThemedUsageBreakdownView.swift"
    private static let chrome = "Sources/ThemeKit/ThemedSurfaceWindow.swift"
    private static let app = "WhisperKey/UsageBreakdownWindow.swift"
    private static let hook = "WhisperKey/UsageBreakdownSnapshotHook.swift"

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
        for path in [Self.drawn, Self.chrome, Self.app] {
            do { regions.append(try SettingsSourceScanTests.wholeFile(path)) } catch { missing.append("\(path): missing") }
        }
        let violations = missing + SettingsSourceScanTests.violations(in: regions)
        XCTAssertTrue(
            violations.isEmpty,
            "\(violations.count) literal colours or sizes:\n" + violations.joined(separator: "\n")
        )
    }

    /// The app's part holds no number but 0 and 1 beyond the text: every size is the
    /// tokens', and the general scan misses a size in an `NSSize` or a `static let`.
    func testTheAppsPartHoldsNoNumber() throws {
        let regex = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])[0-9][0-9_]*(?:\.[0-9]+)?(?![A-Za-z0-9_])"#)
        var violations: [String] = []
        for (offset, line) in try Self.source(Self.app).components(separatedBy: "\n").enumerated() {
            for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                let text = String(line[Range(match.range, in: line)!])
                if Double(text) != 0 && Double(text) != 1 { violations.append("\(offset + 1): \(line.trimmingCharacters(in: .whitespaces))") }
            }
        }
        XCTAssertTrue(violations.isEmpty, "numbers:\n" + violations.joined(separator: "\n"))
    }

    /// The window is the drawn view under a `ThemedRoot` with the popover's period picker,
    /// in the shared surface chrome that follows the theme; the old look is gone.
    func testTheWindowIsBuiltFromTheDrawnViewAndThePeriodPicker() throws {
        let app = try Self.source(Self.app)
        let raw = try Self.raw(Self.app)
        XCTAssertTrue(raw.contains("ThemedRoot(\"usageByModel\") {"))
        XCTAssertTrue(app.contains("ThemedUsageBreakdownView("))
        XCTAssertTrue(app.contains("ThemedPeriodPicker("))
        XCTAssertTrue(app.contains("selection: $settings.usageStatsRange"))
        XCTAssertTrue(app.contains("options: UsageStatsRange.allCases"))
        XCTAssertTrue(app.contains("title: { $0.compactLabel }"))
        XCTAssertTrue(app.contains("help: { $0.displayName }"))
        XCTAssertTrue(raw.contains(".help(\"Choose the usage stats range\")"))
        XCTAssertTrue(app.contains("ThemedSurfaceWindow.configure(window, tokens: ThemeTokensSource.shared.tokens)"))
        XCTAssertTrue(app.contains("ThemedSurfaceWindow.follow(ThemeTokensSource.shared, window: window)"))
        for old in ["PopoverTypography", "HeaderSurfaceColor", "HeaderPeriodPicker", "SettingsWindowLayout"] {
            XCTAssertFalse(app.contains(old), "the window still uses \(old)")
        }
        for drawing in [".font(", ".foregroundStyle(", ".foregroundColor(", "Grid(", "Divider()", "RoundedRectangle("] {
            XCTAssertFalse(app.contains(drawing), "the app's part draws on its own: \(drawing)")
        }
    }

    /// Behaviour kept: title, floating, closable, the transient stack, and the data and
    /// formatting the window had.
    func testTheWindowKeepsTodaysBehaviourAndData() throws {
        let app = try Self.source(Self.app)
        let raw = try Self.raw(Self.app)
        XCTAssertTrue(raw.contains("window.title = \"Usage by model\""))
        XCTAssertTrue(app.contains("window.level = .floating"))
        XCTAssertTrue(app.contains("[.titled, .closable]"))
        XCTAssertTrue(app.contains("TransientWindowStack.shared.register("))
        XCTAssertTrue(app.contains("usageStats.breakdown(range: range)"))
        XCTAssertTrue(app.contains("usageStats.totalSummary(range: range)"))
        XCTAssertTrue(app.contains("UsageLineFormatter.wordsLabel("))
        XCTAssertTrue(app.contains("UsageLineFormatter.compactAudioDurationLabel("))
        XCTAssertTrue(app.contains("UsageLineFormatter.compactApproximateCostLabel("))
        XCTAssertTrue(raw.contains("return \"-\""), "a cost with no single-currency price no longer reads \"-\"")
        XCTAssertTrue(raw.contains("\"\\(provider) · \\(key.modelID)\""), "the model name changed")
    }

    /// The drawn view keeps the texts and reads its tokens: the card, the caps header, the
    /// edge lines, the 34 rows, tabular figures, the 13/600 Total.
    func testTheDrawnViewKeepsTheDesignsParts() throws {
        let drawn = try Self.source(Self.drawn)
        let raw = try Self.raw(Self.drawn)
        for text in ["\"Model\"", "\"Words\"", "\"Audio\"", "\"Cost\"", "\"Total\"", "\"No usage in this period.\""] {
            XCTAssertTrue(raw.contains(text), "the view lost \(text)")
        }
        XCTAssertTrue(drawn.contains("tokens.usageBreakdown"), "the view does not read its token group")
        XCTAssertTrue(drawn.contains("tokens.colors.card.color"), "the card is not 03")
        XCTAssertTrue(drawn.contains("RoundedRectangle(cornerRadius: tokens.radii.card"), "the card's radius is not the card token")
        XCTAssertTrue(drawn.contains("tokens.colors.bar.color"), "the picker band is not 01")
        XCTAssertTrue(drawn.contains("tokens.colors.divider.color"), "the lines under the titlebar and band are not 03")
        XCTAssertTrue(drawn.contains("tokens.colors.edge.color"), "the table lines are not 05")
        XCTAssertTrue(drawn.contains("tokens.type.capsHeader.font"), "the header is not the caps header")
        XCTAssertTrue(drawn.contains("tokens.type.capsHeader.tracking"), "the header is not tracked")
        XCTAssertTrue(drawn.contains(".textCase(.uppercase)"), "the header is not in caps")
        XCTAssertTrue(drawn.contains("tokens.type.title.font"), "Total is not 13/600")
        XCTAssertTrue(drawn.contains("tokens.sizes.listRow"), "the rows are not list rows")
        XCTAssertTrue(drawn.contains(".monospacedDigit()"), "the figures are not tabular")
    }

    /// The Debug-only snapshot hook is started with the others and never writes usage.
    func testTheSnapshotHookIsStartedAndLeavesTheUsageAlone() throws {
        let controller = try Self.source("WhisperKey/MenuBarController.swift")
        XCTAssertTrue(controller.contains("UsageBreakdownSnapshotHook.startIfRequested(coordinator: coordinator)"))
        let hook = try Self.raw(Self.hook)
        XCTAssertTrue(hook.hasPrefix("#if DEBUG"), "the hook is not Debug-only")
        let code = try Self.source(Self.hook)
        for write in [".record(", "reset", "removeItem("] {
            XCTAssertFalse(code.contains(write), "the hook may write usage data: \(write)")
        }
    }

    /// `HeaderPeriodPicker` was the window's own picker; nothing uses it now.
    func testTheOldPickerIsGone() throws {
        let settings = try Self.source("WhisperKey/SettingsView.swift")
        XCTAssertFalse(settings.contains("struct HeaderPeriodPicker"))
    }
}
