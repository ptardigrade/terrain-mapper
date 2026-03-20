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
    private var depthSamples: [Float] = []
    private var continuation: CheckedContinuation<Double, Error>?

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

        // Start (or restart) the AR session with depth enabled.
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = .sceneDepth

        if arSession == nil {
            arSession = ARSession()
            arSession?.delegate = self
        }
        arSession?.run(config, options: [.resetTracking, .removeExistingAnchors])

        // Suspend the current task until the delegate has collected enough frames.
        let slantDistance: Double = try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
        }

        isCapturing = false
        arSession?.pause()

        // Apply tilt correction: V = D × cos(θ)
        let tiltFactor = imuManager?.tiltCorrectionFactor ?? 1.0
        let vertical   = slantDistance * tiltFactor

        return max(vertical, 0.01)   // clamp to positive
    }

    /// Pauses the underlying ARSession (call when backgrounding the app).
    func pauseSession() {
        arSession?.pause()
    }
}

// MARK: - ARSessionDelegate

extension LiDARManager: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Called on ARKit's background queue — we dispatch to MainActor to
        // keep mutable state access safe.
        Task { @MainActor in
            guard self.isCapturing else { return }
            self.processFrame(frame)
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.isCapturing = false
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }

    // MARK: - Frame processing (MainActor)

    private func processFrame(_ frame: ARFrame) {
        guard let depthData = frame.sceneDepth?.depthMap else { return }

        // ── Sample central ROI of the depth map ──────────────────────────
        let width  = CVPixelBufferGetWidth(depthData)
        let height = CVPixelBufferGetHeight(depthData)

        let roiX1 = Int(Double(width)  * (0.5 - kROIFraction / 2))
        let roiX2 = Int(Double(width)  * (0.5 + kROIFraction / 2))
        let roiY1 = Int(Double(height) * (0.5 - kROIFraction / 2))
        let roiY2 = Int(Double(height) * (0.5 + kROIFraction / 2))

        CVPixelBufferLockBaseAddress(depthData, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthData, .readOnly) }

        guard let baseAddr = CVPixelBufferGetBaseAddress(depthData) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthData)
        let floatBuffer = baseAddr.assumingMemoryBound(to: Float32.self)

        for y in roiY1..<roiY2 {
            for x in roiX1..<roiX2 {
                let index = y * (bytesPerRow / MemoryLayout<Float32>.size) + x
                let depth = floatBuffer[index]
                // ARKit returns 0 for invalid pixels; skip them.
                if depth > 0.1 && depth < 20.0 {
                    depthSamples.append(depth)
                }
            }
        }

        // ── Check if we have accumulated enough frames ───────────────────
        // We count frames conservatively: each frame contributes a predictable
        // number of ROI pixels; if total sample count exceeds kFrameCount × ROI_area
        // we have sufficient coverage.
        let roiPixelsPerFrame = (roiX2 - roiX1) * (roiY2 - roiY1)
        let framesEquivalent  = depthSamples.count / max(roiPixelsPerFrame, 1)

        guard framesEquivalent >= kFrameCount else { return }

        // ── Compute median ────────────────────────────────────────────────
        let sorted = depthSamples.sorted()
        let median = Double(sorted[sorted.count / 2])

        // Resolve the continuation
        continuation?.resume(returning: median)
        continuation = nil
    }
}
