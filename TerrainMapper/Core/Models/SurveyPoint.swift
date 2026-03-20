// SurveyPoint.swift
// TerrainMapper
//
// Represents a single surveyed ground-elevation point assembled by the
// SensorFusionEngine.  All altitude values are in metres above the WGS-84
// ellipsoid (GPS reference) unless stated otherwise.

import Foundation

// MARK: - CaptureType

/// Describes how a survey point was acquired.
///
/// - `lidar`:      LiDAR depth measurement (highest quality — 90-frame median,
///                 tilt-corrected).  Full interpolation weight (1.0).
/// - `stickHeight`: GPS + barometer altitude, stick-height subtracted.  Used
///                 when LiDAR is unavailable (reflective or sunlit surface).
///                 Full interpolation weight (1.0).
/// - `pathTrack`:  Passive GPS breadcrumb recorded automatically while the
///                 operator walks between capture points.  No ground-distance
///                 correction; elevation = Kalman-fused phone altitude.
///                 Reduced interpolation weight (0.2) so it only gently biases
///                 the interpolated surface without overriding nearby LiDAR data.
enum CaptureType: String, Codable {
    case lidar
    case stickHeight
    case pathTrack
}

// MARK: - SurveyPoint

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
    /// For `.pathTrack` points this equals `fusedAltitude` (no ground correction).
    let groundElevation: Double

    /// Tilt-corrected vertical distance from device lens to the ground surface
    /// as measured by LiDAR.  0.0 for `.pathTrack` points.
    let lidarDistance: Double

    /// Raw GPS altitude from CLLocation (ellipsoidal, high noise).
    let gpsAltitude: Double

    /// CMAltimeter relative altitude delta from the start of the session.
    /// Highly precise (±0.1 m) but drifts over long sessions.
    /// 0.0 for `.pathTrack` points (not sampled per-breadcrumb).
    let baroAltitudeDelta: Double

    // MARK: - Orientation
    /// Device tilt from vertical (radians).  0 = device pointing straight up.
    /// 0.0 for `.pathTrack` points.
    let tiltAngle: Double

    // MARK: - Accuracy
    /// CLLocation horizontal accuracy (metres, 68% confidence radius).
    let horizontalAccuracy: Double

    /// CLLocation vertical accuracy (metres, 68% confidence).
    let verticalAccuracy: Double

    // MARK: - Quality flags
    /// Set by the outlier-detection pass.  Points flagged as outliers are
    /// excluded from DEM interpolation but kept in the session record.
    /// Always `false` for `.pathTrack` points (they bypass MAD detection).
    var isOutlier: Bool = false

    // MARK: - Track metadata
    /// How this point was acquired.  Controls outlier-detection inclusion and
    /// export classification.
    var captureType: CaptureType = .lidar

    /// Weight factor applied during IDW interpolation.
    /// 1.0 for `.lidar` and `.stickHeight` (full weight).
    /// 0.2 for `.pathTrack` (gentle shape hint — does not override nearby LiDAR).
    var interpolationWeight: Double = 1.0

    // MARK: - Memberwise init (with defaults for new fields)

    init(
        id:                  UUID    = UUID(),
        timestamp:           Date    = Date(),
        latitude:            Double,
        longitude:           Double,
        fusedAltitude:       Double,
        groundElevation:     Double,
        lidarDistance:       Double,
        gpsAltitude:         Double,
        baroAltitudeDelta:   Double,
        tiltAngle:           Double,
        horizontalAccuracy:  Double,
        verticalAccuracy:    Double,
        isOutlier:           Bool    = false,
        captureType:         CaptureType  = .lidar,
        interpolationWeight: Double  = 1.0
    ) {
        self.id                  = id
        self.timestamp           = timestamp
        self.latitude            = latitude
        self.longitude           = longitude
        self.fusedAltitude       = fusedAltitude
        self.groundElevation     = groundElevation
        self.lidarDistance       = lidarDistance
        self.gpsAltitude         = gpsAltitude
        self.baroAltitudeDelta   = baroAltitudeDelta
        self.tiltAngle           = tiltAngle
        self.horizontalAccuracy  = horizontalAccuracy
        self.verticalAccuracy    = verticalAccuracy
        self.isOutlier           = isOutlier
        self.captureType         = captureType
        self.interpolationWeight = interpolationWeight
    }
}

// MARK: - CoreLocation helpers

import CoreLocation

extension SurveyPoint {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Debug

extension SurveyPoint: CustomStringConvertible {
    var description: String {
        String(
            format: "SurveyPoint(%.6f°, %.6f°, elev=%.2f m, fused=%.2f m, lidar=%.2f m, type=%@)",
            latitude, longitude, groundElevation, fusedAltitude, lidarDistance,
            captureType.rawValue
        )
    }
}
