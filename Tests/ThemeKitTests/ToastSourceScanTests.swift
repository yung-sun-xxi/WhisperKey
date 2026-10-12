import Foundation
import XCTest

/// No hard-coded colour or size in the toast (#167), and the toast drawn by the shared
/// floating-panel shell.
///
/// The same scan as `SettingsSourceScanTests`, over the toast's files read whole. The
/// application target has no test bundle, so how its two files are wired is read from
/// the source too: the window is the shared chrome with a root on the shared token
/// source, and the app's `ToastView` only words the content and hands it to
/// `ThemedToastView`, which draws it.
final class ToastSourceScanTests: XCTestCase {
    private static let view = "WhisperKey/ToastView.swift"
    private static let window = "WhisperKey/ToastWindow.swift"
    private static let drawn = "Sources/ThemeKit/ThemedToastView.swift"

    private static let wholeFiles = [
        view,
        window,
        drawn,
        "Sources/ThemeKit/ToastGeometry.swift",
        "WhisperKey/ToastSnapshotHook.swift",
    ]

    /// A number written as a literal.
    private static let numberLiteral = #"(?<![A-Za-z0-9_.])[0-9][0-9_]*(?:\.[0-9]+)?(?![A-Za-z0-9_])"#

    /// The numbers in `line` other than 0 and 1 (`alphaValue = 1` is the slide, not a size).
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

    func testTheToastHoldsNoLiteralColourOrSize() throws {
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

    /// The app's two files hold no number but 0 and 1: the window's size, its margin
    /// and where it rests are the tokens' (`ToastGeometry`), and the view draws nothing of
    /// its own. The general scan above misses a size in an `NSRect` or a `max(56, …)`.
    func testTheAppFilesHoldNoNumber() throws {
        var violations: [String] = []
        for path in [Self.view, Self.window] {
            let lines = try Self.source(path).components(separatedBy: "\n")
            for (offset, line) in lines.enumerated() where !Self.numbers(in: line).isEmpty {
                violations.append("\(path):\(offset + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertTrue(violations.isEmpty, "numbers:\n" + violations.joined(separator: "\n"))
    }

    /// The window is the shared floating-panel chrome, with the tokens delivered to it
    /// live and the window server's shadow.
    func testTheWindowIsTheSharedChrome() throws {
        let window = try Self.source(Self.window)
        XCTAssertTrue(window.contains("ThemedPanelChromeView(kind: .toast"), "the window's content is not the shared chrome")
        XCTAssertTrue(window.contains("ThemedPanelChromeView.configure(self)"), "the window is not configured as a floating panel")
        XCTAssertFalse(window.contains("hasShadow = false"), "the window drops the panels' shadow")
        // `source` blanks string literals, so the root's name is read from the raw file.
        XCTAssertTrue(try Self.raw(Self.window).contains("ThemedRoot(\"toast\") {"), "the toast's root does not follow the shared token source")
        XCTAssertFalse(window.contains("ThemeTokensSource("), "the window builds a token source of its own")
        XCTAssertTrue(window.contains(".toastWindowWidth"), "the window is not as wide as the tokens say")
    }

    /// The app's view words the content; `ThemedToastView` draws all of it.
    func testTheViewIsDrawnByTheThemedToast() throws {
        let view = try Self.source(Self.view)
        XCTAssertTrue(view.contains("ThemedToastView("), "the app's view does not hand the content to the themed toast")
        for drawing in [".font(", ".foregroundStyle(", ".padding(", ".background", ".overlay", ".shadow(", "Circle()", "RoundedRectangle", "VisualEffectBackground", ".buttonStyle("] {
            XCTAssertFalse(view.contains(drawing), "the app's view draws on its own: \(drawing)")
        }

        let drawn = try Self.source(Self.drawn)
        XCTAssertTrue(drawn.contains("ThemedPanelShell(.toast)"), "the toast is not the shared shell")
        XCTAssertTrue(drawn.contains("ThemedPushButton("), "the action is not the drawn push button")
        XCTAssertTrue(drawn.contains("tokens.toast"), "the toast does not read its token group")
        XCTAssertFalse(drawn.contains(".bordered"), "the system's bordered button is still there")
    }

    /// The glyph follows the style only: the microphone for a warning, the crossed-out
    /// one for information; grey, with no tinted circle.
    func testTheGlyphFollowsTheStyle() throws {
        let view = try Self.source(Self.view)
        XCTAssertNotNil(view.range(of: #"case \.warning:\s*(?:return\s+)?\.microphone\b"#, options: .regularExpression), "a warning does not show the microphone")
        XCTAssertNotNil(view.range(of: #"case \.information:\s*(?:return\s+)?\.microphoneSlash\b"#, options: .regularExpression), "information does not show the crossed-out microphone")
        let raw = try Self.raw(Self.view) + Self.raw(Self.drawn)
        for old in ["exclamationmark.triangle", "waveform.slash", "orange"] {
            XCTAssertFalse(raw.contains(old), "the old glyph is still there: \(old)")
        }
    }
}
