#if os(iOS)
import CoreMotion
import QuartzCore

/// Samples fused accelerometer data only while the intact gum is on screen.
@MainActor
final class GumMotionInput {
    private let manager = CMMotionManager()
    private var wakeRenderer: (@MainActor () -> Void)?
    private(set) var gravityX: Float = 0
    private(set) var accelerationX: Float = 0
    private var notifiedGravityX: Float = 0
    private var notifiedAccelerationX: Float = 0
    private var lastSampleTime: TimeInterval = 0

    var recentAccelerationX: Float {
        CACurrentMediaTime() - lastSampleTime < 0.08 ? accelerationX : 0
    }

    func setActive(_ active: Bool, wakeRenderer: @escaping @MainActor () -> Void) {
        guard active && manager.isDeviceMotionAvailable else { stop(); return }
        self.wakeRenderer = wakeRenderer
        guard !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let gravityX = Float(motion.gravity.x)
            let accelerationX = Float(motion.userAcceleration.x)
            Task { @MainActor [weak self] in
                self?.receive(gravityX: gravityX, accelerationX: accelerationX)
            }
        }
    }

    func stop() {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
        wakeRenderer = nil
        gravityX = 0
        accelerationX = 0
        notifiedGravityX = 0
        notifiedAccelerationX = 0
        lastSampleTime = 0
    }

    private func receive(gravityX: Float, accelerationX: Float) {
        guard manager.isDeviceMotionActive else { return }
        let gravity = min(max(gravityX, -0.8), 0.8)
        let acceleration = min(max(accelerationX, -0.8), 0.8)
        // Compare with the last wake, not the preceding 30 Hz sample. A slow
        // tilt still needs to restart a renderer that has settled and paused.
        let changed = abs(gravity - notifiedGravityX) > 0.012
            || abs(acceleration - notifiedAccelerationX) > 0.035
        self.gravityX = gravity
        self.accelerationX = acceleration
        lastSampleTime = CACurrentMediaTime()
        if changed {
            notifiedGravityX = gravity
            notifiedAccelerationX = acceleration
            wakeRenderer?()
        }
    }
}
#endif
