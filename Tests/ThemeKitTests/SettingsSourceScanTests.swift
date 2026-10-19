import Foundation
import XCTest

/// No hard-coded colour or size in the Settings window's views (#162): every colour,
/// font and size there comes from the theme tokens.
///
/// SwiftUI view bodies cannot be unit-tested, so the source is read instead. The
/// Settings window's code in `WhisperKey/SettingsView.swift` sits between
/// `// MARK: - Themed Settings begin` and `// MARK: - Themed Settings end` markers; the
/// popover and the Reset usage window share the file and are restyled by other tickets,
/// so they stay outside. `LaunchAtLoginToggle.swift` is a Settings row and is read whole.
final class SettingsSourceScanTests: XCTestCase {
    static let beginMarker = "// MARK: - Themed Settings begin"
    static let endMarker = "// MARK: - Themed Settings end"

    /// A number other than zero: zero spacing or padding is not a size.
    private static let number = #"(?:0\.[0-9]*[1-9][0-9]*|[1-9][0-9_]*(?:\.[0-9]+)?)"#

    static let forbidden: [(name: String, pattern: String)] = [
        ("colour type", #"\b(?:NS)?Color\s*[.(]"#),
        // `layer: .secondary` is TransientWindowStack's layer, not a colour.
        ("named colour", #"(?<!layer: )\.(?:red|green|orange|blue|yellow|gray|grey|purple|pink|white|black|primary|secondary|tertiary|quaternary|accentColor)\b"#),
        ("system font", #"\.font\(\s*\."#),
        ("frame size", #"\.frame\([^)]*\b(?:width|height|minWidth|minHeight|maxWidth|maxHeight|idealWidth|idealHeight):\s*"# + number),
        ("padding", #"\.padding\((?:[^)]*,\s*)?"# + number + #"\s*\)"#),
        ("spacing", #"\bspacing:\s*"# + number),
        ("corner radius", #"\bcornerRadius:\s*"# + number),
        ("line width", #"\blineWidth:\s*"# + number),
        ("font size", #"\bsize:\s*"# + number),
        ("minimum length", #"\bminLength:\s*"# + number),
        ("opacity", #"\.opacity\(\s*"# + number),
        ("size constant", #":\s*CGFloat\s*=\s*"# + number),
    ]

    func testTheSettingsSectionIsMarked() throws {
        let regions = try Self.settingsRegions()
        XCTAssertGreaterThanOrEqual(regions.count, 1, "no \(Self.beginMarker) … \(Self.endMarker) section")

        let settingsCode = regions.map(\.text).joined(separator: "\n")
        // The markers enclose the Settings window, not a corner of it.
        for name in [
            "enum SettingsWindowController",
            "final class SettingsContentViewController",
            "struct SettingsPane:",
            "struct GeneralSettingsPane",
            "struct RecordingSettingsPane",
            "struct TranscriptionSettingsPane",
            "struct QuickPasteSettingsPane",
            "struct APIKeyValidationBadge",
            "struct ThemePicker",
            "struct SettingsRow",
        ] {
            XCTAssertTrue(settingsCode.contains(name), "\(name) is outside the themed Settings section")
        }
        // ...and leave out the surfaces other tickets restyle.
        for name in ["struct PopoverContent", "struct UsageResetView", "enum UsageResetWindowController"] {
            XCTAssertFalse(settingsCode.contains(name), "\(name) is inside the themed Settings section")
        }
    }

    func testTheSettingsSectionHoldsNoLiteralColourOrSize() throws {
        let sources = try Self.settingsRegions() + [Self.wholeFile("WhisperKey/LaunchAtLoginToggle.swift")]
        let violations = Self.violations(in: sources)
        XCTAssertTrue(violations.isEmpty, "literal colours or sizes:\n" + violations.joined(separator: "\n"))
    }

    /// The scan itself: each rule catches what it is for, and leaves token reads alone.
    func testTheScanCatchesLiteralsAndPassesTokens() {
        let caught = [
            ".foregroundStyle(.red)",
            ".foregroundStyle(.secondary)",
            ".background(Color(nsColor: .controlBackgroundColor))",
            "static let backgroundColor = NSColor.controlBackgroundColor",
            ".font(.caption)",
            ".font(.system(size: 12, weight: .bold))",
            ".frame(width: 64)",
            ".frame(minHeight: 22, alignment: .center)",
            ".padding(18)",
            ".padding(.horizontal, 6)",
            "HStack(spacing: 6) {",
            "RoundedRectangle(cornerRadius: 6)",
            ".strokeBorder(edge, lineWidth: 1)",
            "Spacer(minLength: 8)",
            "static let iconSize: CGFloat = 20",
        ]
        for line in caught {
            let code = Self.code(in: line)
            XCTAssertTrue(Self.forbidden.contains { code.range(of: $0.pattern, options: .regularExpression) != nil }, line)
        }

        let passed = [
            ".foregroundStyle(tokens.colors.secondaryText.color)",
            ".font(tokens.type.body.font)",
            ".frame(width: tokens.settingsWindow.width, alignment: .topLeading)",
            ".padding(.horizontal, tokens.spacing.windowTextEdge)",
            "HStack(spacing: 0) {",
            "layer: .secondary,",
            "Spacer(minLength: 0)",
            "Text(\"Pause media while recording\")",
            ".help(\"Stop recording to change.\") // .red in a comment",
        ]
        for line in passed {
            let code = Self.code(in: line)
            for rule in Self.forbidden {
                XCTAssertNil(code.range(of: rule.pattern, options: .regularExpression), "\(rule.name): \(line)")
            }
        }
    }

    /// One line per literal colour or size in `regions`, with its file and line.
    static func violations(in regions: [Region]) -> [String] {
        var violations: [String] = []
        for region in regions {
            for (offset, rawLine) in region.text.components(separatedBy: "\n").enumerated() {
                let line = code(in: rawLine)
                for rule in forbidden where line.range(of: rule.pattern, options: .regularExpression) != nil {
                    violations.append("\(region.file):\(region.firstLine + offset): \(rule.name): \(rawLine.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return violations
    }

    // MARK: - Reading the source

    struct Region {
        let file: String
        let firstLine: Int
        let text: String
    }

    static func repositoryURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ThemeKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository
    }

    static func wholeFile(_ path: String) throws -> Region {
        let text = try String(contentsOf: repositoryURL().appendingPathComponent(path), encoding: .utf8)
        return Region(file: path, firstLine: 1, text: stripMultilineStrings(text))
    }

    static func settingsRegions() throws -> [Region] {
        try markedRegions(in: "WhisperKey/SettingsView.swift", begin: beginMarker, end: endMarker)
    }

    /// Every stretch of `path` between a `begin` and an `end` marker line.
    static func markedRegions(in path: String, begin beginMarker: String, end endMarker: String) throws -> [Region] {
        let lines = try String(contentsOf: repositoryURL().appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
        var regions: [Region] = []
        var start: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == beginMarker {
                start = index + 1
            } else if trimmed == endMarker, let first = start {
                let text = lines[first..<index].joined(separator: "\n")
                regions.append(Region(file: path, firstLine: first + 1, text: stripMultilineStrings(text)))
                start = nil
            }
        }
        return regions
    }

    /// The line without its string literals and its `//` comment.
    static func code(in line: String) -> String {
        let withoutStrings = line.replacingOccurrences(of: #""(?:[^"\\]|\\.)*""#, with: "\"\"", options: .regularExpression)
        guard let comment = withoutStrings.range(of: "//") else { return withoutStrings }
        return String(withoutStrings[..<comment.lowerBound])
    }

    /// Blanks the lines of `"""` strings, keeping the line count.
    static func stripMultilineStrings(_ text: String) -> String {
        var inside = false
        return text.components(separatedBy: "\n").map { line -> String in
            let quotes = line.components(separatedBy: "\"\"\"").count - 1
            defer { if quotes % 2 == 1 { inside.toggle() } }
            return inside || quotes > 0 ? "" : line
        }.joined(separator: "\n")
    }
}
