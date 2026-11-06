import Foundation

@main struct BlowDetectorChecks {
    static func main() {
        let sampleRate = 48_000.0
        let count = 2048
        var seed: UInt32 = 271
        func noise() -> Float {
            seed = 1_664_525 &* seed &+ 1_013_904_223
            return Float(seed) / Float(UInt32.max) * 2 - 1
        }
        func frame(_ build: (Int) -> Float) -> GumBlowFrame {
            let samples = (0..<count).map(build)
            return samples.withUnsafeBufferPointer {
                GumBlowDetector.analyze($0.baseAddress!, count: count, sampleRate: sampleRate)
            }
        }
        let quiet = frame { _ in noise() * 0.003 }
        let voice = frame { index in
            let phase = 2 * Double.pi * 180 * Double(index) / sampleRate
            return Float(0.07 * sin(phase) + 0.025 * sin(phase * 2) + 0.012 * sin(phase * 3))
        }
        let breath = frame { _ in noise() * 0.10 }
        precondition(!quiet.isBreathLike, "Quiet ambient input inflated gum")
        precondition(!voice.isBreathLike, "A voiced, harmonic vowel inflated gum")
        precondition(breath.isBreathLike, "Broadband breath cue was missed")
        var gate = GumBreathGate()
        precondition(!gate.accept(breath, duration: 2048 / sampleRate))
        precondition(!gate.accept(breath, duration: 2048 / sampleRate))
        precondition(!gate.accept(breath, duration: 2048 / sampleRate))
        precondition(gate.accept(breath, duration: 2048 / sampleRate),
                     "A sustained breath must open the gate")
        precondition(!gate.accept(voice, duration: 2048 / sampleRate),
                     "Voiced input must close the gate")
        print("PASS: quiet ambient and harmonic voice rejected; sustained broadband air accepted")
        print("RMS quiet/voice/air: \(quiet.rms), \(voice.rms), \(breath.rms)")
        print("Periodicity voice/air: \(voice.periodicity), \(breath.periodicity)")
    }
}
