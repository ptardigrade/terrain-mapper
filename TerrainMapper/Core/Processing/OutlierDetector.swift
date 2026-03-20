// OutlierDetector.swift
// TerrainMapper
//
// Identifies survey points whose ground elevation or LiDAR distance falls
// outside statistically plausible bounds, using two independent checks:
//
// 1. Geometric gate — rejects physically impossible LiDAR readings:
//    • lidarDistance < kMinLiDAR (0.1 m):  stick tip above sensor → reflection artifact
//    • lidarDistance > kMaxLiDAR (5.0 m):  no ground return within stick range
//
// 2. MAD outlier test on groundElevation:
//    Median Absolute Deviation (MAD) is used instead of standard deviation
//    because it is robust to the very outliers being detected.
//
//    z_MAD(x) = |x − median| / (1.4826 × MAD)
//
//    The scale factor 1.4826 makes MAD a consistent estimator of σ for
//    normally distributed data.  Points with z_MAD > threshold (default 3.5)
//    are flagged as outliers.
//
// Both checks are applied; a point failing either is flagged as isOutlier = true.

import Foundation

struct OutlierDetector {

    // MARK: - Configuration

    /// Minimum physically valid LiDAR distance (metres).
    var minLiDARDistance: Double = 0.10

    /// Maximum physically valid LiDAR distance (metres) — the longest stick.
    var maxLiDARDistance: Double = 5.00

    /// MAD z-score threshold.  3.5 is recommended for small survey datasets
    /// (more conservative than the classic 3.0 to avoid over-rejection).
    var madThreshold: Double = 3.5

    // MARK: - Public API

    /// Detect and flag outliers in `points`, mutating `isOutlier` in place.
    ///
    /// - Parameter points: The survey points to analyse (modified in place).
    func detectOutliers(in points: inout [SurveyPoint]) {
        guard !points.isEmpty else { return }

        // ── Pass 1: geometric gate ─────────────────────────────────────────
        for i in points.indices {
            let d = points[i].lidarDistance
            if d < minLiDARDistance || d > maxLiDARDistance {
                points[i] = flagged(points[i], reason: "LiDAR distance \(String(format: "%.2f", d)) m out of valid range")
            }
        }

        // ── Pass 2: MAD outlier test on groundElevation ───────────────────
        // Compute MAD only on geometrically valid (non-flagged) points.
        let validElevations = points
            .filter  { !$0.isOutlier }
            .map     { $0.groundElevation }
            .sorted  ()

        guard validElevations.count >= 4 else { return }

        let median    = validElevations.percentile(0.5)
        let deviations = validElevations
            .map     { abs($0 - median) }
            .sorted  ()
        let mad       = deviations.percentile(0.5)
        let robustSigma = 1.4826 * mad

        guard robustSigma > 1e-6 else { return }  // all elevations identical → skip

        for i in points.indices where !points[i].isOutlier {
            let z = abs(points[i].groundElevation - median) / robustSigma
            if z > madThreshold {
                points[i] = flagged(points[i], reason: "MAD z-score \(String(format: "%.1f", z)) > \(madThreshold)")
            }
        }
    }

    // MARK: - Diagnostic summary

    /// Returns a human-readable breakdown of flagged points and their reasons.
    func diagnosticSummary(for points: [SurveyPoint]) -> String {
        let total   = points.count
        let flagged = points.filter(\.isOutlier).count
        let lidar   = points.filter { $0.lidarDistance < minLiDARDistance || $0.lidarDistance > maxLiDARDistance }.count
        return """
        OutlierDetector: \(flagged)/\(total) flagged
          • Geometric gate (LiDAR range): \(lidar)
          • MAD elevation test:           \(max(0, flagged - lidar))
        """
    }

    // MARK: - Private helpers

    private func flagged(_ point: SurveyPoint, reason: String) -> SurveyPoint {
        var p = point
        p.isOutlier = true
        return p
    }
}

// MARK: - Array percentile helper

private extension Array where Element == Double {
    /// Linearly interpolated percentile (0.0 = min, 0.5 = median, 1.0 = max).
    /// Array must be sorted ascending.
    func percentile(_ p: Double) -> Double {
        guard !isEmpty else { return 0 }
        if count == 1 { return self[0] }
        let idx  = p * Double(count - 1)
        let lo   = Int(idx)
        let hi   = min(lo + 1, count - 1)
        let frac = idx - Double(lo)
        return self[lo] * (1 - frac) + self[hi] * frac
    }
}
