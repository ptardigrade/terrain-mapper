// SensorFusionEngine.swift
// TerrainMapper
//
// The top-level coordinator for all sensor managers.  Owns the Kalman filter,
// orchestrates multi-sensor point captures, and assembles SurveySession records.
//
// ─── Point-capture sequence ───────────────────────────────────────────────
//  1. WAIT for IMU stationary gate (device must be still for ~1 second)
//  2. READ current barometric delta → feed into Kalman predict step
//  3. CAPTURE LiDAR distance (90 frames median, tilt-corrected)
//  4. READ current GPS location (or PDR estimate)
//  5. UPDATE Kalman with GPS altitude (if fix is fresh enough)
//  6. ASSEMBLE SurveyPoint from all fused values
//
// ─── Kalman feeding strategy ─────────────────────────────────────────────
// •  Baro updates arrive at 1 Hz; each one triggers a Kalman predict step.
// •  GPS updates trigger a Kalman measurement update with the GPS altitude.
// •  At point-capture time we call predict once more to ensure the state is
//    current, then read state[0] as the fused altitude.

import ARKit
import CoreLocation
import CoreMotion
import Combine
import Foundation

enum SensorFusionError: LocalizedError {
    case sessionNotStarted
    case captureAlreadyInProgress
    case stationaryGateTimeout
    case locationUnavailable
    case lidarCaptureFailed(Error)

    var errorDescription: String? {
        switch self {
        case .sessionNotStarted:
            return "Session has not been started. Call startSession() first."
        case .captureAlreadyInProgress:
            return "A point capture is already in progress. Wait for it to finish."
        case .stationaryGateTimeout:
            return "Device did not become stationary within the timeout period."
        case .locationUnavailable:
            return "No GPS fix available. Move to an open area and try again."
        case .lidarCaptureFailed(let error):
            return "LiDAR capture failed: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class SensorFusionEngine: ObservableObject {

    // MARK: - Published state

    @Published private(set) var isSessionActive: Bool = false
    @Published private(set) var isCapturingPoint: Bool = false
    @Published private(set) var pointCount: Int = 0

    // Pass-through from sub-managers for UI binding
    @Published private(set) var imuIsStationary: Bool = false
    @Published private(set) var tiltAngleDegrees: Double = 0.0
    @Published private(set) var currentAltitude: Double = 0.0
    @Published private(set) var gpsAccuracy: Double = 0.0
    @Published private(set) var stationaryProgress: Double = 0.0
    @Published private(set) var lidarCaptureProgress: Double = 0.0

    /// Square root of Kalman covariance P[0,0] — estimated altitude uncertainty (±metres).
    /// Starts high (~10 m) and decreases as GPS/baro measurements arrive.
    @Published private(set) var altitudeUncertainty: Double = 10.0

    /// Gravity X component (device frame) — forwarded from IMUManager for TiltMeterView.
    @Published private(set) var gravityX: Double = 0.0

    /// Gravity Y component (device frame) — forwarded from IMUManager for TiltMeterView.
    @Published private(set) var gravityY: Double = 0.0

    // MARK: - Sub-managers (internal visibility for testing)

    let imuManager       = IMUManager()
    let barometerManager = BarometerManager()
    let lidarManager     = LiDARManager()
    let gpsManager       = GPSManager()

    // MARK: - Private

    private var kalman = KalmanFilter()
    private var session: SurveySession?

    /// Tracks whether the Kalman filter has received at least one GPS seed.
    private var kalmanInitialised = false

    private var cancellables = Set<AnyCancellable>()

    /// Timeout in seconds for the stationary gate during a capture.
    private let kStationaryTimeoutSeconds = 15.0

    // MARK: - Session lifecycle

    /// Start all sensor streams and begin accumulating data.
    func startSession(stickHeight: Double = 2.0, name: String = "") {
        guard !isSessionActive else { return }

        kalman     = KalmanFilter()
        kalmanInitialised = false
        session    = SurveySession(stickHeight: stickHeight, name: name)
        pointCount = 0

        imuManager.start()
        barometerManager.start()
        gpsManager.start()
        lidarManager.imuManager = imuManager
        // LiDAR ARSession is started on first capturePoint() call

        bindSensorStreams()
        isSessionActive = true
    }

    /// A snapshot of the active session for incremental persistence.
    /// Returns nil if no session is in progress.
    var currentSessionSnapshot: SurveySession? { session }

    /// Stop all sensors, run post-processing, and return the completed session.
    func endSession() -> SurveySession {
        guard var s = session else {
            return SurveySession()
        }

        imuManager.stop()
        barometerManager.stop()
        gpsManager.stop()
        lidarManager.pauseSession()
        cancellables.removeAll()

        s.endTime = Date()

        // Post-processing
        gpsManager.refineWithPDR(points: &s.points)
        s.detectOutliers()

        isSessionActive = false
        session = nil

        return s
    }

    // MARK: - Point capture

    /// Captures a single survey point by orchestrating all sensors.
    ///
    /// - Throws: `SensorFusionError` or `LiDARError` on failure.
    /// - Returns: A fully populated `SurveyPoint`.
    func capturePoint() async throws -> SurveyPoint {
        guard isSessionActive, session != nil else {
            throw SensorFusionError.sessionNotStarted
        }
        guard !isCapturingPoint else {
            throw SensorFusionError.captureAlreadyInProgress
        }
        isCapturingPoint = true
        defer { isCapturingPoint = false }

        // ── Step 1: Wait for stationary gate ─────────────────────────────
        try await waitForStationary()

        // Re-check: session may have been ended while we were waiting for stationary.
        guard isSessionActive, session != nil else {
            throw SensorFusionError.sessionNotStarted
        }

        // ── Step 2: Snapshot baro delta and run Kalman predict ────────────
        let baroDelta = barometerManager.currentRelativeAltitude
        kalman.predict(dt: 1.0, baroAltitudeDelta: baroDelta)

        // ── Step 3: Capture LiDAR distance ───────────────────────────────
        let lidarDistance: Double
        do {
            lidarDistance = try await lidarManager.captureGroundDistance()
        } catch {
            throw SensorFusionError.lidarCaptureFailed(error)
        }

        // Re-check after LiDAR capture (takes ~3 s).
        guard isSessionActive, session != nil else {
            throw SensorFusionError.sessionNotStarted
        }

        // ── Step 4: Get current GPS location ─────────────────────────────
        guard let location = gpsManager.currentLocation else {
            throw SensorFusionError.locationUnavailable
        }

        // ── Step 5: Update Kalman with GPS if fix is fresh (<5 s) ─────────
        if -location.timestamp.timeIntervalSinceNow < 5.0,
           location.verticalAccuracy > 0 {
            kalman.updateGPS(altitude: location.altitude)
        }

        // ── Step 6: Assemble SurveyPoint ──────────────────────────────────
        let fusedAltitude  = kalman.state[0]
        let groundElevation = fusedAltitude - lidarDistance

        let point = SurveyPoint(
            id:                  UUID(),
            timestamp:           Date(),
            latitude:            location.coordinate.latitude,
            longitude:           location.coordinate.longitude,
            fusedAltitude:       fusedAltitude,
            groundElevation:     groundElevation,
            lidarDistance:       lidarDistance,
            gpsAltitude:         location.altitude,
            baroAltitudeDelta:   baroDelta,
            tiltAngle:           imuManager.tiltAngle,
            horizontalAccuracy:  location.horizontalAccuracy,
            verticalAccuracy:    max(location.verticalAccuracy, 0)
        )

        session?.points.append(point)
        pointCount = session?.points.count ?? 0

        return point
    }

    // MARK: - Stationary gate

    /// Removes and returns the last captured survey point from the active session.
    /// Returns nil if there are no points or no active session.
    @discardableResult
    func undoLastPoint() -> SurveyPoint? {
        guard session != nil, !session!.points.isEmpty else { return nil }
        let removed = session!.points.removeLast()
        pointCount = session?.points.count ?? 0
        return removed
    }

    /// Appends a manually-constructed point to the active session.
    func appendPoint(_ point: SurveyPoint) {
        session?.points.append(point)
        pointCount = session?.points.count ?? 0
    }

    /// Suspends until the IMU reports stationary, or throws on timeout.
    private func waitForStationary() async throws {
        // Fast path: already stationary
        if imuManager.isStationary { return }

        let deadline = Date().addingTimeInterval(kStationaryTimeoutSeconds)
        while Date() < deadline {
            if imuManager.isStationary { return }
            // Check every 100 ms
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SensorFusionError.stationaryGateTimeout
    }

    // MARK: - Sensor stream binding

    private func bindSensorStreams() {
        cancellables.removeAll()

        // ── Barometer → Kalman predict ────────────────────────────────────
        // Each baro sample triggers a predict step so the filter stays warm.
        barometerManager.relativeAltitudePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] delta in
                guard let self else { return }
                self.kalman.predict(dt: 1.0, baroAltitudeDelta: delta)
                self.currentAltitude = self.kalman.state[0]
                self.altitudeUncertainty = sqrt(max(0, self.kalman.covariance[0, 0]))
            }
            .store(in: &cancellables)

        // ── GPS → Kalman measurement update ──────────────────────────────
        gpsManager.locationPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] location in
                guard let self else { return }
                self.gpsAccuracy = location.horizontalAccuracy

                guard location.verticalAccuracy > 0 else { return }

                if !self.kalmanInitialised {
                    // Seed the Kalman filter with the first GPS altitude
                    self.kalman = KalmanFilter(initialAltitude: location.altitude)
                    self.kalmanInitialised = true
                } else {
                    self.kalman.updateGPS(altitude: location.altitude)
                }
                self.currentAltitude = self.kalman.state[0]
                self.altitudeUncertainty = sqrt(max(0, self.kalman.covariance[0, 0]))
            }
            .store(in: &cancellables)

        // ── IMU → UI pass-throughs ────────────────────────────────────────
        imuManager.$isStationary
            .receive(on: RunLoop.main)
            .assign(to: &$imuIsStationary)

        imuManager.$tiltAngle
            .map { $0 * 180 / .pi }
            .receive(on: RunLoop.main)
            .assign(to: &$tiltAngleDegrees)

        imuManager.$gravityX
            .receive(on: RunLoop.main)
            .assign(to: &$gravityX)

        imuManager.$gravityY
            .receive(on: RunLoop.main)
            .assign(to: &$gravityY)

        imuManager.$stationaryProgress
            .receive(on: RunLoop.main)
            .assign(to: &$stationaryProgress)

        // ── LiDAR capture progress ─────────────────────────────────────────
        lidarManager.$captureProgress
            .receive(on: RunLoop.main)
            .assign(to: &$lidarCaptureProgress)
    }
}
