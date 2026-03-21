// DifferentialElevationCorrector.swift
// TerrainMapper
//
// Post-processing step that recomputes ground elevations using a differential
// (relative) approach instead of per-point Kalman-fused absolute altitudes.
//
// ─── Problem ──────────────────────────────────────────────────────────────────
// The original pipeline computes:
//
//   groundElevation = fusedAltitude − lidarDistance
//
// where fusedAltitude comes from a Kalman filter fusing GPS altitude (~±5 m
// noise) and barometric delta (~±0.1 m noise).  Because the Kalman filter's
// GPS measurement update introduces ±3–5 m of random error into every fused
// altitude, the resulting ground elevations are noisy even though the LiDAR
// distance measurement is precise to ±1.5 cm.
//
// ─── Solution ─────────────────────────────────────────────────────────────────
// Observation: for terrain mapping we care about RELATIVE elevation differences
// between points far more than absolute altitude.  The barometer gives precise
// relative altitude (±0.1 m), and LiDAR gives precise ground distance (±0.015 m).
//
// The device altitude at any point i (relative to session start) is:
//
//   h_device(i) ≈ h_start + baroDelta(i)
//
// The ground elevation at point i is:
//
//   groundElev(i) = h_device(i) − lidarDistance(i)
//                 = h_start + baroDelta(i) − lidarDistance(i)
//
// The only unknown is h_start (the absolute altitude of the device at session
// start).  We estimate it robustly from all GPS readings:
//
//   h_start = median( gpsAltitude(i) − baroDelta(i) )   for all valid capture points
//
// This averages out GPS noise across N points (effective σ ≈ 5/√N m), while
// preserving ±0.12 m relative precision between points.
//
// ─── Expected improvement ─────────────────────────────────────────────────────
// Before: elevation spread across a flat 1.5 m grid = 3–6 m (GPS-dominated)
// After:  elevation spread across the same grid     ≈ 0.1–0.3 m (baro+LiDAR)

import Foundation

struct DifferentialElevationCorrector {

    /// Apply differential elevation correction to capture points.
    ///
    /// Only corrects points with `captureType != .pathTrack` because path-track
    /// breadcrumbs don't have per-point barometric readings.
    ///
    /// - Parameter points: Mutable array of survey points (already outlier-flagged).
    ///   Points are modified in place with corrected `groundElevation` and `fusedAltitude`.
    func correct(points: inout [SurveyPoint]) {
        // Collect non-outlier capture points that have real barometric data.
        let captureIndices = points.indices.filter { i in
            !points[i].isOutlier && points[i].captureType != .pathTrack
        }

        guard captureIndices.count >= 2 else { return }

        // ── Estimate h_start ────────────────────────────────────────────────
        // For each capture point:  h_start ≈ gpsAltitude − baroDelta
        // Take the median for robustness against GPS outliers.
        let h_start_estimates = captureIndices.map { i in
            points[i].gpsAltitude - points[i].baroAltitudeDelta
        }
        let h_start = median(h_start_estimates)

        // ── Recompute elevations ────────────────────────────────────────────
        // Apply to ALL capture points (including outliers, so diagnostic export
        // shows corrected values), but skip path-track points.
        for i in points.indices {
            guard points[i].captureType != .pathTrack else { continue }

            let baroDelta     = points[i].baroAltitudeDelta
            let lidarDist     = points[i].lidarDistance

            // Corrected device altitude (using baro-referenced baseline)
            let correctedDeviceAlt = h_start + baroDelta

            // Corrected ground elevation
            let correctedGroundElev = correctedDeviceAlt - lidarDist

            points[i] = SurveyPoint(
                id:                  points[i].id,
                timestamp:           points[i].timestamp,
                latitude:            points[i].latitude,
                longitude:           points[i].longitude,
                fusedAltitude:       correctedDeviceAlt,
                groundElevation:     correctedGroundElev,
                lidarDistance:       points[i].lidarDistance,
                gpsAltitude:         points[i].gpsAltitude,
                baroAltitudeDelta:   points[i].baroAltitudeDelta,
                tiltAngle:           points[i].tiltAngle,
                horizontalAccuracy:  points[i].horizontalAccuracy,
                verticalAccuracy:    points[i].verticalAccuracy,
                isOutlier:           points[i].isOutlier,
                captureType:         points[i].captureType,
                interpolationWeight: points[i].interpolationWeight
            )
        }
    }

    /// Also correct path-track points using the same h_start baseline.
    ///
    /// Path-track points don't have per-point baroDelta, but they DO have
    /// fusedAltitude from the Kalman filter.  We can improve them by applying
    /// a global offset: shift all path-track elevations by the average
    /// difference between old and new capture-point elevations.
    ///
    /// - Parameters:
    ///   - pathPoints: Mutable array of path-track breadcrumbs.
    ///   - capturePoints: Already-corrected capture points (for computing the offset).
    ///   - originalCapturePoints: Pre-correction capture points (for computing the offset).
    func correctPathTrack(
        pathPoints: inout [SurveyPoint],
        correctedCaptures: [SurveyPoint],
        originalCaptures: [SurveyPoint]
    ) {
        guard !pathPoints.isEmpty else { return }

        // Compute the median elevation shift applied to capture points.
        // Use this as a global offset for path-track points.
        let validIndices = correctedCaptures.indices.filter { i in
            !correctedCaptures[i].isOutlier && correctedCaptures[i].captureType != .pathTrack
        }
        guard !validIndices.isEmpty else { return }

        let shifts = validIndices.map { i in
            correctedCaptures[i].groundElevation - originalCaptures[i].groundElevation
        }
        let medianShift = median(shifts)

        for i in pathPoints.indices {
            let p = pathPoints[i]
            pathPoints[i] = SurveyPoint(
                id:                  p.id,
                timestamp:           p.timestamp,
                latitude:            p.latitude,
                longitude:           p.longitude,
                fusedAltitude:       p.fusedAltitude + medianShift,
                groundElevation:     p.groundElevation + medianShift,
                lidarDistance:       p.lidarDistance,
                gpsAltitude:         p.gpsAltitude,
                baroAltitudeDelta:   p.baroAltitudeDelta,
                tiltAngle:           p.tiltAngle,
                horizontalAccuracy:  p.horizontalAccuracy,
                verticalAccuracy:    p.verticalAccuracy,
                isOutlier:           p.isOutlier,
                captureType:         p.captureType,
                interpolationWeight: p.interpolationWeight
            )
        }
    }

    // MARK: - Helpers

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 {
            return sorted[n / 2]
        } else {
            return (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
        }
    }
}
