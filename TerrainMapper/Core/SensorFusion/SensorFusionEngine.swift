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
    case pointerTooFar(distance: Double)

    var errorDescription: String? {
        switch self {
        case .sessionNotStarted:
            return "Session has not been started. Call startSession() first."
        case .captureAlreadyInProgress:
            return "A point capture is already in progress. Wait for it to finish."
        case .stationaryGateTimeout:
            return "Couldn't detect a steady hold — keep the device still and try again."
        case .locationUnavailable:
            return "No GPS signal. Move to open sky, wait a moment, then try again."
        case .lidarCaptureFailed(let error):
            return "LiDAR reading failed: \(error.localizedDescription). Try again."
        case .pointerTooFar(let distance):
            return String(format: "Target is %.1f m away — move closer. Maximum range is 2.5 m for accurate readings.", distance)
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

    /// True when GPS has no fix at all — used for a soft UI warning.
    var hasNoGPS: Bool { gpsManager.currentLocation == nil }
    @Published private(set) var stationaryProgress: Double = 0.0
    @Published private(set) var lidarCaptureProgress: Double = 0.0

    /// Live center-pixel depth from LiDAR — forwarded from LiDARManager.
    @Published private(set) var pointerDistance: Float = 0.0

    /// True when the AR pointer is beyond the maximum capture distance.
    /// Returns false when there's no depth reading (distance ≤ 0.1) to avoid
    /// false "too far" states when depth data is temporarily unavailable.
    var isPointerTooFar: Bool {
        pointerDistance > LiDARManager.maxCaptureDistance && pointerDistance > 0.1
    }

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

    /// Most recent path-track breadcrumb — observed by SurveyView to update
    /// the faint GPS trail rendered on the live map.
    @Published private(set) var latestPathTrackPoint: SurveyPoint?

    /// AR mesh vertices (world space) extracted at end of session.
    /// Used by the processing pipeline to augment the elevation model with
    /// dense LiDAR mesh data.  Reset at next session start.
    private(set) var lastSessionMeshVertices: [simd_float3] = []

    // MARK: - Private

    private var kalman = KalmanFilter()
    private var session: SurveySession?
    private let pathTrackRecorder = PathTrackRecorder()

    /// Tracks whether the Kalman filter has received at least one GPS seed.
    private var kalmanInitialised = false

    /// True once the Kalman filter has been seeded with a GPS fix that has
    /// valid vertical accuracy.  Published so SurveyView can switch from
    /// relative elevation display (first point = 0 m) to absolute GPS-based
    /// elevations once real altitude data is available.
    @Published private(set) var hasReliableGPSAltitude: Bool = false

    private var cancellables = Set<AnyCancellable>()

    // MARK: - ARKit VIO state

    /// True until the first capture point of a session is recorded.
    /// On the first capture we record the compass heading to anchor the
    /// ARKit world frame to geographic North.
    private var isFirstCapture = true

    /// Accumulates ARKit world-space (x, z) positions keyed by SurveyPoint UUID.
    /// Copied into SurveySession.arkitPositions at endSession().
    /// Also published so ARSurveyView can render markers during the live session.
    @Published private(set) var arkitPositions: [String: [Double]] = [:]

    /// Compass heading (degrees CW from true north) when the ARKit session started.
    private var arkitAnchorHeading: Double? = nil

    /// Timeout in seconds for the stationary gate during a capture.
    private let kStationaryTimeoutSeconds = 15.0

    // MARK: - Live differential elevation

    /// Computes a baro-differential corrected ground elevation for a newly
    /// captured point.  Uses the same formula as DifferentialElevationCorrector
    /// but runs incrementally so the capture toast and telemetry display
    /// corrected values instead of noisy Kalman-fused ones.
    ///
    /// Returns `(correctedGroundElev, h_start)`.
    func differentialCorrectedElevation(
        gpsAltitude: Double,
        baroDelta: Double,
        lidarDistance: Double
    ) -> Double {
        guard let pts = session?.points, !pts.isEmpty else {
            // Fallback: raw computation for the very first point
            return gpsAltitude - lidarDistance
        }
        // Estimate h_start from all capture points so far (including this one implicitly)
        var estimates = pts.compactMap { p -> Double? in
            guard p.captureType != .pathTrack else { return nil }
            return p.gpsAltitude - p.baroAltitudeDelta
        }
        estimates.append(gpsAltitude - baroDelta)
        estimates.sort()
        let h_start: Double
        let n = estimates.count
        if n % 2 == 1 {
            h_start = estimates[n / 2]
        } else {
            h_start = (estimates[n / 2 - 1] + estimates[n / 2]) / 2.0
        }
        return h_start + baroDelta - lidarDistance
    }

    // MARK: - Session lifecycle

    /// Start all sensor streams and begin accumulating data.
    func startSession(name: String = "") {
        guard !isSessionActive else { return }

        kalman     = KalmanFilter()
        kalmanInitialised = false
        hasReliableGPSAltitude = false
        session    = SurveySession(name: name)
        pointCount = 0
        isFirstCapture    = true
        arkitPositions    = [:]
        arkitAnchorHeading = nil
        lastSessionMeshVertices = []

        imuManager.start()
        barometerManager.start()
        gpsManager.start()
        lidarManager.imuManager = imuManager
        // LiDAR ARSession is started on first capturePoint() call

        // Start passive path-track recording between captures.
        pathTrackRecorder.onPathPointRecorded = { [weak self] point in
            guard let self else { return }
            self.session?.pathTrackPoints.append(point)
            self.latestPathTrackPoint = point
        }
        pathTrackRecorder.start(gpsManager: gpsManager, engine: self)

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

        // Extract AR mesh vertices BEFORE pausing the session (requires active ARSession).
        lastSessionMeshVertices = lidarManager.extractMeshWorldVertices()

        imuManager.stop()
        barometerManager.stop()
        gpsManager.stop()
        lidarManager.pauseSession()   // stops ARSession and resets isSessionRunning
        pathTrackRecorder.stop()
        cancellables.removeAll()

        s.endTime = Date()

        // Attach ARKit VIO data collected during capture so the processing pipeline
        // can refine horizontal positions independently of GPS accuracy.
        if !arkitPositions.isEmpty {
            s.arkitPositions    = arkitPositions
            s.arkitAnchorHeading = arkitAnchorHeading
        }

        // Persist AR mesh vertices so history reprocessing produces identical results.
        if !lastSessionMeshVertices.isEmpty {
            s.arMeshWorldVertices = lastSessionMeshVertices.map { v in [v.x, v.y, v.z] }
        }

        // Outlier detection and PDR refinement are intentionally deferred to
        // ProcessingPipeline so the user's configured thresholds (madThreshold,
        // gridResolution, etc.) are applied.  Running them here would either be
        // overridden by the pipeline (wasted work) or — in the PDR case — produce
        // corrections that the pipeline's linear-interpolation pass would silently
        // overwrite, compounding position errors.

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

        // ── Step 2b: Snapshot AR pointer position BEFORE LiDAR capture ──
        // The LiDAR capture takes ~3 seconds.  Snapshot the pointer position now
        // (after stationary gate, before LiDAR sampling) so the dot appears where
        // the user was pointing when they tapped "Capture", not where the phone
        // drifted to 3 seconds later.
        let snapshotPointerPos = lidarManager.currentPointerPosition
        let snapshotCameraPos = lidarManager.currentWorldPosition

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

        // ── Step 3b: Enforce 1.5 m maximum capture distance ─────────────
        if lidarDistance > Double(LiDARManager.maxCaptureDistance) {
            throw SensorFusionError.pointerTooFar(distance: lidarDistance)
        }

        // ── Step 4: Get current GPS location (soft fallback if unavailable) ─
        let location: CLLocation
        if let gpsLoc = gpsManager.currentLocation {
            location = gpsLoc
        } else if let lastPt = session?.points.last {
            // No GPS fix — reuse last captured point's position with degraded accuracy.
            location = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: lastPt.latitude, longitude: lastPt.longitude),
                altitude: lastPt.gpsAltitude,
                horizontalAccuracy: 9999,
                verticalAccuracy: -1,
                timestamp: Date()
            )
        } else {
            // Very first point with no GPS — use a placeholder.
            // ARKit VIO will refine the relative positions in post-processing.
            location = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                altitude: 0,
                horizontalAccuracy: 9999,
                verticalAccuracy: -1,
                timestamp: Date()
            )
        }

        // ── Step 5: Update Kalman with GPS if fix is fresh (<5 s) ─────────
        if gpsManager.currentLocation != nil,
           -location.timestamp.timeIntervalSinceNow < 5.0,
           location.verticalAccuracy > 0 {
            kalman.updateGPS(altitude: location.altitude)
        }

        // ── Step 5b: Record AR pointer position for VIO-based refinement ──
        // Use the pre-capture snapshot so the dot appears at the pointer location
        // when the user tapped Capture.  Fall back to post-capture positions.
        let pointerPos = snapshotPointerPos ?? lidarManager.currentPointerPosition
        let cameraPos = snapshotCameraPos ?? lidarManager.currentWorldPosition

        // On the very first capture, record the compass heading to anchor the
        // ARKit world frame to geographic North for the processing pipeline.
        if isFirstCapture {
            arkitAnchorHeading = gpsManager.currentHeading
            isFirstCapture = false
        }

        // ── Step 6: Assemble SurveyPoint ──────────────────────────────────
        let fusedAltitude  = kalman.state[0]
        let groundElevation = fusedAltitude - lidarDistance

        let pointID = UUID()

        // Store ARKit position keyed by UUID so the pipeline can look it up.
        // Format: [x, z, y_ground] — pipeline uses [0]=x and [1]=z (unchanged);
        // ARSurveyView uses [2]=y_ground to place 3-D dot anchors.
        //
        // Use the pointer position (where the user was aiming) so the dot appears
        // at the aimed location, not directly under the phone.
        if let ptr = pointerPos {
            arkitPositions[pointID.uuidString] = [Double(ptr.x), Double(ptr.z), Double(ptr.y)]
        } else if let pos = cameraPos {
            // Fallback: camera position with estimated ground Y
            let groundY = Double(pos.y) - lidarDistance
            arkitPositions[pointID.uuidString] = [Double(pos.x), Double(pos.z), groundY]
        }

        let point = SurveyPoint(
            id:                  pointID,
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

    /// Removes and returns the last explicitly captured survey point.
    /// Path-track breadcrumbs in `session.pathTrackPoints` are unaffected.
    /// Returns nil if there are no capture points or no active session.
    @discardableResult
    func undoLastPoint() -> SurveyPoint? {
        guard session != nil, !session!.points.isEmpty else { return nil }
        let removed = session!.points.removeLast()
        pointCount = session?.points.count ?? 0
        return removed
    }

    /// Appends a manually-constructed explicit capture point.
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
                    self.hasReliableGPSAltitude = true
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

        // ── LiDAR center depth → pointer distance ───────────────────────
        lidarManager.$centerDepthDistance
            .receive(on: RunLoop.main)
            .assign(to: &$pointerDistance)
    }
}
