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
    var points: [SurveyPoint]

    // MARK: - Configuration
    /// Fallback measurement-stick height (metres) used when LiDAR is unavailable.
    /// The operator enters this before starting a session.
    var stickHeight: Double

    /// EGM96 geoid undulation (metres) at the session centroid.
    /// Positive value means WGS-84 ellipsoid is above geoid (most land areas).
    /// Populated after the first GPS fix by looking up the local EGM96 table.
    var geoidOffset: Double

    // MARK: - Initialisers

    init(stickHeight: Double = 2.0, geoidOffset: Double = 0.0) {
        self.id          = UUID()
        self.startTime   = Date()
        self.endTime     = nil
        self.points      = []
        self.stickHeight = stickHeight
        self.geoidOffset = geoidOffset
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
