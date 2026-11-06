import Foundation

/// A local acoustic cue, not speech recognition. Unvoiced speech and wind can
/// still resemble a breath, so callers must require sustained input.
struct GumBlowFrame: Sendable {
    let rms: Float
    let highFrequencyShare: Float
    let periodicity: Float

    var isBreathLike: Bool {
        rms > 0.012 && highFrequencyShare > 0.18 && periodicity < 0.36
    }

    var strength: Float { min(max((rms - 0.01) / 0.12, 0), 1) }
}

struct GumBreathGate {
    private(set) var sustainedTime: Double = 0

    mutating func accept(_ frame: GumBlowFrame, duration: Double) -> Bool {
        sustainedTime = frame.isBreathLike ? min(sustainedTime + duration, 0.3) : 0
        return sustainedTime >= 0.14
    }
}

enum GumBlowDetector {
    /// Work is bounded by one short audio tap. The high-pass ratio rejects
    /// low-frequency handling noise; autocorrelation rejects voiced tones.
    static func analyze(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double) -> GumBlowFrame {
        guard count >= 512, sampleRate >= 8_000 else {
            return GumBlowFrame(rms: 0, highFrequencyShare: 0, periodicity: 1)
        }
        let length = min(count, 4096)
        let alpha = Float(min(1, 2 * Double.pi * 300 / sampleRate))
        var low: Float = 0
        var total: Float = 0
        var highTotal: Float = 0
        var downsampled: [Float] = []
        downsampled.reserveCapacity(length / 4)
        for index in 0..<length {
            let sample = samples[index].isFinite ? samples[index] : 0
            low += alpha * (sample - low)
            let high = sample - low
            total += sample * sample
            highTotal += high * high
            if index.isMultiple(of: 4) { downsampled.append(high) }
        }
        let rms = sqrt(total / Float(length))
        let highShare = sqrt(highTotal / max(total, 1e-9))
        guard rms > 0.008, downsampled.count > 160 else {
            return GumBlowFrame(rms: rms, highFrequencyShare: highShare, periodicity: 0)
        }
        let rate = sampleRate / 4
        let firstLag = max(2, Int(rate / 350))
        let lastLag = min(downsampled.count / 3, Int(rate / 80))
        var periodicity: Float = 0
        if firstLag <= lastLag {
            for lag in stride(from: firstLag, through: lastLag, by: 2) {
                var cross: Float = 0, left: Float = 0, right: Float = 0
                for index in lag..<downsampled.count {
                    let a = downsampled[index]
                    let b = downsampled[index - lag]
                    cross += a * b
                    left += a * a
                    right += b * b
                }
                periodicity = max(periodicity, cross / sqrt(max(left * right, 1e-12)))
            }
        }
        return GumBlowFrame(rms: rms, highFrequencyShare: highShare,
                            periodicity: periodicity)
    }
}
