// LiDARManager.swift
// TerrainMapper
//
// Wraps ARKit to sample the device LiDAR sensor and return a tilt-corrected
// vertical distance from the device to the ground surface directly below.
//
// ─── Capture strategy ────────────────────────────────────────────────────
// Raw LiDAR depth maps are noisy.  We:
//   1. Sample only the central 20% region of each depth frame (the part of
//      the image that corresponds to ground directly below the stick tip).
//   2. Collect 90 consecutive frames at ~30 fps → 3 seconds of data.
//   3. Return the *median* of all sampled pixels across all frames.
//
// Median is chosen over mean because it is robust to sky-reflections and
// specular ground surfaces that produce erroneous very-far or very-near readings.
//
// ─── Tilt correction ─────────────────────────────────────────────────────
// ARKit reports slant distance D along the optical axis.
// Vertical ground distance V = D × cos(θ), where θ = IMUManager.tiltAngle.
//
// ─── Threading model ─────────────────────────────────────────────────────
// ARSession delegate callbacks arrive on an ARKit-owned background queue.
// We accumulate frames there and resolve the async continuation on the main
// actor once we have enough samples.

import ARKit
import CoreMotion
import Combine
import Foundation

enum LiDARError: LocalizedError {
    case hardwareUnavailable
    case depthDataUnavailable
    case captureCancelled
    case insufficientFrames(got: Int, needed: Int)

    var errorDescription: String? {
        switch self {
        case .hardwareUnavailable:
            return "LiDAR scanner is not available on this device."
        case .depthDataUnavailable:
            return "Depth data could not be read from the current AR frame."
        case .captureCancelled:
            return "Capture was cancelled before enough frames were collected."
        case .insufficientFrames(let got, let needed):
            return "Only \(got) depth frames were collected; needed \(needed)."
        }
    }
}

@MainActor
final class LiDARManager: NSObject, ObservableObject {

    // MARK: - Public state

    @Published private(set) var isCapturing: Bool = false
    @Published var captureProgress: Double = 0.0

    // MARK: - Configuration

    /// Number of frames to accumulate before computing the median.
    let kFrameCount    = 90
    /// Central region fraction for ROI sampling (0.2 = central 20%).
    let kROIFraction   = 0.20

    // MARK: - Dependencies (injected)

    /// IMUManager provides the current tilt angle for slant → vertical correction.
    var imuManager: IMUManager?

    // MARK: - Private

    private var arSession: ARSession?

    /// True after the first captureGroundDistance() call initialises the session.
    /// Subsequent calls reuse the running session so ARKit VIO tracking is
    /// preserved across capture points (no world-origin reset between captures).
    private var isSessionRunning = false

    private var depthSamples: [Float] = []
    /// Counts every ARFrame that arrives during a capture, regardless of how
    /// many valid depth pixels it contributed.  This prevents infinite hangs
    /// when most pixels are filtered (glass, mirror, sunlit grass, etc.).
    private var frameCount: Int = 0
    private var continuation: CheckedContinuation<Double, Error>?

    // MARK: - ARKit world-position access

    /// The camera's position in ARKit world space at the most recent AR frame.
    ///
    /// x and z are the horizontal components (metres from the world origin set
    /// on the first LiDAR capture).  Used by SensorFusionEngine to store
    /// relative positions for ARKit VIO post-processing.
    ///
    /// Returns nil when no AR session is running or no frame has been received.
    var currentWorldPosition: simd_float3? {
        guard let frame = arSession?.currentFrame else { return nil }
        let col3 = frame.camera.transform.columns.3
        return simd_float3(col3.x, col3.y, col3.z)
    }

    // MARK: - Public API

    /// Captures a tilt-corrected vertical distance to the ground.
    ///
    /// The method starts (or reuses) an ARSession, accumulates `kFrameCount`
    /// LiDAR depth frames, computes the median of the central ROI samples,
    /// applies tilt correction from the IMU, then returns the result.
    ///
    /// - Throws: `LiDARError` if hardware is unavailable or capture fails.
    /// - Returns: Vertical distance to the ground surface in metres.
    func captureGroundDistance() async throws -> Double {
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            throw LiDARError.hardwareUnavailable
        }
        guard !isCapturing else {
            throw LiDARError.captureCancelled
        }

        isCapturing   = true
        depthSamples  = []
        depthSamples.reserveCapacity(kFrameCount * 200)  // rough pre-allocation
        frameCount    = 0
        captureProgress = 0.0

        // Start the AR session fresh on the first capture only.
        // Subsequent captures reuse the already-running session so the ARKit
        // world origin (and VIO tracking state) is preserved across captures —
        // this lets us read relative camera positions to correct for GPS error.
        if !isSessionRunning {
            let config = ARWorldTrackingConfiguration()
            config.frameSemantics = .sceneDepth
            if arSession == nil {
                arSession = ARSession()
                arSession?.delegate = self
            }
            arSession?.run(config, options: [.resetTracking, .removeExistingAnchors])
            isSessionRunning = true
        }
        // else: session is already running — just reset counters and start
        // accumulating fresh frames from the still-active session.

        // Suspend the current task until the delegate has collected enough frames.
        let slantDistance: Double = try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
        }

        isCapturing = false
        // Do NOT pause the session between captures: keeping the AR session
        // running preserves VIO world tracking so currentWorldPosition returns
        // consistent positions relative to the first capture.

        // Apply tilt correction: V = D × cos(θ)
        let tiltFactor = imuManager?.tiltCorrectionFactor ?? 1.0
        let vertical   = slantDistance * tiltFactor

        return max(vertical, 0.01)   // clamp to positive
    }

    /// Stops the underlying ARSession.
    ///
    /// Call this from SensorFusionEngine.endSession() to release resources.
    /// Setting arSession to nil forces a fresh session (with a new world origin)
    /// on the next survey, which is the correct behaviour.
    func pauseSession() {
        arSession?.pause()
        arSession = nil
        isSessionRunning = false
    }
}

// MARK: - ARSessionDelegate

extension LiDARManager: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Do all heavy pixel work here on ARKit's background queue.
        // Only hop to MainActor to update state variables.
        guard let depthData = frame.sceneDepth?.depthMap else { return }
        let samples = LiDARManager.extractDepthSamples(from: depthData, roiFraction: 0.20)

        Task { @MainActor in
            guard self.isCapturing else { return }
            self.accumulateSamples(samples)
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.isCapturing = false
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }

    // MARK: - Depth extraction (background queue)

    private nonisolated static func extractDepthSamples(
        from depthMap: CVPixelBuffer,
        roiFraction: Double
    ) -> [Float] {
        let width  = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        let roiX1 = Int(Double(width)  * (0.5 - roiFraction / 2))
        let roiX2 = Int(Double(width)  * (0.5 + roiFraction / 2))
        let roiY1 = Int(Double(height) * (0.5 - roiFraction / 2))
        let roiY2 = Int(Double(height) * (0.5 + roiFraction / 2))

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddr = CVPixelBufferGetBaseAddress(depthMap) else { return [] }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let floatBuffer = baseAddr.assumingMemoryBound(to: Float32.self)

        var result: [Float] = []
        result.reserveCapacity((roiX2 - roiX1) * (roiY2 - roiY1))

        for y in roiY1..<roiY2 {
            for x in roiX1..<roiX2 {
                let index = y * (bytesPerRow / MemoryLayout<Float32>.size) + x
                let depth = floatBuffer[index]
                if depth > 0.1 && depth < 20.0 {
                    result.append(depth)
                }
            }
        }
        return result
    }

    // MARK: - Frame accumulation (MainActor)

    private func accumulateSamples(_ samples: [Float]) {
        // Capture is already resolved — discard stale frames still in flight from
        // ARKit's background queue.
        guard continuation != nil else { return }

        depthSamples.append(contentsOf: samples)

        frameCount += 1
        captureProgress = min(1.0, Double(frameCount) / Double(kFrameCount))
        guard frameCount >= kFrameCount else { return }

        guard !depthSamples.isEmpty else {
            continuation?.resume(throwing: LiDARError.depthDataUnavailable)
            continuation = nil
            return
        }
        let sorted = depthSamples.sorted()
        let median = Double(sorted[sorted.count / 2])

        continuation?.resume(returning: median)
        continuation = nil
    }
}
