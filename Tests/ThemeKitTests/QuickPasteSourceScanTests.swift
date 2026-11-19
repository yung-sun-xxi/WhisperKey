import Foundation
import XCTest

/// No hard-coded colour or size in the quick paste popup (#166), and one geometry for
/// drawing and choosing.
///
/// The same scan as `SettingsSourceScanTests`, over the popup's files read whole. The
/// application target has no test bundle, so how its two files are wired is read from
/// the source too: the controller takes the geometry from the tokens once per reveal and
/// hands that one value to both the hit test and the panel; neither file builds a
/// geometry of its own or reads a size token behind its back.
final class QuickPasteSourceScanTests: XCTestCase {
    private static let panel = "WhisperKey/QuickPastePanel.swift"
    private static let controller = "WhisperKey/QuickPasteController.swift"

    private static let wholeFiles = [
        panel,
        "WhisperKey/QuickPasteSnapshotHook.swift",
        "Sources/ThemeKit/ThemedQuickPasteView.swift",
        "Sources/ThemeKit/QuickPasteGeometry.swift",
    ]

    private static func source(_ path: String) throws -> String {
        let regions = try SettingsSourceScanTests.wholeFile(path)
        return regions.text.components(separatedBy: "\n").map(SettingsSourceScanTests.code(in:)).joined(separator: "\n")
    }

    private static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testThePopupHoldsNoLiteralColourOrSize() throws {
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

    /// The window is the shared floating-panel shell, with the tokens delivered to it.
    func testThePanelIsTheSharedShell() throws {
        let panel = try Self.source(Self.panel)
        XCTAssertTrue(panel.contains("ThemedPanelChromeView(kind: .quickPaste"), "the window's content is not the shared chrome")
        // The root that follows the shared source, so an open panel takes a theme switch;
        // a root given a source of its own would stay on that source's theme.
        // `source` blanks string literals, so the root's name is read from the raw file.
        let raw = try String(contentsOf: SettingsSourceScanTests.repositoryURL().appendingPathComponent(Self.panel), encoding: .utf8)
        XCTAssertTrue(raw.contains("ThemedRoot(\"quickPaste\") {"), "the panel's root does not follow the shared token source")
        XCTAssertFalse(panel.contains("ThemeTokensSource("), "the panel builds a token source of its own")
        XCTAssertTrue(panel.contains("ThemedQuickPasteView("), "the panel does not draw the themed view")
        XCTAssertFalse(panel.contains("VisualEffectBackground"), "the old material background is still there")
    }

    /// One geometry: the controller reads it once, and both files only pass it on.
    func testOneGeometryForDrawingAndChoosing() throws {
        let panel = try Self.source(Self.panel)
        let controller = try Self.source(Self.controller)

        XCTAssertEqual(Self.count(".quickPasteMetrics", in: controller), 1, "the controller reads the geometry more than once, or not at all")
        XCTAssertEqual(Self.count(".quickPasteMetrics", in: panel), 0, "the panel reads its own geometry instead of the controller's")
        for (name, text) in [("panel", panel), ("controller", controller)] {
            XCTAssertFalse(text.contains("QuickPasteMetrics("), "the \(name) builds a geometry of its own")
            XCTAssertFalse(text.contains("sizes.listRow"), "the \(name) reads the row height behind the geometry's back")
            XCTAssertFalse(text.contains("panels.quickPaste"), "the \(name) reads the width behind the geometry's back")
            XCTAssertFalse(text.contains("spacing.rowInset"), "the \(name) reads the inset behind the geometry's back")
        }
        // The window size, the panel, the stored reveal and the hit test all take that one
        // value.
        for use in [
            "QuickPasteLayout.panelSize(entryCount: entries.count, metrics: metrics)",
            "QuickPastePanel(content: content, metrics: metrics)",
            "metrics: metrics,",
            "metrics: reveal.metrics",
        ] {
            XCTAssertTrue(controller.contains(use), "the controller does not pass its metrics: \(use)")
        }
        XCTAssertTrue(panel.contains("metrics: metrics"), "the panel does not size or draw from the metrics it is given")
    }

    /// One order (#211): the newest entry is the top row wherever the panel opens, so
    /// nothing in the popup's files turns the list over or asks whether it was.
    func testNothingTurnsTheListOver() throws {
        let files = Self.wholeFiles + [
            Self.controller,
            "Sources/QuickPaste/QuickPasteLayout.swift",
            "Sources/QuickPaste/QuickPasteSelection.swift",
        ]
        for path in files {
            let text = try Self.source(path)
            XCTAssertFalse(text.contains("isFlipped"), "\(path) still asks whether the panel is turned over")
            XCTAssertFalse(text.contains("reversed()"), "\(path) reverses something")
        }
        // The rows are the entries, in the entries' own order.
        let panel = try Self.source(Self.panel)
        XCTAssertTrue(panel.contains("entries.map { entry in"), "the panel's rows are not the entries in order")
    }

    /// The age (#211): each row's label is `QuickPasteAge` of the entry's own date against
    /// one moment per reveal, which the controller takes from the clock exactly once and
    /// the snapshot hook fixes, so its pictures do not change between runs.
    func testTheAgeIsMeasuredOnceAgainstTheMomentOfReveal() throws {
        let panel = try Self.source(Self.panel)
        let controller = try Self.source(Self.controller)
        let hook = try Self.source("WhisperKey/QuickPasteSnapshotHook.swift")

        XCTAssertTrue(
            panel.contains("age: QuickPasteAge.label(capturedAt: entry.capturedAt, now: now)"),
            "the panel does not give a row its entry's age"
        )
        XCTAssertFalse(panel.contains("Date()"), "the panel reads the clock itself, on every repaint")

        XCTAssertTrue(
            controller.contains("QuickPasteContent(entries: entries, now: Date())"),
            "the controller does not measure the ages against the moment of reveal"
        )
        XCTAssertEqual(Self.count("Date()", in: controller), 1, "the controller reads the clock more than once")

        XCTAssertTrue(
            hook.contains("QuickPasteContent(entries: entries, now: now)"),
            "the snapshot hook does not pass its fixed moment"
        )
        XCTAssertTrue(
            hook.contains("static let now = Date(timeIntervalSinceReferenceDate: 0)"),
            "the snapshot hook's moment is not fixed"
        )
        XCTAssertFalse(hook.contains("Date()"), "the snapshot hook reads the clock, so its pictures change between runs")
        // And its invented entries are dated back from that moment, each by its own age,
        // so the pictures show more than one label.
        XCTAssertTrue(
            hook.contains("capturedAt: now.addingTimeInterval(-$0.age)"),
            "the snapshot hook's entries are not dated against its fixed moment"
        )
    }

    /// The copied entry's symbol is a one-line swap: its name is written once.
    func testTheCopiedSymbolIsWrittenOnce() throws {
        var total = 0
        for path in Self.wholeFiles + [Self.controller] {
            let text = try String(contentsOf: SettingsSourceScanTests.repositoryURL().appendingPathComponent(path), encoding: .utf8)
            total += Self.count("\"command\"", in: text)
        }
        XCTAssertEqual(total, 1)
    }
}
