import Foundation

/// How the Retry arrow turns, in degrees clockwise from rest and seconds: it eases up to
/// a steady turn, and on the end of the work eases on to rest, the next upright position.
/// Both joints are smooth: position and speed carry over.
struct TurnMotion: Equatable, Sendable {
    /// The steady speed: one turn a second. The owner picked it live.
    static let speed = 360.0
    /// How long the start takes to reach it.
    static let rampDuration = 0.3
    /// The least way left to rest; any shorter and the stop would be a jerk, so the arrow
    /// makes one more turn.
    static let leastSettle = 45.0
    /// The bounds on the stop. The result is on screen by then, so it is short, and a long
    /// way is made up by turning faster.
    static let settleDurations = 0.35...0.75

    /// Where the turn starts: 0, or wherever a stop was caught.
    var from = 0.0

    /// The angle `elapsed` seconds into the turn.
    func angle(after elapsed: Double) -> Double {
        let t = max(elapsed, 0)
        if t < Self.rampDuration {
            return from + Self.speed * t * t / (2 * Self.rampDuration)
        }
        return from + Self.speed * (t - Self.rampDuration / 2)
    }

    /// The speed `elapsed` seconds into the turn.
    func velocity(after elapsed: Double) -> Double {
        Self.speed * min(max(elapsed, 0) / Self.rampDuration, 1)
    }

    /// The stop that takes over `elapsed` seconds into the turn.
    func settle(after elapsed: Double) -> Settle {
        Settle(from: angle(after: elapsed), velocity: velocity(after: elapsed))
    }

    /// From an angle and a speed to rest.
    struct Settle: Equatable, Sendable {
        let from: Double
        let velocity: Double
        /// A whole number of turns: the arrow at rest.
        let end: Double
        let duration: Double

        init(from: Double, velocity: Double) {
            self.from = from
            self.velocity = velocity
            end = ((from + TurnMotion.leastSettle) / 360).rounded(.up) * 360
            let bounds = TurnMotion.settleDurations
            // An even slowdown would take this long.
            let even = velocity > 0 ? 2 * (end - from) / velocity : bounds.upperBound
            duration = min(max(even, bounds.lowerBound), bounds.upperBound)
        }

        /// The cubic from `from` at `velocity` to `end` at rest.
        func angle(after elapsed: Double) -> Double {
            guard elapsed < duration else { return end }
            let s = max(elapsed, 0) / duration
            let distance = end - from
            return from
                + velocity * duration * (s * s * s - 2 * s * s + s)
                + distance * (3 * s * s - 2 * s * s * s)
        }
    }
}
