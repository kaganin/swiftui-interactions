import Foundation

/// One rupture per reset. Crossing the calibrated burst line starts the tear.
struct GumRupture {
    private var elapsed: Float?
    var time: Float? { elapsed.map(Self.simulationTime) }
    var elapsedTime: Float? { elapsed }
    var isSettled: Bool { (elapsed ?? -1) >= 0.68 }

    /// Shared by the dome and membrane: immediate visible opening, then wet settling.
    /// This is an authored playback clock, not a change to material forces.
    static func simulationTime(for elapsed: Float) -> Float {
        let elapsed = min(max(elapsed, 0), 0.68)
        // A hairline puncture appears on contact. Elastic recoil is fast, then
        // the wet sheet spends the remaining time settling against the glass.
        if elapsed >= 0.68 { return 0.65 }
        return min(0.65, 0.028 + 0.05 * (1 - exp(-elapsed / 0.04)) + elapsed * 0.84118)
    }

    mutating func advance(touchingBurstLine: Bool, dt: Float, reducedMotion: Bool) -> Bool {
        if let elapsed {
            self.elapsed = reducedMotion ? 0.68 : min(0.68, elapsed + dt)
            return false
        }
        // The renderer tests shaded film at the burst line. A second strain
        // gate would leave the film visibly pressed there.
        guard touchingBurstLine else { return false }
        elapsed = reducedMotion ? 0.68 : 0
        return true
    }
}
