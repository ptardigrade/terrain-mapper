// TerrainInterpolator.swift
// TerrainMapper
//
// Generates a regular elevation grid from an irregular set of survey points
// using either Inverse Distance Weighting (IDW) or Ordinary Kriging.
//
// ─── IDW (Inverse Distance Weighting) ────────────────────────────────────
// The elevation at a grid cell is the weighted average of nearby observations:
//
//   z(x) = Σ wᵢ·zᵢ / Σ wᵢ        wᵢ = 1 / dᵢᵖ
//
// where dᵢ is the Euclidean distance from x to observation i, and p is the
// power parameter (default p = 2, classic IDW).  Higher p gives more weight
// to close points; p = 1 is linear decay; p → ∞ = nearest-neighbour.
//
// A search radius `maxSearchRadius` limits which points influence each cell,
// and a minimum of `minNeighbours` points is required for interpolation.
//
// ─── Ordinary Kriging ─────────────────────────────────────────────────────
// Kriging is a geostatistical estimator that minimises prediction variance.
// Ordinary kriging assumes a stationary but unknown mean:
//
//   z*(x) = Σ λᵢ·z(xᵢ)      subject to Σ λᵢ = 1
//
// The weights λᵢ are obtained by solving the kriging system:
//
//   [Γ  1] [λ]   [γ(x)]
//   [1ᵀ 0] [μ] = [  1 ]
//
// where Γᵢⱼ = γ(|xᵢ − xⱼ|) is the semi-variogram evaluated between
// observation pairs, and γ(x) is the vector of semi-variogram values
// between query point and observations.
//
// Spherical variogram model:
//   γ(h) = c₀ + c₁ × [1.5(h/a) − 0.5(h/a)³]   for h ≤ a
//   γ(h) = c₀ + c₁                               for h > a
//
// Parameters (c₀, c₁, a) are estimated automatically from the data using
// the method of moments on the empirical semi-variogram.
//
// Note: Kriging requires solving an (N+1)×(N+1) linear system per grid cell.
// We limit N to `maxKrigingNeighbours` (default 20) for performance.

import Foundation

struct TerrainInterpolator {

    // MARK: - Configuration

    var power: Double = 2.0               // IDW power
    var gridResolutionMeters: Double = 0.5 // metres per cell (default)
    var maxSearchRadiusMeters: Double = 30.0
    var minNeighbours: Int = 3
    var maxKrigingNeighbours: Int = 20

    // MARK: - Public API

    /// Interpolate survey points to a regular grid.
    ///
    /// - Parameters:
    ///   - points: Valid (non-outlier) survey points.
    ///   - resolution: Cell size in metres (overrides stored `gridResolutionMeters`).
    ///   - method: Interpolation algorithm.
    /// - Returns: A `TerrainGrid` with elevation values.
    func interpolate(
        points: [SurveyPoint],
        resolution: Double? = nil,
        method: InterpolationMethod = .idw
    ) -> TerrainGrid {
        let res = resolution ?? gridResolutionMeters
        // Guard against zero/negative resolution which would cause division-by-zero below.
        guard res > 0 else {
            return emptyGrid(resolution: 0.5)
        }
        guard !points.isEmpty else {
            return emptyGrid(resolution: res)
        }

        // ── Compute bounding box & origin ──────────────────────────────────
        let lats = points.map(\.latitude)
        let lons = points.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!

        let centLat = (minLat + maxLat) / 2
        let centLon = (minLon + maxLon) / 2

        // Padding: one resolution cell on each side
        let R = 6_371_000.0
        let resDeg = res / (R * .pi / 180)
        let originLat = minLat - resDeg
        let originLon = minLon - resDeg

        // Grid dimensions
        let spanLat  = (maxLat - minLat) + 2 * resDeg
        let spanLon  = (maxLon - minLon) + 2 * resDeg
        let width    = max(2, Int(ceil(spanLon / resDeg)))
        let height   = max(2, Int(ceil(spanLat / resDeg)))

        // ── Convert points to local EN metres ─────────────────────────────
        let localPts: [(x: Double, y: Double, z: Double)] = points.map { p in
            let (e, n) = latLonToEN(lat: p.latitude, lon: p.longitude,
                                    originLat: centLat, originLon: centLon)
            return (e, n, p.groundElevation)
        }

        // ── Fit variogram if kriging ───────────────────────────────────────
        var vario = VariogramParams(c0: 0, c1: 1, a: maxSearchRadiusMeters)
        if case .kriging = method {
            vario = fitVariogram(points: localPts)
        }

        // ── Fill grid ─────────────────────────────────────────────────────
        var elevations = [[Double?]](repeating: [Double?](repeating: nil, count: width),
                                     count: height)

        for row in 0..<height {
            for col in 0..<width {
                let lat = originLat + (Double(row) + 0.5) * resDeg
                let lon = originLon + (Double(col) + 0.5) * resDeg
                let (qx, qy) = latLonToEN(lat: lat, lon: lon,
                                           originLat: centLat, originLon: centLon)

                // Find neighbours within search radius
                let neighbours = nearestPoints(localPts, to: (qx, qy),
                                                maxRadius: maxSearchRadiusMeters)
                guard neighbours.count >= minNeighbours else { continue }

                switch method {
                case .idw:
                    elevations[row][col] = idwEstimate(neighbours: neighbours, power: power)
                case .kriging:
                    let knnFull = nearestPointsWithCoordinates(localPts, to: (qx, qy),
                                                               maxRadius: maxSearchRadiusMeters)
                    let knn = Array(knnFull.prefix(maxKrigingNeighbours))
                    elevations[row][col] = krigingEstimate(neighbours: knn, vario: vario)
                }
            }
        }

        let approxResMeters = resDeg * R * .pi / 180
        return TerrainGrid(
            originLatitude:    originLat,
            originLongitude:   originLon,
            resolutionDegrees: resDeg,
            resolutionMeters:  approxResMeters,
            width:             width,
            height:            height,
            elevations:        elevations
        )
    }

    // MARK: - IDW

    private func idwEstimate(
        neighbours: [(dist: Double, z: Double)],
        power p: Double
    ) -> Double {
        // Handle case where a point is exactly at the query location
        if let exact = neighbours.first(where: { $0.dist < 1e-6 }) {
            return exact.z
        }
        var wSum = 0.0, wzSum = 0.0
        for (d, z) in neighbours {
            let w = 1.0 / pow(d, p)
            wSum  += w
            wzSum += w * z
        }
        return wSum > 0 ? wzSum / wSum : neighbours[0].z
    }

    // MARK: - Kriging

    private struct VariogramParams {
        var c0: Double   // nugget  (variance at h = 0+)
        var c1: Double   // partial sill
        var a:  Double   // range (metres) — beyond this, variance is constant
    }

    /// Semi-variogram value for spherical model γ(h).
    private func semiVariogram(_ h: Double, vario: VariogramParams) -> Double {
        if h <= 0 { return 0 }
        if h >= vario.a {
            return vario.c0 + vario.c1
        }
        let r = h / vario.a
        return vario.c0 + vario.c1 * (1.5 * r - 0.5 * r * r * r)
    }

    /// Fit spherical variogram parameters from the data using method-of-moments.
    private func fitVariogram(points: [(x: Double, y: Double, z: Double)]) -> VariogramParams {
        let n = points.count
        guard n >= 4 else {
            return VariogramParams(c0: 0, c1: 1, a: maxSearchRadiusMeters)
        }

        // Build empirical semi-variogram in 10 lag bins up to maxSearchRadius
        let numBins  = 10
        let binWidth = maxSearchRadiusMeters / Double(numBins)
        var bins     = [(sum: Double, count: Int)](repeating: (0, 0), count: numBins)

        for i in 0..<n {
            for j in (i+1)..<n {
                let dx = points[i].x - points[j].x
                let dy = points[i].y - points[j].y
                let h  = sqrt(dx*dx + dy*dy)
                guard h < maxSearchRadiusMeters else { continue }
                let binIdx = min(numBins - 1, Int(h / binWidth))
                let halfSq = 0.5 * (points[i].z - points[j].z) * (points[i].z - points[j].z)
                bins[binIdx].sum   += halfSq
                bins[binIdx].count += 1
            }
        }

        // Empirical γ(h) at bin centres
        let empirical: [(h: Double, g: Double)] = bins.enumerated().compactMap { idx, bin in
            guard bin.count > 0 else { return nil }
            return ((Double(idx) + 0.5) * binWidth, bin.sum / Double(bin.count))
        }
        guard !empirical.isEmpty else {
            return VariogramParams(c0: 0, c1: 1, a: maxSearchRadiusMeters)
        }

        // Estimate sill (max empirical variance) and range (lag at 95% of sill)
        let sill   = empirical.map(\.g).max() ?? 1.0
        let nugget = empirical.first?.g ?? 0.0
        let partialSill = max(1e-6, sill - nugget)
        let range  = empirical.first(where: { $0.g >= 0.95 * sill })?.h
                     ?? maxSearchRadiusMeters * 0.8

        return VariogramParams(c0: max(0, nugget), c1: partialSill, a: range)
    }

    /// Solve ordinary kriging system for the given neighbours.
    private func krigingEstimate(
        neighbours: [(dist: Double, z: Double, x: Double, y: Double)],
        vario: VariogramParams
    ) -> Double {
        let n = neighbours.count
        guard n >= 2 else { return neighbours[0].z }

        // Build (n+1)×(n+1) kriging matrix A (including Lagrange multiplier row/col)
        var A = [[Double]](repeating: [Double](repeating: 0.0, count: n + 1), count: n + 1)
        for i in 0..<n {
            for j in 0..<n {
                let dx = neighbours[i].x - neighbours[j].x
                let dy = neighbours[i].y - neighbours[j].y
                let h  = sqrt(dx*dx + dy*dy)
                A[i][j] = semiVariogram(h, vario: vario)
            }
            A[i][n] = 1.0   // Lagrange column
            A[n][i] = 1.0   // Lagrange row
        }
        A[n][n] = 0.0

        // Right-hand side b (variogram from query point to each neighbour)
        var b = [Double](repeating: 0.0, count: n + 1)
        for i in 0..<n {
            b[i] = semiVariogram(neighbours[i].dist, vario: vario)
        }
        b[n] = 1.0

        // Solve Ax = b via Gaussian elimination with partial pivoting
        guard var x = gaussianElimination(A: A, b: b) else {
            return idwEstimate(neighbours: neighbours.map { ($0.dist, $0.z) }, power: power)
        }

        // Estimate = Σ λᵢ·zᵢ
        var estimate = 0.0
        for i in 0..<n { estimate += x[i] * neighbours[i].z }
        return estimate
    }

    // MARK: - Spatial search

    /// Returns the `(distance, z)` pairs for all points within `maxRadius` of `query`,
    /// sorted by ascending distance.  Also returns (x, y) for kriging variant.
    private func nearestPoints(
        _ pts: [(x: Double, y: Double, z: Double)],
        to query: (Double, Double),
        maxRadius: Double
    ) -> [(dist: Double, z: Double)] {
        var result: [(dist: Double, z: Double)] = []
        for p in pts {
            let dx = p.x - query.0, dy = p.y - query.1
            let d  = sqrt(dx*dx + dy*dy)
            if d <= maxRadius { result.append((d, p.z)) }
        }
        return result.sorted { $0.dist < $1.dist }
    }

    /// Nearest-neighbours variant that also returns (x, y) for kriging.
    private func nearestPointsWithCoordinates(
        _ pts: [(x: Double, y: Double, z: Double)],
        to query: (Double, Double),
        maxRadius: Double
    ) -> [(dist: Double, z: Double, x: Double, y: Double)] {
        var result: [(dist: Double, z: Double, x: Double, y: Double)] = []
        for p in pts {
            let dx = p.x - query.0, dy = p.y - query.1
            let d  = sqrt(dx*dx + dy*dy)
            if d <= maxRadius { result.append((d, p.z, p.x, p.y)) }
        }
        return result.sorted { $0.dist < $1.dist }
    }

    // MARK: - Linear algebra

    /// Gaussian elimination with partial pivoting.  Returns nil if singular.
    private func gaussianElimination(A: [[Double]], b: [Double]) -> [Double]? {
        let n = b.count
        var M = A.map { $0 + [0.0] }   // augmented matrix
        for i in 0..<n { M[i][n] = b[i] }

        for col in 0..<n {
            // Partial pivot
            var maxRow = col
            for row in (col+1)..<n {
                if abs(M[row][col]) > abs(M[maxRow][col]) { maxRow = row }
            }
            M.swapAt(col, maxRow)
            guard abs(M[col][col]) > 1e-12 else { return nil }

            for row in (col+1)..<n {
                let factor = M[row][col] / M[col][col]
                for k in col...n { M[row][k] -= factor * M[col][k] }
            }
        }

        // Back-substitution
        var x = [Double](repeating: 0.0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = M[i][n]
            for j in (i+1)..<n { s -= M[i][j] * x[j] }
            x[i] = s / M[i][i]
        }
        return x
    }

    // MARK: - Helpers

    private func emptyGrid(resolution: Double) -> TerrainGrid {
        TerrainGrid(originLatitude: 0, originLongitude: 0,
                    resolutionDegrees: resolution / 111_320,
                    resolutionMeters:  resolution,
                    width: 0, height: 0, elevations: [])
    }
}
