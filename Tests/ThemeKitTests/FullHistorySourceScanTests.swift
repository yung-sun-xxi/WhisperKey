import Foundation
import XCTest

/// No hard-coded colour or size in the full history window (#164), and the window wired
/// to the drawn view and the shared chrome.
///
/// The same scan as `SettingsSourceScanTests`, over the window's files read whole. The
/// application target has no test bundle, so how `HistoryFullWindow.swift` is wired is
/// read from the source: the window takes its chrome and size from
/// `ThemedFullHistoryWindow` and follows the shared token source, its root is a
/// `ThemedRoot`, and the view only maps the store's entries to rows and hands them to
/// `ThemedFullHistoryView`, which draws them.
final class FullHistorySourceScanTests: XCTestCase {
    private static let window = "WhisperKey/HistoryFullWindow.swift"
    private static let drawn = "Sources/ThemeKit/ThemedFullHistoryView.swift"
    private static let chrome = "Sources/ThemeKit/ThemedFullHistoryWindow.swift"

    private static let wholeFiles = [
        window,
        drawn,
        chrome,
        "WhisperKey/FullHistorySnapshotHook.swift",
    ]

    /// A number written as a literal.
    private static let numberLiteral = #"(?<![A-Za-z0-9_.])[0-9][0-9_]*(?:\.[0-9]+)?(?![A-Za-z0-9_])"#

    private static func numbers(in line: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: numberLiteral)
        return regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            let text = String(line[Range(match.range, in: line)!])
            let value = Double(text.replacingOccurrences(of: "_", with: ""))
            return value == 0 || value == 1 ? nil : text
        }
    }

    private static func source(_ path: String) throws -> String {
        let regions = try SettingsSourceScanTests.wholeFile(path)
        return regions.text.components(separatedBy: "\n").map(SettingsSourceScanTests.code(in:)).joined(separator: "\n")
    }

    private static func raw(_ path: String) throws -> String {
        try String(contentsOf: SettingsSourceScanTests.repositoryURL().appendingPathComponent(path), encoding: .utf8)
    }

    func testTheFullHistoryHoldsNoLiteralColourOrSize() throws {
        var regions: [SettingsSourceScanTests.Region] = []
        var missing: [String] = []
        for path in Self.wholeFiles {
            do {
                regions.append(try SettingsSourceScanTests.wholeFile(path))
            } catch {
                missing.append("\(path): missing")
            }
        }
        let violations = missing + SettingsSourceScanTests.violations(in: regions)
        XCTAssertTrue(
            violations.isEmpty,
            "\(violations.count) literal colours or sizes:\n" + violations.joined(separator: "\n")
        )
    }

    /// The window's file holds no number but 0 and 1: its size and minimum are the
    /// tokens', the preview length and the check's lifetime are the drawn view's. The
    /// general scan above misses a size in an `NSSize` or a `setContentSize`.
    func testTheWindowFileHoldsNoNumber() throws {
        var violations: [String] = []
        let lines = try Self.source(Self.window).components(separatedBy: "\n")
        for (offset, line) in lines.enumerated() where !Self.numbers(in: line).isEmpty {
            violations.append("\(Self.window):\(offset + 1): \(line.trimmingCharacters(in: .whitespaces))")
        }
        XCTAssertTrue(violations.isEmpty, "numbers:\n" + violations.joined(separator: "\n"))
    }

    /// The window: Settings' chrome and the tokens' size from `ThemedFullHistoryWindow`,
    /// re-applied on every theme switch from the shared source; title, style, level and
    /// the transient stack as they were.
    func testTheWindowIsSettingsChromeFollowingTheSharedSource() throws {
        let window = try Self.source(Self.window)
        let raw = try Self.raw(Self.window)
        XCTAssertTrue(window.contains("ThemedFullHistoryWindow.configure(window, tokens: ThemeTokensSource.shared.tokens)"), "the window does not take its chrome and size from the tokens")
        XCTAssertTrue(window.contains("ThemedFullHistoryWindow.follow(ThemeTokensSource.shared, window: window)"), "the window does not follow a theme switch")
        XCTAssertTrue(window.contains("ThemeTokensSource.shared.follow(coordinator.settings)"), "the shared source does not follow the settings")
        XCTAssertTrue(raw.contains("ThemedRoot(\"fullHistory\") {"), "the root does not follow the shared token source")
        XCTAssertFalse(window.contains("ThemeTokensSource("), "the window builds a token source of its own")
        for drawing in ["setContentSize", "minSize", "backgroundColor", ".appearance", "titlebarAppearsTransparent", "NSSize("] {
            XCTAssertFalse(window.contains(drawing), "the app's file sets the chrome or size itself: \(drawing)")
        }
        // Unchanged.
        XCTAssertTrue(raw.contains("window.title = \"WhisperKey History\""))
        XCTAssertTrue(window.contains("window.styleMask = [.titled, .closable, .resizable, .miniaturizable]"))
        XCTAssertTrue(window.contains("window.level = .floating"))
        XCTAssertTrue(raw.contains("id: \"fullHistory\""))
        XCTAssertTrue(window.contains("layer: .secondary"))
    }

    /// The chrome itself: the system titlebar see-through over the theme's 02, the theme's
    /// appearance, the tokens' content size and minimum.
    func testTheChromeIsReadFromTheTokens() throws {
        let chrome = try Self.source(Self.chrome)
        XCTAssertTrue(chrome.contains("window.titlebarAppearsTransparent = true"))
        XCTAssertTrue(chrome.contains("window.backgroundColor = tokens.colors.surface.nsColor"))
        XCTAssertTrue(chrome.contains("window.appearance = tokens.windowAppearance.nsAppearance"))
        XCTAssertTrue(chrome.contains("window.setContentSize(tokens.fullHistory.contentSize)"))
        XCTAssertTrue(chrome.contains("window.contentMinSize = tokens.fullHistory.minContentSize"))
    }

    /// The app's view maps entries to rows and hands them over; it draws nothing itself,
    /// and the rows carry the new timestamp, not the date, time and language of before.
    func testTheViewIsDrawnByTheThemedFullHistory() throws {
        let window = try Self.source(Self.window)
        XCTAssertTrue(window.contains("ThemedFullHistoryView("), "the app's view does not hand the rows to the drawn view")
        XCTAssertTrue(window.contains("HistoryTimestamp.string(from: entry.createdAt)"), "the rows do not carry the absolute timestamp")
        XCTAssertTrue(window.contains("ClearHistoryConfirmation.present("), "Clear history does not ask first")
        XCTAssertTrue(window.contains("ThemedFullHistoryView.previewLength"), "the preview is not cut to the view's length")
        for drawing in [".font(", ".foregroundStyle(", ".padding(", "Divider()", "RoundedRectangle", "Image(systemName", ".controlSize(", "Button(", "language", ".formatted("] {
            XCTAssertFalse(window.contains(drawing), "the app's view draws or words on its own: \(drawing)")
        }

        let drawn = try Self.source(Self.drawn)
        let rawDrawn = try Self.raw(Self.drawn)
        XCTAssertTrue(rawDrawn.contains("ThemedPushButton(\"Clear history\", role: .destructive,"), "Clear history is not the destructive push button")
        XCTAssertFalse(rawDrawn.contains("Clear history…"), "the mockup's ellipsis")
        XCTAssertTrue(drawn.contains("ThemedListRow(style:"), "the rows are not the shared list row")
        XCTAssertFalse(drawn.contains("isSelected:"), "the rows draw a selection this window does not have")
        XCTAssertTrue(rawDrawn.contains("ThemedFailureButton(\"Retry\""), "Retry is not the failed row's button")
        XCTAssertTrue(drawn.contains("tokens.fullHistory"), "the view does not read its token group")
        XCTAssertFalse(drawn.contains("Divider()"), "dividers between the rows")
        XCTAssertTrue(rawDrawn.contains("Image(systemName: \"tray\")"), "the empty list's tray")
        XCTAssertTrue(drawn.contains(".help("), "the row's tooltip is gone")
        XCTAssertTrue(drawn.contains(".contextMenu"), "the row's context menu is gone")
    }

    /// The row's actions are today's: a click copies a recognised entry, a shift-click or
    /// a click on a failed one opens it; the context menu offers Retry, Open in Window and
    /// Copy to Clipboard as before.
    func testTheRowsActionsAreTodays() throws {
        let raw = try Self.raw(Self.drawn)
        XCTAssertNotNil(raw.range(of: #"if !row\.isRecognized \|\| NSEvent\.modifierFlags\.contains\(\.shift\) \{\s*onOpen\(row\.id\)\s*\} else \{\s*onCopy\(row\.id\)"#, options: .regularExpression), "the click no longer copies or opens as before")
        for item in ["Button(\"Retry\"", "Button(\"Open in Window\"", "Button(\"Copy to Clipboard\""] {
            XCTAssertTrue(raw.contains(item), "the context menu lost \(item)")
        }
        let window = try Self.raw(Self.window)
        XCTAssertTrue(window.contains("HistoryReadWindowController.show(entry: entry)"), "Open no longer opens the reader")
        XCTAssertTrue(window.contains("coordinator.retryHistoryEntry(entry)"), "Retry no longer retries")
        XCTAssertTrue(window.contains("NSPasteboard.general.setString(entry.text, forType: .string)"), "Copy no longer copies the whole text")
    }
}
