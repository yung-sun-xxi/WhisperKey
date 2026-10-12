import AppKit
import QuickPaste
import SwiftUI
import XCTest
@testable import ThemeKit

/// The quick paste popup (#166): its geometry comes from the tokens, and what it draws
/// lies exactly where `QuickPasteLayout` says a pointer chooses.
///
/// The panel takes no mouse events, so which row is chosen is computed from
/// `QuickPasteLayout` while the view draws the rows itself. If the two used different
/// numbers the highlight would sit on one row and the release would paste another. These
/// tests host the view the way the app does and hold its pixels to the hit test.
@MainActor
final class QuickPasteThemeTests: XCTestCase {
    private let midnight = ThemeTokens.midnight

    // MARK: - Metrics from the tokens

    func testMidnightMetricsAreTheDesignGrid() {
        // 328 wide (the sheet's "quick paste 328") with a 1 edge, a 36 header bar (panel
        // bar), a 1 separator, 34 list rows, rows inset 8 from the shell.
        XCTAssertEqual(
            midnight.quickPasteMetrics,
            QuickPasteMetrics(width: 328, edgeWidth: 1, headerHeight: 36, separatorHeight: 1, rowHeight: 34, rowInset: 8)
        )
    }

    func testMetricsAreReadFromTheTokensTheyName() {
        let metrics = midnight.quickPasteMetrics
        XCTAssertEqual(metrics.width, midnight.panels.quickPaste.width)
        XCTAssertEqual(metrics.edgeWidth, midnight.panels.quickPaste.edgeWidth)
        XCTAssertEqual(metrics.headerHeight, midnight.sizes.panelBar)
        XCTAssertEqual(metrics.separatorHeight, midnight.panels.quickPaste.edgeWidth)
        XCTAssertEqual(metrics.rowHeight, midnight.sizes.listRow)
        XCTAssertEqual(metrics.rowInset, midnight.spacing.rowInset)
    }

    /// The token sheet's "Quick paste popup" section, read from the file: the height
    /// formula and the marker are the tokens'.
    func testTheSheetsQuickPasteSectionIsTheTokens() throws {
        let section = try TokenSheet.load().section("Quick paste popup")
        let m = midnight.quickPasteMetrics
        func n(_ value: CGFloat) -> String { String(Int(value)) }
        let formula = "Panel height = \(n(m.edgeWidth)) (edge) + \(n(m.headerHeight)) + \(n(m.separatorHeight)) (separator) + \(n(m.rowInset)) + rows × \(n(m.rowHeight)) + \(n(m.rowInset)) + \(n(m.edgeWidth)) (edge)"
        XCTAssertTrue(section.contains(formula), formula)
        XCTAssertTrue(section.contains("**\(n(midnight.sizes.panelBar))** tall (panel bar)"), section)
        XCTAssertTrue(section.contains("clipped by the shell's radius \(n(midnight.panels.quickPaste.radius))"), section)

        let marker = midnight.quickPasteMarker
        XCTAssertTrue(section.contains("\(n(marker.width)) wide, leading, on every row; \(n(marker.gap)) gap before the text"), section)
        XCTAssertTrue(section.contains("| marker symbol | \(n(marker.font.size))pt, 07"), section)
        XCTAssertTrue(section.contains("SF Symbol **`\(ThemedQuickPasteView.dictatedSymbol)`**, `.semibold`"), section)
        XCTAssertTrue(section.contains("SF Symbol **`\(ThemedQuickPasteView.copiedSymbol)`**, `.semibold`"), section)
        XCTAssertEqual(marker.font.weight, .semibold)
    }

    func testBothThemesShareOneGeometry() {
        XCTAssertEqual(ThemeTokens.classic.quickPasteMetrics, midnight.quickPasteMetrics)
        XCTAssertEqual(ThemeTokens.classic.quickPasteMarker, midnight.quickPasteMarker)
    }

    func testPanelSizeFromTheTokens() {
        let metrics = midnight.quickPasteMetrics
        XCTAssertEqual(QuickPasteLayout.panelSize(entryCount: 0, metrics: metrics), CGSize(width: 328, height: 89))
        XCTAssertEqual(QuickPasteLayout.panelSize(entryCount: 5, metrics: metrics), CGSize(width: 328, height: 225))
    }

    func testMarkerTokens() {
        let marker = midnight.quickPasteMarker
        // An 11pt semibold symbol in a 14 column, 8 before the text; both markers alike
        // but for their shape.
        XCTAssertEqual(marker.width, 14)
        XCTAssertEqual(marker.gap, 8)
        XCTAssertEqual(marker.font, ThemeFont(size: 11, weight: .semibold))
    }

    func testTheCopiedMarkerSymbolIsOneConstant() {
        XCTAssertEqual(ThemedQuickPasteView.copiedSymbol, "command")
        XCTAssertEqual(ThemedQuickPasteView.dictatedSymbol, "waveform")
    }

    // MARK: - The view is as big as the window the layout sizes

    func testTheDrawnPanelIsAsTallAsTheLayoutSaysForEveryCount() {
        for count in [0, 1, 2, 5, 9] {
            let host = NSHostingView(rootView: panel(rows: rows(count), selected: nil))
            XCTAssertEqual(
                host.fittingSize,
                QuickPasteLayout.panelSize(entryCount: count, metrics: midnight.quickPasteMetrics),
                "\(count) entries"
            )
        }
    }

    func testALongEntryDoesNotWidenOrWrapThePanel() {
        let long = ThemedQuickPasteView.Row(
            id: UUID(),
            text: String(repeating: "a long dictated sentence ", count: 12),
            marker: .dictated
        )
        let host = NSHostingView(rootView: panel(rows: [long], selected: nil))
        XCTAssertEqual(host.fittingSize, QuickPasteLayout.panelSize(entryCount: 1, metrics: midnight.quickPasteMetrics))
    }

    // MARK: - What is drawn is where the pointer chooses

    func testTheSelectionIsDrawnInTheBandTheHitTestChooses() throws {
        let metrics = midnight.quickPasteMetrics
        let entries = rows(5)
        let size = QuickPasteLayout.panelSize(entryCount: 5, metrics: metrics)
        let frame = CGRect(origin: .zero, size: size)

        for selectedSlot in 0..<5 {
            let image = try render(panel(rows: entries, selected: entries[selectedSlot].id), size: size)

            for slot in 0..<5 {
                // The band the hit test gives this slot, found by asking it.
                let band = try hitBand(slot: slot, count: 5, frame: frame, metrics: metrics)
                let isSelected = slot == selectedSlot
                // Mid-row, right of any text, and one point inside the band's top and bottom.
                let x = size.width / 2 + 60
                for y in [band.top - 1, band.mid, band.bottom + 1] {
                    let colour = image.colour(x: x, screenY: y, height: size.height)
                    XCTAssertEqual(
                        colour.matches(midnight.colors.selectedRow),
                        isSelected,
                        "selected \(selectedSlot), slot \(slot), y \(y): \(colour)"
                    )
                }
                // The red bar at the row's leading edge, vertically centred.
                let bar = image.colour(x: barX(metrics), screenY: band.mid, height: size.height)
                XCTAssertEqual(
                    bar.matches(midnight.colors.brand),
                    isSelected,
                    "bar: selected \(selectedSlot), slot \(slot): \(bar)"
                )
            }
        }
    }

    func testTheBarIsTheSelectionBarTokenTallAndWide() throws {
        let metrics = midnight.quickPasteMetrics
        let entries = rows(1)
        let size = QuickPasteLayout.panelSize(entryCount: 1, metrics: metrics)
        let image = try render(panel(rows: entries, selected: entries[0].id), size: size)
        let band = try hitBand(slot: 0, count: 1, frame: CGRect(origin: .zero, size: size), metrics: metrics)
        let bar = midnight.sizes.selectionBar
        let left = metrics.edgeWidth + metrics.rowInset

        // Measured down the bar's column, a point at a time: the points that read nearer
        // the brand red than the row's fill (the antialiased rounded ends count) are the
        // bar. 18 of them, centred on the band the hit test gives the row.
        let ys = stride(from: band.bottom + 0.5, to: band.top, by: 1).filter { y in
            image.colour(x: barX(metrics), screenY: y, height: size.height)
                .isNearer(to: midnight.colors.brand, than: midnight.colors.selectedRow)
        }
        XCTAssertEqual(CGFloat(ys.count), bar.height, "bar points: \(ys)")
        let first = try XCTUnwrap(ys.min())
        let last = try XCTUnwrap(ys.max())
        XCTAssertEqual((first + last) / 2, band.mid, accuracy: 0.01, "the bar is centred in the row")
        XCTAssertTrue(image.colour(x: barX(metrics), screenY: band.mid, height: size.height).matches(midnight.colors.brand))
        // Right of the 2: the row's fill.
        XCTAssertFalse(image.colour(x: left + bar.width + 1, screenY: band.mid, height: size.height).matches(midnight.colors.brand))
        XCTAssertTrue(image.colour(x: left + bar.width + 1, screenY: band.mid, height: size.height).matches(midnight.colors.selectedRow))
    }

    func testNoSelectionDrawsNoFillAndNoBar() throws {
        let metrics = midnight.quickPasteMetrics
        let size = QuickPasteLayout.panelSize(entryCount: 3, metrics: metrics)
        let image = try render(panel(rows: rows(3), selected: nil), size: size)
        for slot in 0..<3 {
            let band = try hitBand(slot: slot, count: 3, frame: CGRect(origin: .zero, size: size), metrics: metrics)
            XCTAssertFalse(image.colour(x: size.width / 2 + 60, screenY: band.mid, height: size.height).matches(midnight.colors.selectedRow))
            XCTAssertFalse(image.colour(x: barX(metrics), screenY: band.mid, height: size.height).matches(midnight.colors.brand))
        }
    }

    // MARK: - The header bar

    /// The bar fills the band between the top edge and the separator, uncovered by the
    /// edge; the separator is the 1 line under it; the 8 above the first row is the shell.
    func testTheHeaderBarSeparatorAndGapAreWhereTheMetricsPutThem() throws {
        let metrics = midnight.quickPasteMetrics
        let size = QuickPasteLayout.panelSize(entryCount: 2, metrics: metrics)
        let image = try render(panel(rows: rows(2), selected: nil), size: size)
        let top = size.height
        // Right of the "CLIPBOARD" label, clear of the rounded corners.
        let x = size.width / 2 + 60
        func at(_ y: CGFloat) -> Sample { image.colour(x: x, screenY: y, height: size.height) }

        let barTop = top - metrics.edgeWidth
        let barBottom = barTop - metrics.headerHeight
        let separatorBottom = barBottom - metrics.separatorHeight
        let rowsTop = separatorBottom - metrics.rowInset

        XCTAssertTrue(at(top - 0.25).matches(midnight.colors.edge), "the top edge: \(at(top - 0.25))")
        for y in [barTop - 0.25, barTop - metrics.headerHeight / 2, barBottom + 0.25] {
            XCTAssertTrue(at(y).matches(midnight.colors.bar), "bar at y \(y): \(at(y))")
        }
        XCTAssertTrue(at(barBottom - 0.25).matches(midnight.colors.divider), "separator: \(at(barBottom - 0.25))")
        for y in [separatorBottom - 0.25, rowsTop + 0.25] {
            XCTAssertFalse(at(y).matches(midnight.colors.divider), "gap at y \(y): \(at(y))")
            XCTAssertFalse(at(y).matches(midnight.colors.bar), "gap at y \(y): \(at(y))")
        }
        // And the hit test agrees: everything down to rowsTop is not a row, rowsTop is.
        let frame = CGRect(origin: .zero, size: size)
        XCTAssertNil(QuickPasteLayout.highlightedIndex(mouse: CGPoint(x: x, y: rowsTop + 0.25), panelFrame: frame, entryCount: 2, metrics: metrics))
        XCTAssertEqual(QuickPasteLayout.highlightedIndex(mouse: CGPoint(x: x, y: rowsTop), panelFrame: frame, entryCount: 2, metrics: metrics), 0)
    }

    // MARK: - The popover's row keeps its hover

    func testAnExternallySelectedRowDrawsTheBarAndAHoverRowDoesNot() throws {
        let size = CGSize(width: 200, height: midnight.sizes.listRow)
        let selected = try render(
            ThemedRoot("test", source: ThemeTokensSource(theme: .midnight)) {
                ThemedListRow(isSelected: true) { Text("a") }.frame(width: 200)
            },
            size: size
        )
        let plain = try render(
            ThemedRoot("test", source: ThemeTokensSource(theme: .midnight)) {
                ThemedListRow { Text("a") }.frame(width: 200)
            },
            size: size
        )
        let mid = size.height / 2
        XCTAssertTrue(selected.colour(x: 1, screenY: mid, height: size.height).matches(midnight.colors.brand))
        XCTAssertTrue(selected.colour(x: 150, screenY: mid, height: size.height).matches(midnight.colors.selectedRow))
        XCTAssertFalse(plain.colour(x: 1, screenY: mid, height: size.height).matches(midnight.colors.brand))
        XCTAssertFalse(plain.colour(x: 150, screenY: mid, height: size.height).matches(midnight.colors.selectedRow))
    }

    // MARK: - Helpers

    /// The middle of the selection bar's column: the row's leading edge (inside the shell's
    /// edge and the row inset) plus half the bar.
    private func barX(_ metrics: QuickPasteMetrics) -> CGFloat {
        metrics.edgeWidth + metrics.rowInset + midnight.sizes.selectionBar.width / 2
    }

    private func rows(_ count: Int) -> [ThemedQuickPasteView.Row] {
        (0..<count).map { index in
            ThemedQuickPasteView.Row(id: UUID(), text: "e\(index)", marker: index.isMultiple(of: 2) ? .dictated : .copied)
        }
    }

    private func panel(rows: [ThemedQuickPasteView.Row], selected: UUID?) -> some View {
        ThemedRoot("test", source: ThemeTokensSource(theme: .midnight)) {
            ThemedQuickPasteView(metrics: midnight.quickPasteMetrics, rows: rows, selectedID: selected)
        }
    }

    /// The vertical band, in screen coordinates of a panel at `frame`, in which the hit
    /// test answers `slot`: found by walking the panel a quarter point at a time.
    private func hitBand(slot: Int, count: Int, frame: CGRect, metrics: QuickPasteMetrics) throws -> (top: CGFloat, mid: CGFloat, bottom: CGFloat) {
        var ys: [CGFloat] = []
        var y = frame.maxY
        while y >= frame.minY {
            if QuickPasteLayout.highlightedIndex(
                mouse: CGPoint(x: frame.midX, y: y),
                panelFrame: frame,
                entryCount: count,
                metrics: metrics
            ) == slot {
                ys.append(y)
            }
            y -= 0.25
        }
        let top = try XCTUnwrap(ys.max(), "no band for slot \(slot)")
        let bottom = try XCTUnwrap(ys.min())
        return (top, (top + bottom) / 2, bottom)
    }

    private func render(_ view: some View, size: CGSize) throws -> Snapshot {
        try XCTUnwrap(Snapshot.render(view, size: size))
    }
}

/// A token's colour as the renderer produces it.
@MainActor
private enum Swatch {
    private static var cache: [ThemeColor: NSColor] = [:]

    static func colour(_ token: ThemeColor) -> NSColor? {
        if let known = cache[token] { return known }
        let size = CGSize(width: 8, height: 8)
        let swatch = Snapshot.render(Rectangle().fill(token.color), size: size)?
            .colour(x: 4, screenY: 4, height: size.height).colour
        cache[token] = swatch
        return swatch
    }
}

/// A rendered view, read a point at a time.
struct Snapshot {
    let rep: NSBitmapImageRep
    let scale: CGFloat

    /// Hosts `view` in a borderless window at `size` and caches what it draws.
    @MainActor
    static func render(_ view: some View, size: CGSize) -> Snapshot? {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return Snapshot(rep: rep, scale: CGFloat(rep.pixelsWide) / size.width)
    }

    /// The colour at view x and at screen y of a panel whose bottom is at y 0.
    func colour(x: CGFloat, screenY: CGFloat, height: CGFloat) -> Sample {
        let px = Int((x * scale).rounded(.down))
        let py = Int(((height - screenY) * scale).rounded(.down))
        let colour = rep.colorAt(x: min(max(px, 0), rep.pixelsWide - 1), y: min(max(py, 0), rep.pixelsHigh - 1))
        return Sample(colour: colour?.usingColorSpace(.sRGB))
    }
}

struct Sample: CustomStringConvertible {
    let colour: NSColor?

    /// Within a few levels of what `token` renders as, drawn alone through the same
    /// hosting and caching as the panel, so colour management treats both alike.
    @MainActor
    func matches(_ token: ThemeColor) -> Bool {
        guard let colour, let swatch = Swatch.colour(token) else { return false }
        let tolerance: CGFloat = 0.02
        return abs(colour.alphaComponent - swatch.alphaComponent) < tolerance
            && abs(colour.redComponent - swatch.redComponent) < tolerance
            && abs(colour.greenComponent - swatch.greenComponent) < tolerance
            && abs(colour.blueComponent - swatch.blueComponent) < tolerance
    }

    /// Nearer `a` than `b` as each renders, by the sum of the channel distances.
    @MainActor
    func isNearer(to a: ThemeColor, than b: ThemeColor) -> Bool {
        guard let colour, let ca = Swatch.colour(a), let cb = Swatch.colour(b) else { return false }
        func distance(_ other: NSColor) -> CGFloat {
            abs(colour.redComponent - other.redComponent)
                + abs(colour.greenComponent - other.greenComponent)
                + abs(colour.blueComponent - other.blueComponent)
        }
        return distance(ca) < distance(cb)
    }

    var description: String {
        guard let colour else { return "nil" }
        return String(format: "rgba(%.3f, %.3f, %.3f, %.3f)", colour.redComponent, colour.greenComponent, colour.blueComponent, colour.alphaComponent)
    }
}
