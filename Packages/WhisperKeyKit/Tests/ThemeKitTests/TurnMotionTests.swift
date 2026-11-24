import XCTest
@testable import ThemeKit

/// The Retry arrow's motion: smooth at both joints, and at rest soon after the work ends.
final class TurnMotionTests: XCTestCase {
    func testTheStartEasesFromRestToTheSteadySpeed() {
        let motion = TurnMotion()
        XCTAssertEqual(motion.angle(after: 0), 0)
        XCTAssertEqual(motion.velocity(after: 0), 0)
        XCTAssertEqual(motion.velocity(after: TurnMotion.rampDuration), TurnMotion.speed, accuracy: 1e-9)
        let before = motion.angle(after: TurnMotion.rampDuration - 1e-6)
        XCTAssertEqual(motion.angle(after: TurnMotion.rampDuration), before, accuracy: 0.01)
        XCTAssertEqual(motion.angle(after: 2) - motion.angle(after: 1), 360, accuracy: 1e-9)
    }

    /// Wherever the work ends, the stop takes over the angle and the speed, never turns
    /// back, and ends upright and at rest within its bounds.
    func testTheStopIsSmoothAndEndsUpright() {
        let motion = TurnMotion()
        for step in 1...300 {
            let elapsed = Double(step) / 100
            let settle = motion.settle(after: elapsed)
            let h = 1e-5
            XCTAssertEqual(settle.angle(after: 0), motion.angle(after: elapsed), accuracy: 1e-9, "\(elapsed)")
            XCTAssertEqual((settle.angle(after: h) - settle.angle(after: 0)) / h, motion.velocity(after: elapsed), accuracy: 0.5, "\(elapsed)")
            XCTAssertEqual((settle.end - settle.angle(after: settle.duration - h)) / h, 0, accuracy: 0.5, "\(elapsed)")
            XCTAssertEqual(settle.angle(after: settle.duration), settle.end, "\(elapsed)")
            XCTAssertEqual(settle.end.truncatingRemainder(dividingBy: 360), 0, "\(elapsed)")
            XCTAssertTrue(TurnMotion.settleDurations.contains(settle.duration), "\(elapsed)")
            var last = settle.from
            for i in 1...100 {
                let angle = settle.angle(after: settle.duration * Double(i) / 100)
                XCTAssertGreaterThanOrEqual(angle, last - 1e-9, "turns back at \(elapsed)")
                last = angle
            }
        }
    }

    /// A retry caught during a stop goes on from the angle the stop had reached.
    func testATurnCaughtDuringAStopGoesOnFromThere() {
        XCTAssertEqual(TurnMotion(from: 123).angle(after: 0), 123)
    }
}
