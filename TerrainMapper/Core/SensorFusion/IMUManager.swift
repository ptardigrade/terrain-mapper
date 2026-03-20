// IMUManager.swift
// TerrainMapper
//
// Wraps CMMotionManager to provide:
//   • Device tilt angle from vertical (used for LiDAR slant correction)
//   • Stationary validation gate (IMU variance < 0.005 g² over 30 samples)
//
// ─── Tilt correction math ─────────────────────────────────────────────────
// The LiDAR sensor measures slant distance D along the device's optical axis.
// We want the *vertical* distance V to the ground surface.
//
//   V = D × cos(θ)
//
// where θ is the angle between the device's z-axis and the gravity vector.
// CMDeviceMotion.gravity gives g = (gx, gy, gz) normalised to ±1.
// When the device points straight down (measuring stick vertical), gz ≈ −1
// and θ ≈ 0.  tiltAngle = arccos(|gz|).
//
// ─── Stationary gate ──────────────────────────────────────────────────────
// We collect the last 30 accelerometer magnitude samples (|a| − 1 g, removing
// gravity) and compute their variance.  If variance < 0.005 g² the device is
// considered stationary — safe to capture a LiDAR measurement.
// This prevents noisy readings while the operator is still walking.

import CoreMotion
import Combine
import Foundation

@MainActor
final class IMUManager: ObservableObject {

    // MARK: - Public state

    /// Current tilt angle from vertical in radians.
    /// 0 = device z-axis aligned with gravity (pointing straight down/up).
    @Published private(set) var tiltAngle: Double = 0.0

    /// True when the device has been stationary for at least `kWindowSize` samples.
    @Published private(set) var isStationary: Bool = false

    /// Convenience multiplier: cos(tiltAngle).
    /// Multiply a LiDAR slant distance by this to get the vertical component.
    var tiltCorrectionFactor: Double { cos(tiltAngle) }

    // MARK: - Private

    private let motionManager = CMMotionManager()
    private var accelerationWindow: [Double] = []
    private let kWindowSize   = 30
    private let kVarianceGate = 0.005   // g²
    private let kUpdateHz     = 30.0    // Hz

    // MARK: - Lifecycle

    /// Start streaming IMU data.
    func start() {
        guard motionManager.isDeviceMotionAvailable else {
            print("[IMUManager] Device motion unavailable on this hardware.")
            return
        }
        motionManager.deviceMotionUpdateInterval = 1.0 / kUpdateHz
        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: .main
        ) { [weak self] motion, error in
            guard let self, let motion, error == nil else { return }
            Task { @MainActor in
                self.processMotion(motion)
            }
        }
    }

    /// Stop IMU streaming and reset state.
    func stop() {
        motionManager.stopDeviceMotionUpdates()
        accelerationWindow.removeAll()
        tiltAngle    = 0.0
        isStationary = false
    }

    // MARK: - Processing

    private func processMotion(_ motion: CMDeviceMotion) {
        // ── Tilt angle ───────────────────────────────────────────────────
        // gravity vector components in device frame.
        // gz is negative when device points downward (screen facing up on a stick).
        let g = motion.gravity
        // Clamp to [-1, 1] before acos to guard against floating-point rounding.
        let cosTheta = max(-1.0, min(1.0, abs(g.z)))
        tiltAngle = acos(cosTheta)

        // ── Stationary gate ──────────────────────────────────────────────
        // userAcceleration removes gravity; magnitude should be ~0 when still.
        let ua = motion.userAcceleration
        let accelMag = sqrt(ua.x*ua.x + ua.y*ua.y + ua.z*ua.z)

        accelerationWindow.append(accelMag)
        if accelerationWindow.count > kWindowSize {
            accelerationWindow.removeFirst()
        }

        if accelerationWindow.count == kWindowSize {
            let variance = accelerationWindow.variance()
            isStationary = variance < kVarianceGate
        } else {
            isStationary = false
        }
    }
}

// MARK: - Array variance helper
private extension Array where Element == Double {
    /// Population variance of the array elements.
    func variance() -> Double {
        guard count > 1 else { return 0 }
        let mean = reduce(0, +) / Double(count)
        let sumSq = map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
        return sumSq / Double(count)
    }
}
