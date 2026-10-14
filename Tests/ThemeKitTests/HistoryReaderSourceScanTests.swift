import Foundation
import XCTest

/// No hard-coded colour or size in the history entry reader (#165), and the window wired
/// to the drawn view and its chrome.
///
/// The same scan as `FullHistorySourceScanTests`. The application target has no test
/// bundle, so how `HistoryReadWindow.swift` is wired is read from the source: the window
/// takes its chrome and size from `ThemedHistoryReaderWindow` and follows the shared
/// token source, its root is a `ThemedRoot`, and the view only maps the entry to the
/// drawn view's words and actions; `ThemedHistoryReaderView` draws them.
final class HistoryReaderSourceScanTests: XCTestCase {
    private static let window = "WhisperKey/HistoryReadWindow.swift"
    private static let drawn = "Sources/ThemeKit/ThemedHistoryReaderView.swift"
    private static let chrome = "Sources/ThemeKit/ThemedHistoryReaderWindow.swift"
    private static let hook = "WhisperKey/HistoryReaderSnapshotHook.swift"

    private static let wholeFiles = [window, drawn, chrome, hook]

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

    func testTheReaderHoldsNoLiteralColourOrSize() throws {
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
    /// tokens', the Copied lifetime is the drawn view's. The general scan above misses a
    /// size in an `NSSize` or a `setContentSize`.
    func testTheWindowFileHoldsNoNumber() throws {
        var violations: [String] = []
        let lines = try Self.source(Self.window).components(separatedBy: "\n")
        for (offset, line) in lines.enumerated() where !Self.numbers(in: line).isEmpty {
            violations.append("\(Self.window):\(offset + 1): \(line.trimmingCharacters(in: .whitespaces))")
        }
        XCTAssertTrue(violations.isEmpty, "numbers:\n" + violations.joined(separator: "\n"))
    }

    /// The window: Settings' chrome and the tokens' size from `ThemedHistoryReaderWindow`,
    /// re-applied on every theme switch from the shared source for as long as the window
    /// is kept; title, style, level and the close delegate as they were.
    func testTheWindowIsSettingsChromeFollowingTheSharedSource() throws {
        let window = try Self.source(Self.window)
        let raw = try Self.raw(Self.window)
        XCTAssertTrue(window.contains("ThemedHistoryReaderWindow.configure(window, tokens: ThemeTokensSource.shared.tokens)"), "the window does not take its chrome and size from the tokens")
        XCTAssertTrue(window.contains("themeFollowers[entry.id] = ThemedHistoryReaderWindow.follow(ThemeTokensSource.shared, window: window)"), "the window does not follow a theme switch")
        XCTAssertTrue(window.contains("themeFollowers.removeValue(forKey: id)"), "a closed reader keeps following the theme")
        XCTAssertTrue(raw.contains("ThemedRoot(\"reader\") {"), "the root does not follow the shared token source")
        XCTAssertFalse(window.contains("ThemeTokensSource("), "the window builds a token source of its own")
        for drawing in ["setContentSize", "minSize", "backgroundColor", ".appearance", "titlebarAppearsTransparent", "NSSize("] {
            XCTAssertFalse(window.contains(drawing), "the app's file sets the chrome or size itself: \(drawing)")
        }
        // Unchanged.
        XCTAssertTrue(raw.contains("window.title = \"Transcription\""))
        XCTAssertTrue(window.contains("window.styleMask = [.titled, .closable, .resizable]"))
        XCTAssertTrue(window.contains("window.level = .floating"))
        XCTAssertTrue(window.contains("window.isReleasedWhenClosed = false"))
        XCTAssertTrue(window.contains("WindowCloseDelegate.shared.register(id: entry.id, window: window)"))
    }

    /// The chrome itself: the system titlebar see-through over the theme's 02, the theme's
    /// appearance, the tokens' content size and minimum.
    func testTheChromeIsReadFromTheTokens() throws {
        let chrome = try Self.source(Self.chrome)
        XCTAssertTrue(chrome.contains("window.titlebarAppearsTransparent = true"))
        XCTAssertTrue(chrome.contains("window.backgroundColor = tokens.colors.surface.nsColor"))
        XCTAssertTrue(chrome.contains("window.appearance = tokens.windowAppearance.nsAppearance"))
        XCTAssertTrue(chrome.contains("window.setContentSize(tokens.historyReader.contentSize)"))
        XCTAssertTrue(chrome.contains("window.contentMinSize = tokens.historyReader.minContentSize"))
    }

    /// The app's view maps the entry and hands it over; it draws nothing itself. The date
    /// keeps the system format, the wording of each status is today's, Retry shows only
    /// when the entry can be retried and there is something to retry with.
    func testTheViewIsDrawnByTheThemedReader() throws {
        let window = try Self.source(Self.window)
        let raw = try Self.raw(Self.window)
        XCTAssertTrue(window.contains("ThemedHistoryReaderView("), "the app's view does not hand the entry to the drawn view")
        XCTAssertTrue(window.contains("entry.createdAt.formatted(date: .abbreviated, time: .shortened)"), "the date lost the system format")
        XCTAssertTrue(window.contains("language: entry.language"), "the language does not reach the tag")
        XCTAssertTrue(window.contains("isRecognized: entry.status == .recognized"), "Copy and the text colour lost their condition")
        XCTAssertTrue(window.contains("canRetry: entry.canRetryRecognition && onRetry != nil"), "Retry lost its condition")
        XCTAssertTrue(window.contains("NSPasteboard.general.setString(entry.text, forType: .string)"), "Copy no longer copies the whole text")
        for wording in ["\"File to recognize\"", "\"No speech detected\"", "\"No microphone audio captured\"", "entry.text.isEmpty ? \"Audio capture failed\" : entry.text"] {
            XCTAssertTrue(raw.contains(wording), "the wording changed: \(wording)")
        }
        for drawing in [".font(", ".foregroundStyle(", ".padding(", "RoundedRectangle", "Capsule", "Button(", ".keyboardShortcut(", "uppercased", "Task.sleep", "ScrollView", "Spacer"] {
            XCTAssertFalse(window.contains(drawing), "the app's view draws on its own: \(drawing)")
        }
    }

    /// The drawn view: today's buttons in today's order with today's shortcuts, the text
    /// scrollable and selectable, the card from the tokens.
    func testTheDrawnViewKeepsTodaysControls() throws {
        let drawn = try Self.source(Self.drawn)
        let raw = try Self.raw(Self.drawn)
        XCTAssertTrue(drawn.contains("tokens.historyReader"), "the view does not read its token group")
        XCTAssertNotNil(raw.range(of: #"if isRecognized \{\s*ThemedPushButton\(Self\.copyTitle\(copied: didCopy\)\)"#, options: .regularExpression), "Copy is not the push button shown for a recognised entry")
        XCTAssertTrue(drawn.contains(".keyboardShortcut(\"\", modifiers: [.command])") && raw.contains(".keyboardShortcut(\"c\", modifiers: [.command])"), "Copy lost ⌘C")
        XCTAssertNotNil(raw.range(of: #"if canRetry \{\s*ThemedPushButton\("Retry"\) \{\s*onRetry\(\)\s*onClose\(\)"#, options: .regularExpression), "Retry no longer retries, then closes")
        XCTAssertNotNil(raw.range(of: #"ThemedPushButton\("Close", action: onClose\)\s*\.keyboardShortcut\(\.cancelAction\)"#, options: .regularExpression), "Close lost Esc")
        XCTAssertTrue(drawn.contains("Spacer(minLength: 0)"), "Close is not pushed to the trailing edge")
        XCTAssertTrue(drawn.contains("ScrollView"), "the text does not scroll")
        XCTAssertTrue(drawn.contains(".textSelection(.enabled)"), "the text cannot be selected")
        XCTAssertTrue(drawn.contains("RoundedRectangle(cornerRadius: tokens.radii.card)"), "the card's radius is not the card token")
        XCTAssertTrue(drawn.contains("tokens.colors.card.color"), "the card is not 03")
        XCTAssertFalse(drawn.contains("Capsule"), "the tag is drawn in a capsule")
        XCTAssertTrue(drawn.contains("Self.copiedNanoseconds"), "Copied does not last the view's time")
    }

    /// The Debug-only snapshot hook is started with the others.
    func testTheSnapshotHookIsStarted() throws {
        let controller = try Self.source("WhisperKey/MenuBarController.swift")
        XCTAssertTrue(controller.contains("HistoryReaderSnapshotHook.startIfRequested(settings: coordinator.settings)"))
        let hook = try Self.raw(Self.hook)
        XCTAssertTrue(hook.hasPrefix("#if DEBUG"), "the hook is not Debug-only")
    }
}
