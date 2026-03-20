// PathTrackRecorder.swift
// TerrainMapper
//
// Passively records GPS breadcrumbs between explicit survey captures.
// These path-track points are stored separately from surveyed points and
// fed into the terrain interpolator with a reduced weight (0.2) so they
// act as gentle shape hints rather than authoritative measurements.
//
// ─── Filtering pipeline ───────────────────────────────────────────────────
// Every incoming CLLocation is screened through five gates in order.
// A location must pass ALL gates before it is recorded:
//
//  Gate 1 — Quality:    horizontalAccuracy < 20 m (blocks poor GPS fixes)
//  Gate 2 — Speed:      CLLocation.speed < 2.5 m/s (blocks running / cycling)
//  Gate 3 — Capture:    not currently capturing a LiDAR/stick-height point
//  Gate 4 — Temporal:   ≥ 2.0 s since the last recorded path point
//  Gate 5 — Spatial:    ≥ 1.5 m from the last recorded path point
//
// The spatial gate is the most important: it makes density proportional to
// movement speed.  Walking slowly through a dip → dense coverage of that
// feature.  Striding quickly between two corners → sparse coverage (fewer
// low-quality altitude readings in between).
//
// ─── Elevation ────────────────────────────────────────────────────────────
// Path-track points use the Kalman-fused altitude from SensorFusionEngine
// as their groundElevation.  This is the phone altitude, not the ground —
// but with an interpolationWeight of 0.2, nearby LiDAR points (weight 1.0)
// dominate.  The path points only contribute to the shape of the surface
// in regions with no nearby LiDAR captures.

import CoreLocation
import Combine
import Foundation

@MainActor
final class PathTrackRecorder {

    // MARK: - Configuration

    /// GPS horizontal accuracy must be below this to record a path point.
    let maxHorizontalAccuracyMetres: Double = 20.0

    /// Device speed must be below this to record a path point.
    /// 2.5 m/s ≈ 9 km/h — a brisk walk; running/cycling filtered out.
    let maxSpeedMetresPerSecond: Double = 2.5

    /// Minimum time between successive path points.
    let minTemporalGapSeconds: TimeInterval = 2.0

    /// Minimum horizontal distance between successive path points.
    /// Points closer than this are dropped (prevents clustering at standstills).
    let minSpatialGapMetres: Double = 1.5

    /// IDW interpolation weight for path-track points.
    let interpolationWeight: Double = 0.2

    // MARK: - Callback

    /// Called on MainActor whenever a filtered path point is produced.
    /// The engine registers here to append to `session.pathTrackPoints`.
    var onPathPointRecorded: ((SurveyPoint) -> Void)?

    // MARK: - Private state

    private var lastRecordedLocation: CLLocation?
    private var lastRecordedTime:     Date?
    private var cancellables = Set<AnyCancellable>()

    // Weak reference to the engine so we can read current altitude and
    // isCapturingPoint without creating a retain cycle.
    private weak var engine: SensorFusionEngine?

    // MARK: - Lifecycle

    /// Begin subscribing to `gpsManager.locationPublisher`.
    func start(gpsManager: GPSManager, engine: SensorFusionEngine) {
        self.engine = engine
        lastRecordedLocation = nil
        lastRecordedTime     = nil

        gpsManager.locationPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] location in
                self?.evaluate(location)
            }
            .store(in: &cancellables)
    }

    /// Stop recording and release all subscriptions.
    func stop() {
        cancellables.removeAll()
        lastRecordedLocation = nil
        lastRecordedTime     = nil
        engine = nil
    }

    // MARK: - Filtering pipeline

    private func evaluate(_ location: CLLocation) {
        guard let engine else { return }

        // ── Gate 1: GPS quality ───────────────────────────────────────────
        guard location.horizontalAccuracy > 0,
              location.horizontalAccuracy < maxHorizontalAccuracyMetres else { return }

        // ── Gate 2: Speed ─────────────────────────────────────────────────
        // CLLocation.speed is −1 when unavailable (e.g. stationary fix).
        // Only apply the gate when speed is actually reported.
        if location.speed >= 0, location.speed > maxSpeedMetresPerSecond { return }

        // ── Gate 3: Active LiDAR/stick-height capture in progress ─────────
        // During the 3-second LiDAR sampling window the device must be still;
        // the GPS position at that moment is already captured in the survey
        // point, so adding a path-track duplicate would add noise.
        guard !engine.isCapturingPoint else { return }

        let now = Date()

        // ── Gate 4: Temporal rate limit ───────────────────────────────────
        if let lastTime = lastRecordedTime,
           now.timeIntervalSince(lastTime) < minTemporalGapSeconds { return }

        // ── Gate 5: Spatial gate ──────────────────────────────────────────
        if let lastLoc = lastRecordedLocation {
            let dist = location.distance(from: lastLoc)
            guard dist >= minSpatialGapMetres else { return }
        }

        // ── All gates passed — assemble the path-track point ─────────────
        // groundElevation = Kalman-fused phone altitude.  There is no ground-
        // distance correction because the device height above ground is unknown
        // during transit.  The reduced interpolationWeight (0.2) means nearby
        // LiDAR-measured points (weight 1.0) will dominate the IDW estimate.
        let fusedAlt = engine.currentAltitude
        let point = SurveyPoint(
            id:                  UUID(),
            timestamp:           now,
            latitude:            location.coordinate.latitude,
            longitude:           location.coordinate.longitude,
            fusedAltitude:       fusedAlt,
            groundElevation:     fusedAlt,
            lidarDistance:       0.0,
            gpsAltitude:         location.altitude,
            baroAltitudeDelta:   0.0,
            tiltAngle:           0.0,
            horizontalAccuracy:  location.horizontalAccuracy,
            verticalAccuracy:    max(location.verticalAccuracy, 0),
            isOutlier:           false,
            captureType:         .pathTrack,
            interpolationWeight: interpolationWeight
        )

        lastRecordedLocation = location
        lastRecordedTime     = now
        onPathPointRecorded?(point)
    }
}
