import Foundation

/// A small, damped lateral bend driven by the last breath impulse.
/// The attachment stays fixed; geometry applies this displacement only above it.
struct GumSway {
    private(set) var offset: Float = 0
    private(set) var velocity: Float = 0
    private(set) var target: Float = 0

    var isMoving: Bool { abs(offset - target) > 0.0001 || abs(velocity) > 0.001 }

    mutating func advance(dt: Float, inflation: Float, inflationSpeed: Float,
                          variation: Float, gravityX: Float, accelerationX: Float,
                          reducedMotion: Bool) {
        if reducedMotion { self = GumSway(); return }
        let opened = smoothstep(0.12, 0.55, inflation)
        let direction: Float = sin(variation * 6.2831853) >= 0 ? 1 : -1
        let load = min(max(inflationSpeed / 0.18, 0), 1)
        // The film can swing freely while small, but the display edges constrain
        // its lateral travel as it grows toward the burst line.
        let sideContact = smoothstep(0.64, 0.76, inflation)
        let range = 0.15 - 0.125 * sideContact
        let breath = direction * 0.035 * opened * load
        let tilt = -gravityX * range * 1.6 * opened
        let inertia = -accelerationX * range * opened
        target = min(max(breath + tilt + inertia, -range), range)
        // Short substeps keep the same response at 30, 60 and uneven input frames.
        let step = max(0, min(dt, 0.05)) / 4
        for _ in 0..<4 {
            velocity += ((target - offset) * 150 - velocity * 16) * step
            offset += velocity * step
            if abs(offset) > range {
                offset = min(max(offset, -range), range)
                if offset * velocity > 0 { velocity = 0 }
            }
        }
    }

    private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
