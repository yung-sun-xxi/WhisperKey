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
        // 328 wide (the sheet's "quick paste 328"), a 34 header band like the popover's
        // "History" row, 34 list rows, rows inset 8 from the shell.
        XCTAssertEqual(
            midnight.quickPasteMetrics,
            QuickPasteMetrics(width: 328, headerHeight: 34, rowHeight: 34, rowInset: 8)
        )
    }

    func testMetricsAreReadFromTheTokensTheyName() {
        let metrics = midnight.quickPasteMetrics
        XCTAssertEqual(metrics.width, midnight.panels.quickPaste.width)
        XCTAssertEqual(metrics.headerHeight, midnight.sizes.listRow)
        XCTAssertEqual(metrics.rowHeight, midnight.sizes.listRow)
        XCTAssertEqual(metrics.rowInset, midnight.spacing.rowInset)
    }

    func testBothThemesShareOneGeometry() {
        XCTAssertEqual(ThemeTokens.classic.quickPasteMetrics, midnight.quickPasteMetrics)
        XCTAssertEqual(ThemeTokens.classic.quickPasteMarker, midnight.quickPasteMarker)
    }

    func testPanelSizeFromTheTokens() {
        let metrics = midnight.quickPasteMetrics
        XCTAssertEqual(QuickPasteLayout.panelSize(entryCount: 0, metrics: metrics), CGSize(width: 328, height: 76))
        XCTAssertEqual(QuickPasteLayout.panelSize(entryCount: 5, metrics: metrics), CGSize(width: 328, height: 212))
    }

    func testMarkerTokens() {
        let marker = midnight.quickPasteMarker
        // Today's marker sizes: an 11pt symbol in a 14 column, the dictated one heavier.
        XCTAssertEqual(marker.width, 14)
        XCTAssertEqual(marker.gap, 10)
        XCTAssertEqual(marker.dictated, ThemeFont(size: 11, weight: .semibold))
        XCTAssertEqual(marker.copied, ThemeFont(size: 11, weight: .regular))
        XCTAssertNotEqual(marker.dictated.weight, marker.copied.weight, "the two markers differ by weight")
    }

    func testTheCopiedMarkerSymbolIsOneConstant() {
        XCTAssertEqual(ThemedQuickPasteView.copiedSymbol, "doc.on.clipboard")
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
                let band = try hitBand(slot: slot, frame: frame, metrics: metrics)
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
                let bar = image.colour(x: metrics.rowInset + 1, screenY: band.mid, height: size.height)
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
        let band = try hitBand(slot: 0, frame: CGRect(origin: .zero, size: size), metrics: metrics)
        let bar = midnight.sizes.selectionBar
        let half = bar.height / 2
        let left = metrics.rowInset

        // Inside: 18 tall, centred; 2 wide from the row's leading edge.
        for y in [band.mid + half - 1, band.mid, band.mid - half + 1] {
            XCTAssertTrue(image.colour(x: left + 1, screenY: y, height: size.height).matches(midnight.colors.brand), "y \(y)")
        }
        // Outside: above and below the 18, and right of the 2.
        for y in [band.mid + half + 1, band.mid - half - 1] {
            XCTAssertFalse(image.colour(x: left + 1, screenY: y, height: size.height).matches(midnight.colors.brand), "y \(y)")
        }
        XCTAssertFalse(image.colour(x: left + bar.width + 1, screenY: band.mid, height: size.height).matches(midnight.colors.brand))
    }

    func testNoSelectionDrawsNoFillAndNoBar() throws {
        let metrics = midnight.quickPasteMetrics
        let size = QuickPasteLayout.panelSize(entryCount: 3, metrics: metrics)
        let image = try render(panel(rows: rows(3), selected: nil), size: size)
        for slot in 0..<3 {
            let band = try hitBand(slot: slot, frame: CGRect(origin: .zero, size: size), metrics: metrics)
            XCTAssertFalse(image.colour(x: size.width / 2 + 60, screenY: band.mid, height: size.height).matches(midnight.colors.selectedRow))
            XCTAssertFalse(image.colour(x: metrics.rowInset + 1, screenY: band.mid, height: size.height).matches(midnight.colors.brand))
        }
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
    private func hitBand(slot: Int, frame: CGRect, metrics: QuickPasteMetrics) throws -> (top: CGFloat, mid: CGFloat, bottom: CGFloat) {
        let count = Int((frame.height - metrics.headerHeight - metrics.rowInset) / metrics.rowHeight)
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

    var description: String {
        guard let colour else { return "nil" }
        return String(format: "rgba(%.3f, %.3f, %.3f, %.3f)", colour.redComponent, colour.greenComponent, colour.blueComponent, colour.alphaComponent)
    }
}
