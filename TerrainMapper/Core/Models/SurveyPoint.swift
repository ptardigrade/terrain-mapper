// SurveyPoint.swift
// TerrainMapper
//
// Represents a single surveyed ground-elevation point assembled by the
// SensorFusionEngine.  All altitude values are in metres above the WGS-84
// ellipsoid (GPS reference) unless stated otherwise.

import Foundation

/// A single terrain-survey point produced by the SensorFusionEngine.
///
/// Altitude provenance:
/// - `gpsAltitude`        – raw altitude reported by CoreLocation (ellipsoidal, noisy ~5 m)
/// - `baroAltitudeDelta`  – relative height change from CMAltimeter since session start
/// - `fusedAltitude`      – Kalman-filtered best estimate combining GPS + baro
/// - `lidarDistance`      – tilt-corrected vertical distance from device to ground (LiDAR)
/// - `groundElevation`    – `fusedAltitude - lidarDistance` (what we actually care about)
struct SurveyPoint: Identifiable, Codable {
    // MARK: - Identity
    let id: UUID
    let timestamp: Date

    // MARK: - Position
    let latitude: Double
    let longitude: Double

    // MARK: - Altitude
    /// Kalman-fused altitude estimate (metres, WGS-84 ellipsoid).
    let fusedAltitude: Double

    /// Ground elevation = fusedAltitude − lidarDistance.
    /// This is the elevation of the terrain surface beneath the measurement stick.
    let groundElevation: Double

    /// Tilt-corrected vertical distance from device lens to the ground surface
    /// as measured by LiDAR.  Equal to slant_distance × cos(tiltAngle).
    let lidarDistance: Double

    /// Raw GPS altitude from CLLocation (ellipsoidal, high noise).
    let gpsAltitude: Double

    /// CMAltimeter relative altitude delta from the start of the session.
    /// Highly precise (±0.1 m) but drifts over long sessions.
    let baroAltitudeDelta: Double

    // MARK: - Orientation
    /// Device tilt from vertical (radians).  0 = device pointing straight up.
    let tiltAngle: Double

    // MARK: - Accuracy
    /// CLLocation horizontal accuracy (metres, 68% confidence radius).
    let horizontalAccuracy: Double

    /// CLLocation vertical accuracy (metres, 68% confidence).
    let verticalAccuracy: Double

    // MARK: - Quality flag
    /// Set by the outlier-detection pass in SurveySession.  Points flagged as
    /// outliers are excluded from DEM interpolation but kept in the record.
    var isOutlier: Bool = false
}

extension SurveyPoint: CustomStringConvertible {
    var description: String {
        String(
            format: "SurveyPoint(%.6f°, %.6f°, elev=%.2f m, fused=%.2f m, lidar=%.2f m)",
            latitude, longitude, groundElevation, fusedAltitude, lidarDistance
        )
    }
}
