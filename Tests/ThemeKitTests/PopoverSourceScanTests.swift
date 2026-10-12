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
        "Sources/ThemeKit/ThemedPanelShell.swift",
        "Sources/ThemeKit/ThemedListRow.swift",
        "Sources/ThemeKit/ThemedPeriodPicker.swift",
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
            "struct HeaderOutputToggle",
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
