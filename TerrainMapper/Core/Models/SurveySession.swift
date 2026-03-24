// SurveySession.swift
// TerrainMapper
//
// A container for all SurveyPoints collected during one field session.
// Provides helpers for outlier detection, loop-closure correction bookkeeping,
// and simple statistics used by the UI.

import Foundation

/// Represents one end-to-end survey session in the field.
///
/// Geoid correction:
/// iOS GPS reports ellipsoidal (WGS-84) altitude.  True elevation above mean sea
/// level (orthometric height) = ellipsoidal_altitude − geoid_undulation.
/// `geoidOffset` stores the EGM96 geoid undulation for the session centroid so
/// that `groundElevation` values can be rendered as AMSL when needed.
struct SurveySession: Identifiable, Codable {
    // MARK: - Identity
    let id: UUID
    let startTime: Date
    var endTime: Date?

    // MARK: - Points

    /// Explicitly captured survey points (LiDAR or stick-height).
    /// These are the primary measurements — full interpolation weight (1.0).
    var points: [SurveyPoint]

    /// Passive GPS breadcrumbs recorded automatically between captures.
    /// Stored separately so all existing processing (outlier detection,
    /// loop closure, PDR refinement) operates only on `points`.
    /// Fed into the terrain interpolator with reduced weight (0.2) to
    /// act as soft shape hints between capture locations.
    var pathTrackPoints: [SurveyPoint]

    // MARK: - Configuration
    /// Fallback measurement-stick height (metres) used when LiDAR is unavailable.
    /// The operator enters this before starting a session.
    var stickHeight: Double

    /// Optional user-provided name for this session (displayed in history).
    /// Auto-generated from start time if not set.
    var name: String

    /// EGM96 geoid undulation (metres) at the session centroid.
    /// Positive value means WGS-84 ellipsoid is above geoid (most land areas).
    /// Populated after the first GPS fix by looking up the local EGM96 table.
    var geoidOffset: Double

    // MARK: - ARKit VIO positioning data

    /// ARKit world-space (x, z) positions recorded at each capture point,
    /// keyed by the SurveyPoint UUID string.  Nil on sessions recorded before
    /// ARKit VIO tracking was introduced (backward-compatible optional).
    ///
    /// Stored as `[String: [Double]]` rather than `[UUID: simd_float3]` for
    /// Codable compatibility.  Each value is `[x, z]` in ARKit world metres.
    var arkitPositions: [String: [Double]]? = nil

    /// Compass heading (degrees CW from true north) at the time the ARKit
    /// session started.  Used to rotate ARKit world XZ to geographic East/North.
    var arkitAnchorHeading: Double? = nil

    /// Downsampled AR mesh world-space vertices captured during the session.
    /// Each element is `[x, y, z]` in ARKit world metres.
    /// Optional for backward compatibility with sessions saved before this field existed.
    var arMeshWorldVertices: [[Float]]? = nil

    // MARK: - Initialisers

    init(stickHeight: Double = 1.1, geoidOffset: Double = 0.0, name: String = "") {
        self.id              = UUID()
        self.startTime       = Date()
        self.endTime         = nil
        self.points          = []
        self.pathTrackPoints = []
        self.stickHeight     = stickHeight
        self.name            = name
        self.geoidOffset     = geoidOffset
    }
}

// MARK: - Derived statistics
extension SurveySession {
    /// Duration of the session.  Returns nil if the session is still open.
    var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    /// Non-outlier points only.
    var validPoints: [SurveyPoint] {
        points.filter { !$0.isOutlier }
    }

    /// Bounding box of valid points as (minLat, maxLat, minLon, maxLon).
    var boundingBox: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)? {
        guard !validPoints.isEmpty else { return nil }
        let lats = validPoints.map(\.latitude)
        let lons = validPoints.map(\.longitude)
        return (lats.min()!, lats.max()!, lons.min()!, lons.max()!)
    }

    /// Elevation range of valid points (min, max) in metres.
    var elevationRange: (min: Double, max: Double)? {
        guard !validPoints.isEmpty else { return nil }
        let elevs = validPoints.map(\.groundElevation)
        return (elevs.min()!, elevs.max()!)
    }

    // MARK: - Outlier detection

    /// Flag points whose ground elevation deviates more than `sigma` standard
    /// deviations from the median.  Uses median absolute deviation (MAD) which
    /// is robust to the very outliers we're trying to flag.
    mutating func detectOutliers(sigma: Double = 3.0) {
        guard points.count >= 4 else { return }

        let elevs = points.map(\.groundElevation).sorted()
        let median = elevs[elevs.count / 2]

        // MAD: median of |xᵢ - median|
        let deviations = elevs.map { abs($0 - median) }.sorted()
        let mad = deviations[deviations.count / 2]

        // Scale factor 1.4826 makes MAD consistent with σ for normal data
        let robustSigma = 1.4826 * mad

        guard robustSigma > 0 else { return }

        for i in points.indices {
            let z = abs(points[i].groundElevation - median) / robustSigma
            points[i].isOutlier = z > sigma
        }
    }
}
