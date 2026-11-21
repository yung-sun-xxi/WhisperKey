import Foundation
import XCTest

/// No hard-coded colour or size in the menu bar popover (#161): every colour, font and
/// size there comes from the theme tokens.
///
/// The same scan as `SettingsSourceScanTests`, over the popover's code: the stretches of
/// `WhisperKey/SettingsView.swift` and `WhisperKey/MenuBarController.swift` between
/// `// MARK: - Themed Popover begin` and `// MARK: - Themed Popover end` markers, the
/// history list read whole, and the shared panel shell, list row and period picker that
/// the popover builds for the other floating panels.
final class PopoverSourceScanTests: XCTestCase {
    static let beginMarker = "// MARK: - Themed Popover begin"
    static let endMarker = "// MARK: - Themed Popover end"

    private static let markedFiles = [
        "WhisperKey/SettingsView.swift",
        "WhisperKey/MenuBarController.swift",
    ]

    private static let wholeFiles = [
        "WhisperKey/HistorySection.swift",
        "Packages/WhisperKeyKit/Sources/ThemeKit/ThemedPanelShell.swift",
        "Packages/WhisperKeyKit/Sources/ThemeKit/ThemedListRow.swift",
        "Packages/WhisperKeyKit/Sources/ThemeKit/ThemedPeriodPicker.swift",
    ]

    private static func popoverRegions() throws -> [SettingsSourceScanTests.Region] {
        try markedFiles.flatMap {
            try SettingsSourceScanTests.markedRegions(in: $0, begin: beginMarker, end: endMarker)
        }
    }

    func testThePopoverIsMarked() throws {
        let popoverCode = try Self.popoverRegions().map(\.text).joined(separator: "\n")
        // The markers enclose the popover, not a corner of it.
        for name in [
            "struct PopoverContent",
            "struct PermissionBanner",
            "struct DevBuildBadge",
            "struct CommandCenterHeader",
            "struct CancelStatusIcon",
            "struct UsageSummaryRow",
            "struct UsageMetricColumn",
            "struct HeaderVerticalDivider",
            "func configurePanel",
            "func updatePanelSize",
            "class MenuBarPanel",
        ] {
            XCTAssertTrue(popoverCode.contains(name), "\(name) is outside the themed popover section")
        }
        // ...and leave out what the Usage by model window (#170) and Settings still use.
        for name in [
            "struct HeaderPeriodPicker",
            "enum HeaderSurfaceColor",
            "enum UsageLineFormatter",
            "struct SettingsRow",
            "func positionPanel",
        ] {
            XCTAssertFalse(popoverCode.contains(name), "\(name) is inside the themed popover section")
        }
    }

    /// A failed popover row reads text, copied check, Retry, age (#228): the age keeps the
    /// trailing column every other row keeps, as the full history window's row does. The
    /// age is its own element after Retry, outside the inner row-tap stack, and still
    /// carries the row's actions.
    func testAFailedPopoverRowPutsRetryBeforeTheAge() throws {
        let raw = try String(
            contentsOf: SettingsSourceScanTests.repositoryURL().appendingPathComponent("WhisperKey/HistorySection.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(raw.range(of: "private struct HistoryInlineRow"), "HistoryInlineRow is gone")
        let end = try XCTUnwrap(raw.range(of: "private var displayText", range: start.upperBound..<raw.endIndex), "the row's text is gone")
        let row = String(raw[start.lowerBound..<end.lowerBound])
        let retry = try XCTUnwrap(row.range(of: "ThemedFailureButton(\"Retry\""), "the row lost its Retry button")
        let age = try XCTUnwrap(row.range(of: "Text(age)"), "the row lost its age")
        XCTAssertLessThan(retry.lowerBound, age.lowerBound, "the age comes before Retry")

        // The inner stack the row's click lands on (text and check) closes with the row's
        // actions before Retry and the age are drawn.
        let rowActions = ".modifier(InlineRowActions("
        let innerClose = try XCTUnwrap(
            [row.range(of: ".onTapGesture"), row.range(of: rowActions)].compactMap { $0?.lowerBound }.min(),
            "the row lost its click"
        )
        XCTAssertLessThan(innerClose, retry.lowerBound, "Retry sits inside the row's tap area")
        XCTAssertLessThan(innerClose, age.lowerBound, "the age sits inside the inner row-tap stack")
        XCTAssertTrue(row[age.upperBound...].contains(rowActions), "the age does not carry the row's click, menu and tooltip")

        // The actions themselves: the click, the menu with Retry, the tooltip.
        let actionsStart = try XCTUnwrap(raw.range(of: "private struct InlineRowActions"), "the row's actions are gone")
        let actions = String(raw[actionsStart.lowerBound...])
        for item in [".onTapGesture(perform: primaryClick)", ".contextMenu", "Button(\"Retry\", action: onRetry)", ".help(help)"] {
            XCTAssertTrue(actions.contains(item), "the row's actions lost \(item)")
        }
    }

    func testThePopoverHoldsNoLiteralColourOrSize() throws {
        var regions = try Self.popoverRegions()
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
}
