import Foundation

@main struct SwayChecks {
    static func main() {
        for rate in [30, 60, 120] {
            var sway = GumSway()
            let dt = Float(1) / Float(rate)
            for _ in 0..<(rate / 2) {
                sway.advance(dt: dt, inflation: 0.72, inflationSpeed: 0.18,
                             variation: 0.13, gravityX: 0, accelerationX: 0, reducedMotion: false)
            }
            let loaded = sway.offset
            precondition(loaded > 0.025 && loaded < 0.04,
                         "A breath should bend the free film gently at \(rate) fps")
            var crossed = false
            for _ in 0..<(rate * 2) {
                sway.advance(dt: dt, inflation: 0.72, inflationSpeed: 0,
                             variation: 0.13, gravityX: 0, accelerationX: 0, reducedMotion: false)
                crossed = crossed || sway.offset < 0
                precondition(abs(sway.offset) <= 0.045, "The mouth-bound film must stay bounded")
            }
            precondition(crossed && !sway.isMoving,
                         "Release should recoil and settle without perpetual floating")
            sway.advance(dt: dt, inflation: 0.72, inflationSpeed: 0.18,
                         variation: 0.13, gravityX: 0, accelerationX: 0, reducedMotion: true)
            precondition(sway.offset == 0 && !sway.isMoving,
                         "Reduce Motion must remove the secondary oscillation")
        }
        for rate in [30, 60, 120] {
            let dt = Float(1) / Float(rate)
            var tilted = GumSway()
            for _ in 0..<(rate * 2) {
                tilted.advance(dt: dt, inflation: 0.5, inflationSpeed: 0,
                               variation: 0.13, gravityX: 0.5, accelerationX: 0,
                               reducedMotion: false)
            }
            precondition(tilted.offset < -0.08, "A phone tilt must visibly bend the bubble")
            for _ in 0..<(rate * 2) {
                tilted.advance(dt: dt, inflation: 0.5, inflationSpeed: 0,
                               variation: 0.13, gravityX: -0.5, accelerationX: 0,
                               reducedMotion: false)
            }
            precondition(tilted.offset > 0.08, "Reversing tilt must reverse the bend")
            for _ in 0..<rate {
                tilted.advance(dt: dt, inflation: 0.8, inflationSpeed: 0,
                               variation: 0.13, gravityX: -1, accelerationX: -2,
                               reducedMotion: false)
                precondition(abs(tilted.offset) <= 0.0251, "Large bubbles must remain edge-constrained")
            }
            tilted.advance(dt: dt, inflation: 0.5, inflationSpeed: 0,
                           variation: 0.13, gravityX: 1, accelerationX: 2,
                           reducedMotion: true)
            precondition(tilted.offset == 0 && !tilted.isMoving,
                         "Reduce Motion must suppress sensor-driven movement too")
        }
        print("PASS: breath recoil, phone tilt/reversal, edge limits and Reduce Motion at 30/60/120 fps")
    }
}
