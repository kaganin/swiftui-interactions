// Compile with Sources/GumRupture.swift; no GPU or simulator is needed.
@main struct RuptureChecks {
    static func main() {
        var state = GumRupture()
        for _ in 0..<300 {
            precondition(!state.advance(touchingBurstLine: false,
                                        dt: 1 / 30, reducedMotion: false))
        }
        precondition(state.advance(touchingBurstLine: true,
                                   dt: 1 / 30, reducedMotion: false),
                     "The first burst-line-contact frame must start the tear")
        precondition(!state.advance(touchingBurstLine: false,
                                    dt: 1 / 30, reducedMotion: false))
        precondition(state.time != nil, "Contact must not be undone")
        for fps: Float in [30, 60, 120] {
            state = GumRupture()
            precondition(state.advance(touchingBurstLine: true,
                                       dt: 1 / fps, reducedMotion: false),
                         "Contact must rupture at every display cadence")
        }
        state = GumRupture()
        var triggers = 0
        for _ in 0..<90 {
            if state.advance(touchingBurstLine: true,
                             dt: 1 / 30, reducedMotion: false) { triggers += 1 }
        }
        precondition(triggers == 1 && state.isSettled, "One rupture must settle")
        let settled = state.time
        _ = state.advance(touchingBurstLine: false, dt: 1, reducedMotion: false)
        precondition(state.time == settled, "Stuck fragments must remain fixed")
        state = GumRupture()
        precondition(state.advance(touchingBurstLine: true,
                                   dt: 1 / 30, reducedMotion: true))
        precondition(state.isSettled, "Reduced motion skips flight")
        state = GumRupture()
        for _ in 0..<44 {
            _ = state.advance(touchingBurstLine: true,
                              dt: 1 / 60, reducedMotion: false)
        }
        precondition(state.isSettled, "Burst-line contact and rupture must finish within 0.74 seconds")
        // The opening must remain readable across several display frames, while
        // the clock stays continuous and reaches the same physical final state.
        precondition(GumRupture.simulationTime(for: 0) >= 0.025,
                     "The contact frame should contain a hairline puncture")
        precondition(GumRupture.simulationTime(for: 0.05) >= 0.10,
                     "The elastic recoil must become visible within three 60 Hz frames")
        precondition(GumRupture.simulationTime(for: 0.10) >= 0.15,
                     "The first opening should be visible soon after contact")
        precondition(GumRupture.simulationTime(for: 0.30) >= 0.22)
        precondition(GumRupture.simulationTime(for: 0.68) == 0.65)
        var previous = GumRupture.simulationTime(for: 0)
        for frame in 0...82 {
            let sample = GumRupture.simulationTime(for: Float(frame) / 120)
            precondition(sample >= previous && sample - previous < 0.02,
                         "The shared clock must not jump or reverse during handoff")
            previous = sample
        }
        state = GumRupture()
        precondition(state.time == nil && !state.isSettled, "Reset clears rupture")
        print("PASS: first-frame contact at 30/60/120 Hz, one trigger, settled persistence, reduced motion, reset")
    }
}
