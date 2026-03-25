// LoopClosureProcessor.swift
// TerrainMapper
//
// Detects when a survey path returns to its starting location and applies a
// linear drift correction proportional to cumulative path distance.
//
// ─── Why loop closure matters ─────────────────────────────────────────────
// The Kalman filter's barometer channel accumulates drift over long sessions.
// If the operator walks a closed loop and returns to the start point, the
// true elevation change must be zero.  Any non-zero elevation discrepancy
// at the closing point is therefore pure drift.
//
// Rather than applying a single global offset (which would bias the midpoint
// of the loop most), we distribute the drift proportionally to the cumulative
// horizontal path distance travelled by the time each point was recorded.
//
//   correction[i] = total_drift × (cumulDist[i] / totalDist)
//
// This is equivalent to assuming the drift rate (m/metre walked) is constant,
// which is a reasonable model for both baro and GPS drift.
//
// ─── Closure detection ───────────────────────────────────────────────────
// We test whether the last point is within `kClosureRadius` metres of the
// first point, using the Haversine formula for horizontal distance.
// Vertical discrepancy is computed from the Kalman-fused altitudes.

import Foundation
import CoreLocation

struct LoopClosureProcessor {

    // MARK: - Configuration

    /// Maximum horizontal distance (metres) between first and last point for
    /// the loop to be considered closed.
    var closureRadiusMetres: Double = 10.0

    // MARK: - Public API

    /// Applies loop-closure drift correction to `points` (valid points only).
    ///
    /// - Parameter points: All survey points (mutated in place).
    /// - Returns: `true` if a closure was detected and correction applied.
    @discardableResult
    func applyLoopClosure(to points: inout [SurveyPoint]) -> Bool {
        let valid = points.indices.filter { !points[$0].isOutlier }
        guard valid.count >= 4 else { return false }

        let firstIdx = valid.first!
        let lastIdx  = valid.last!

        let first = points[firstIdx]
        let last  = points[lastIdx]

        // ── Closure detection ─────────────────────────────────────────────
        let horizontalDist = haversineMetres(
            lat1: first.latitude, lon1: first.longitude,
            lat2: last.latitude,  lon2: last.longitude
        )
        guard horizontalDist <= closureRadiusMetres else {
            return false   // not a closed loop
        }

        // ── Elevation discrepancy at closure ──────────────────────────────
        // The operator returned to the start → fusedAltitude should equal
        // first.fusedAltitude.  The residual is the accumulated drift.
        let totalDrift = last.fusedAltitude - first.fusedAltitude

        guard abs(totalDrift) > 0.01 else { return true }   // negligible drift

        // ── Cumulative path distance along valid points ───────────────────
        var cumDist: [Double] = []
        cumDist.reserveCapacity(valid.count)
        cumDist.append(0.0)

        for k in 1..<valid.count {
            let prev = points[valid[k - 1]]
            let curr = points[valid[k]]
            let d = haversineMetres(
                lat1: prev.latitude, lon1: prev.longitude,
                lat2: curr.latitude, lon2: curr.longitude
            )
            cumDist.append(cumDist[k - 1] + d)
        }
        let totalDist = cumDist.last ?? 1.0

        // ── Apply linear correction proportional to cumulative distance ───
        for (k, idx) in valid.enumerated() {
            let fraction   = totalDist > 0 ? cumDist[k] / totalDist : 0
            let correction = totalDrift * fraction   // metres to subtract
            let p = points[idx]
            points[idx] = SurveyPoint(
                id:                 p.id,
                timestamp:          p.timestamp,
                latitude:           p.latitude,
                longitude:          p.longitude,
                fusedAltitude:      p.fusedAltitude      - correction,
                groundElevation:    p.groundElevation     - correction,
                lidarDistance:      p.lidarDistance,
                gpsAltitude:        p.gpsAltitude,
                baroAltitudeDelta:  p.baroAltitudeDelta   - correction,
                tiltAngle:          p.tiltAngle,
                horizontalAccuracy: p.horizontalAccuracy,
                verticalAccuracy:   p.verticalAccuracy,
                isOutlier:          p.isOutlier
            )
        }

        return true
    }

    // MARK: - ARKit horizontal loop closure

    /// Applies linear horizontal drift correction to ARKit world-space positions
    /// when GPS indicates the user returned to the starting point.
    ///
    /// ARKit VIO accumulates horizontal drift over long sessions (typically 1–5 m
    /// over 20 minutes).  If the operator walks a closed loop, any discrepancy
    /// between the first and last ARKit XZ positions is pure drift.  We distribute
    /// this error linearly across all captured points in capture order.
    ///
    /// - Parameters:
    ///   - points: Capture points (used for GPS-based loop detection and ordering).
    ///   - arkitPositions: Mutable ARKit position dictionary `[UUID: [x, z, ...]]`.
    /// - Returns: `true` if a closure was detected and ARKit positions corrected.
    @discardableResult
    func applyArkitLoopClosure(
        points: [SurveyPoint],
        arkitPositions: inout [String: [Double]]
    ) -> Bool {
        // Non-outlier points that have ARKit data, in capture order
        let validWithArkit = points.filter {
            !$0.isOutlier && arkitPositions[$0.id.uuidString] != nil
        }
        guard validWithArkit.count >= 4 else { return false }

        let first = validWithArkit.first!
        let last  = validWithArkit.last!

        // Check GPS proximity (did the user return to start?)
        let horizontalDist = haversineMetres(
            lat1: first.latitude, lon1: first.longitude,
            lat2: last.latitude,  lon2: last.longitude
        )
        guard horizontalDist <= closureRadiusMetres else { return false }

        // Compute ARKit XZ drift between first and last position
        let firstPos = arkitPositions[first.id.uuidString]!
        let lastPos  = arkitPositions[last.id.uuidString]!
        let driftX = lastPos[0] - firstPos[0]
        let driftZ = lastPos[1] - firstPos[1]

        let driftMag = sqrt(driftX * driftX + driftZ * driftZ)
        guard driftMag > 0.1 else { return true }  // negligible drift

        // Linearly distribute correction across all points with ARKit data
        let n = validWithArkit.count
        for (k, p) in validWithArkit.enumerated() {
            let fraction = Double(k) / Double(n - 1)
            let key = p.id.uuidString
            guard var pos = arkitPositions[key] else { continue }
            pos[0] -= driftX * fraction
            pos[1] -= driftZ * fraction
            arkitPositions[key] = pos
        }

        return true
    }

    // MARK: - Query helpers

    /// Returns the horizontal closure distance in metres (first → last valid point).
    /// Returns `nil` if fewer than 2 valid points.
    func closureDistance(in points: [SurveyPoint]) -> Double? {
        let valid = points.filter { !$0.isOutlier }
        guard let first = valid.first, let last = valid.last, valid.count >= 2 else {
            return nil
        }
        return haversineMetres(
            lat1: first.latitude, lon1: first.longitude,
            lat2: last.latitude,  lon2: last.longitude
        )
    }

    // MARK: - Private

    private func haversineMetres(lat1: Double, lon1: Double,
                                  lat2: Double, lon2: Double) -> Double {
        let R   = 6_371_000.0
        let φ1  = lat1 * .pi / 180,  φ2 = lat2 * .pi / 180
        let Δφ  = (lat2 - lat1) * .pi / 180
        let Δλ  = (lon2 - lon1) * .pi / 180
        let a   = sin(Δφ/2)*sin(Δφ/2) + cos(φ1)*cos(φ2)*sin(Δλ/2)*sin(Δλ/2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
