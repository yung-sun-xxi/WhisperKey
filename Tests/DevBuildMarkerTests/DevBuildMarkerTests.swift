// The module under test exists only under DEBUG; `swift test` builds debug.
#if DEBUG
import AppKit
import XCTest
@testable import DevBuildMarker

final class DevBuildMarkerTests: XCTestCase {

    /// Stands in for the menu bar asset, which lives in the app's catalog: an
    /// 18x15 pt opaque block, deliberately not a template.
    private func makeBase() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 15), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Renders the image at 2x into a bitmap so its pixels can be inspected.
    private func render(_ image: NSImage) -> NSBitmapImageRep {
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((image.size.width * scale).rounded(.up)),
            pixelsHigh: Int((image.size.height * scale).rounded(.up)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func opaquePixelCount(in rep: NSBitmapImageRep, fromX minX: Int, toX maxX: Int) -> Int {
        var count = 0
        for x in minX..<maxX {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                count += 1
            }
        }
        return count
    }

    func testLetterIsD() {
        XCTAssertEqual(DevBuildMarker.letter, "D")
    }

    func testMarkedImageIsWiderThanBase() {
        let base = makeBase()
        let marked = DevBuildMarker.markedMenuBarImage(base)
        XCTAssertGreaterThan(marked.size.width, base.size.width)
    }

    func testMarkedImageIsTemplate() {
        let marked = DevBuildMarker.markedMenuBarImage(makeBase())
        XCTAssertTrue(marked.isTemplate, "a non-template image ignores light and dark menu bars")
    }

    func testLetterIsDrawnRightOfBase() {
        let base = makeBase()
        let marked = DevBuildMarker.markedMenuBarImage(base)
        let rep = render(marked)
        let baseEdge = Int((base.size.width * 2).rounded(.up))
        XCTAssertGreaterThan(
            opaquePixelCount(in: rep, fromX: baseEdge, toX: rep.pixelsWide),
            20,
            "no letter pixels right of the icon"
        )
    }

    func testBaseRegionStillHoldsTheIcon() {
        let base = makeBase()
        let marked = DevBuildMarker.markedMenuBarImage(base)
        let rep = render(marked)
        let baseWidth = Int((base.size.width * 2).rounded(.down))
        let baseHeight = Int((base.size.height * 2).rounded(.down))
        // The opaque block covers the whole base region, so at least its full area
        // must come back opaque there.
        XCTAssertGreaterThanOrEqual(
            opaquePixelCount(in: rep, fromX: 0, toX: baseWidth),
            baseWidth * baseHeight
        )
    }
}
#endif
