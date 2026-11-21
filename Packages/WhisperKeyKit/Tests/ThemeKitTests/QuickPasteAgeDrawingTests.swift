import AppKit
import QuickPaste
import SettingsStore
import SwiftUI
import XCTest
@testable import ThemeKit

/// The age a quick paste row shows (#211): drawn, against the row's trailing edge, in
/// `secondaryText`, whole however long the entry is, in both themes.
///
/// A row's `body` cannot be called from a test, but it can be rendered. Each claim here is
/// a comparison of two renders that differ in one thing: the pixels that changed are what
/// that one thing draws.
@MainActor
final class QuickPasteAgeDrawingTests: XCTestCase {
    private struct Theme {
        let name: String
        let theme: AppTheme
        let tokens: ThemeTokens
    }

    private let themes = [
        Theme(name: "midnight", theme: .midnight, tokens: .midnight),
        Theme(name: "daylight", theme: .daylight, tokens: .daylight),
    ]

    /// A solid block: whatever the screen's scale, some pixel of it is fully covered, so
    /// its colour can be read exactly rather than through an antialiased edge.
    private static let block = "\u{2588}\u{2588}"

    private static let longEntry = String(repeating: "a long dictated sentence ", count: 12)

    // MARK: - It is drawn, and where

    func testARowDrawsItsAgeAgainstItsTrailingEdge() throws {
        for theme in themes {
            let without = try render(theme, text: "e0", age: "")
            let with = try render(theme, text: "e0", age: "3d")
            let ink = try XCTUnwrap(Self.box(of: without, differingFrom: with), "\(theme.name): the age draws nothing")

            let trailing = trailingEdge(theme)
            let width = Snapshot.fittingSize(Text("3d").font(theme.tokens.type.caption.font)).width
            // Right-aligned: the last glyph ends at the row's padding, give or take its
            // side bearing, and the label is no wider than its own text.
            XCTAssertLessThanOrEqual(ink.maxX, trailing + 0.5, "\(theme.name): \(ink)")
            XCTAssertGreaterThanOrEqual(ink.maxX, trailing - 2, "\(theme.name): \(ink)")
            XCTAssertGreaterThanOrEqual(ink.minX, trailing - width - 1, "\(theme.name): \(ink)")
            // Inside the one row, not above or under it.
            let band = rowBand(theme)
            XCTAssertGreaterThanOrEqual(ink.minY, band.lowerBound, "\(theme.name): \(ink)")
            XCTAssertLessThanOrEqual(ink.maxY, band.upperBound, "\(theme.name): \(ink)")
        }
    }

    func testEveryLabelIsDrawn() throws {
        for theme in themes {
            let without = try render(theme, text: "e0", age: "")
            var widths: [CGFloat] = []
            for age in ["3d", "59m", "400d"] {
                let with = try render(theme, text: "e0", age: age)
                let ink = try XCTUnwrap(Self.box(of: without, differingFrom: with), "\(theme.name) \(age)")
                widths.append(ink.width)
            }
            // More characters, more ink: the label drawn is the label given.
            XCTAssertEqual(widths, widths.sorted(), "\(theme.name): \(widths)")
            XCTAssertLessThan(widths[0], widths[2], "\(theme.name): \(widths)")
        }
    }

    // MARK: - Its colour

    func testTheAgeIsSecondaryTextAndTheEntryIsPrimary() throws {
        for theme in themes {
            let blank = try render(theme, text: "", age: "")

            let age = try render(theme, text: "", age: Self.block)
            let ageInk = try XCTUnwrap(Self.box(of: blank, differingFrom: age), "\(theme.name): no age")
            let ageColour = age.colour(x: ageInk.midX, screenY: ageInk.midY, height: age.height)
            XCTAssertTrue(ageColour.matches(theme.tokens.colors.secondaryText), "\(theme.name): the age is \(ageColour)")
            XCTAssertFalse(ageColour.matches(theme.tokens.colors.primaryText), "\(theme.name): the age is \(ageColour)")

            // The same reading of the entry's own text, so the method is seen telling the
            // two colours apart.
            let entry = try render(theme, text: Self.block, age: "")
            let entryInk = try XCTUnwrap(Self.box(of: blank, differingFrom: entry), "\(theme.name): no entry text")
            let entryColour = entry.colour(x: entryInk.midX, screenY: entryInk.midY, height: entry.height)
            XCTAssertTrue(entryColour.matches(theme.tokens.colors.primaryText), "\(theme.name): the entry is \(entryColour)")
        }
    }

    // MARK: - A long entry gives way to it

    func testALongEntryIsCutBeforeTheAgeAndTheAgeStaysWhole() throws {
        for theme in themes {
            let gap = theme.tokens.quickPasteMarker.gap
            let alone = try render(theme, text: "e0", age: "")
            // The narrowest label and the widest.
            for age in ["now", "400d"] {
                let short = try render(theme, text: "e0", age: age)
                let cut = try render(theme, text: Self.longEntry, age: age)
                let what = "\(theme.name) \(age)"

                // Where the age is, when nothing competes with it for room.
                let ageInk = try XCTUnwrap(Self.box(of: alone, differingFrom: short), "\(what): no age")
                // What the long entry changes: its own text, and nothing else.
                let textInk = try XCTUnwrap(Self.box(of: short, differingFrom: cut), "\(what): the long entry draws as the short one")

                // The age is untouched: every changed pixel is left of it, by the row's gap.
                XCTAssertLessThanOrEqual(textInk.maxX, ageInk.minX - gap + 1, "\(what): the text runs into the age, text \(textInk) age \(ageInk)")
                // And the text is cut there, not earlier: it uses the room up to the gap.
                XCTAssertGreaterThanOrEqual(textInk.maxX, ageInk.minX - gap - 16, "\(what): the text stops short of the age, text \(textInk) age \(ageInk)")
            }
        }
    }

    func testALongEntryWithAnAgeDoesNotWidenOrWrapThePanel() {
        for theme in themes {
            let row = ThemedQuickPasteView.Row(id: UUID(), text: Self.longEntry, marker: .copied, age: "400d")
            let host = NSHostingView(rootView: panel(theme, rows: [row]))
            XCTAssertEqual(
                host.fittingSize,
                QuickPasteLayout.panelSize(entryCount: 1, metrics: theme.tokens.quickPasteMetrics),
                theme.name
            )
        }
    }

    // MARK: - Helpers

    /// The x at which a row's content ends: the panel's width less the shell's edge, the
    /// rows' inset and the row's own padding.
    private func trailingEdge(_ theme: Theme) -> CGFloat {
        let metrics = theme.tokens.quickPasteMetrics
        return metrics.width - metrics.edgeWidth - metrics.rowInset - theme.tokens.spacing.rowPadding
    }

    /// The first row's span, in points down from the panel's top.
    private func rowBand(_ theme: Theme) -> ClosedRange<CGFloat> {
        let metrics = theme.tokens.quickPasteMetrics
        return metrics.rowsTopOffset...(metrics.rowsTopOffset + metrics.rowHeight)
    }

    private func panel(_ theme: Theme, rows: [ThemedQuickPasteView.Row]) -> some View {
        ThemedRoot("test", source: ThemeTokensSource(theme: theme.theme)) {
            ThemedQuickPasteView(metrics: theme.tokens.quickPasteMetrics, rows: rows, selectedID: nil)
        }
    }

    /// A panel of one unselected row.
    private func render(_ theme: Theme, text: String, age: String) throws -> Render {
        let size = QuickPasteLayout.panelSize(entryCount: 1, metrics: theme.tokens.quickPasteMetrics)
        let row = ThemedQuickPasteView.Row(id: UUID(), text: text, marker: .copied, age: age)
        let snapshot = try XCTUnwrap(Snapshot.render(panel(theme, rows: [row]), size: size))
        return Render(snapshot: snapshot, height: size.height)
    }

    private struct Render {
        let snapshot: Snapshot
        let height: CGFloat

        func colour(x: CGFloat, screenY: CGFloat, height: CGFloat) -> Sample {
            snapshot.colour(x: x, screenY: screenY, height: height)
        }
    }

    /// A rectangle of ink, in points: x from the panel's leading edge, y down from its top.
    /// `midY` is turned over for `Snapshot.colour`, which counts up from the bottom.
    private struct InkBox: CustomStringConvertible {
        let minX: CGFloat
        let maxX: CGFloat
        let minY: CGFloat
        let maxY: CGFloat
        let height: CGFloat

        var width: CGFloat { maxX - minX }
        var midX: CGFloat { (minX + maxX) / 2 }
        var midY: CGFloat { height - (minY + maxY) / 2 }

        var description: String {
            String(format: "x %.1f...%.1f, y %.1f...%.1f", minX, maxX, minY, maxY)
        }
    }

    /// The smallest box around every pixel in which the two renders differ, or `nil` when
    /// they are the same picture.
    private static func box(of a: Render, differingFrom b: Render) -> InkBox? {
        let first = a.snapshot.rep
        let second = b.snapshot.rep
        guard first.pixelsWide == second.pixelsWide, first.pixelsHigh == second.pixelsHigh else { return nil }

        let samples = min(first.samplesPerPixel, second.samplesPerPixel)
        var one = [Int](repeating: 0, count: first.samplesPerPixel)
        var other = [Int](repeating: 0, count: second.samplesPerPixel)
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min

        for y in 0..<first.pixelsHigh {
            for x in 0..<first.pixelsWide {
                first.getPixel(&one, atX: x, y: y)
                second.getPixel(&other, atX: x, y: y)
                // Two levels of slack: the same drawing twice is the same pixels, and a
                // glyph's faintest antialiased edge is well above this.
                guard (0..<samples).contains(where: { abs(one[$0] - other[$0]) > 2 }) else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }

        let scale = a.snapshot.scale
        return InkBox(
            minX: CGFloat(minX) / scale,
            maxX: CGFloat(maxX + 1) / scale,
            minY: CGFloat(minY) / scale,
            maxY: CGFloat(maxY + 1) / scale,
            height: a.height
        )
    }
}
