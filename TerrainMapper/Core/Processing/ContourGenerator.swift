// ContourGenerator.swift
// TerrainMapper
//
// Extracts iso-elevation contour lines from a TerrainGrid using the
// Marching Squares algorithm.
//
// ─── Marching Squares overview ────────────────────────────────────────────
// For each 2×2 cell of the grid, assign a binary index (0 or 1) to each
// corner based on whether its elevation is above the current contour level.
// The 4-bit cell index (0–15) indexes a lookup table that specifies which
// edges the contour crosses.
//
// Linear interpolation along each crossing edge gives the exact intersection
// coordinate.  Segments from adjacent cells are then stitched into polylines.
//
// ─── Ambiguous cases (5 and 10) ───────────────────────────────────────────
// Cases 5 (0101) and 10 (1010) have two possible interpretations (saddle
// points).  We always use the average of the four corners to break the
// ambiguity — this is equivalent to the "asymptotic decider" approach and
// produces smooth saddle curves.
//
// ─── Coordinate output ────────────────────────────────────────────────────
// Interpolated intersection points are converted back to (latitude, longitude)
// using the grid's origin and cell-size parameters.  All output coordinates
// are in decimal degrees (WGS-84).

import Foundation

struct ContourGenerator {

    // MARK: - Configuration

    /// Minimum number of points a contour segment must have to be emitted.
    var minPointsPerContour: Int = 3

    // MARK: - Public API

    /// Generate iso-elevation contour lines from a TerrainGrid.
    ///
    /// - Parameters:
    ///   - grid: The elevation raster to contour.
    ///   - interval: Elevation spacing between contours (metres, default 0.5).
    /// - Returns: Array of `ContourLine`, one per iso-level per connected polyline.
    func generateContours(from grid: TerrainGrid, interval: Double = 0.5) -> [ContourLine] {
        guard grid.height > 1, grid.width > 1,
              let validElevs = optionalLet(grid.validElevations) else { return [] }
        guard !validElevs.isEmpty else { return [] }

        let minElev = validElevs.min()!
        let maxElev = validElevs.max()!
        guard maxElev - minElev > interval / 2 else { return [] }

        // Contour levels: round to nearest multiple of interval above/below range
        let firstLevel = ceil(minElev / interval) * interval
        var levels: [Double] = []
        var lev = firstLevel
        while lev < maxElev {
            levels.append(lev)
            lev += interval
        }

        var allContours: [ContourLine] = []
        for level in levels {
            let segs = extractSegments(from: grid, level: level)
            let lines = stitchSegments(segs, level: level, grid: grid)
            allContours.append(contentsOf: lines)
        }
        return allContours
    }

    // MARK: - Segment extraction (Marching Squares)

    /// A raw line segment in grid-index space: two (col, row) fractional positions.
    private struct GridSegment {
        let x0: Double, y0: Double   // column and row indices (fractional)
        let x1: Double, y1: Double
    }

    private func extractSegments(from grid: TerrainGrid, level: Double) -> [GridSegment] {
        var segments: [GridSegment] = []

        for row in 0..<(grid.height - 1) {
            for col in 0..<(grid.width - 1) {
                // Four corners of the cell (CCW: SW, SE, NE, NW)
                guard let v00 = grid.elevation(row: row,     col: col),      // SW
                      let v10 = grid.elevation(row: row,     col: col + 1),  // SE
                      let v11 = grid.elevation(row: row + 1, col: col + 1),  // NE
                      let v01 = grid.elevation(row: row + 1, col: col)       // NW
                else { continue }

                // Cell index: bit 0 = SW, bit 1 = SE, bit 2 = NE, bit 3 = NW
                let idx =  (v00 >= level ? 1 : 0)
                         | (v10 >= level ? 2 : 0)
                         | (v11 >= level ? 4 : 0)
                         | (v01 >= level ? 8 : 0)

                if idx == 0 || idx == 15 { continue }   // all below / all above

                // Linear interpolation along edges
                // Bottom edge: (row, col) — (row, col+1)
                let tB = (idx & 3) == 1 || (idx & 3) == 2 ? interp(v00, v10, level) : 0.0
                // Right edge:  (row, col+1) — (row+1, col+1)
                let tR = interp(v10, v11, level)
                // Top edge:    (row+1, col) — (row+1, col+1)
                let tT = interp(v01, v11, level)
                // Left edge:   (row, col) — (row+1, col)
                let tL = interp(v00, v01, level)

                // Edge midpoint coordinates in grid-index space
                let bot: (Double, Double) = (Double(col) + tB,     Double(row))
                let rgt: (Double, Double) = (Double(col) + 1,      Double(row) + tR)
                let top: (Double, Double) = (Double(col) + tT,     Double(row) + 1)
                let lft: (Double, Double) = (Double(col),           Double(row) + tL)

                // Lookup table — 16 cases (multiple segments for saddle cases)
                var pairs: [(from: (Double,Double), to: (Double,Double))] = []
                switch idx {
                case 1:  pairs = [(bot, lft)]
                case 2:  pairs = [(bot, rgt)]
                case 3:  pairs = [(lft, rgt)]
                case 4:  pairs = [(top, rgt)]
                case 5:  // saddle — split based on cell average
                    let avg = (v00 + v10 + v11 + v01) / 4
                    if avg >= level {
                        pairs = [(bot, lft), (top, rgt)]
                    } else {
                        pairs = [(bot, rgt), (top, lft)]
                    }
                case 6:  pairs = [(bot, top)]
                case 7:  pairs = [(lft, top)]
                case 8:  pairs = [(top, lft)]
                case 9:  pairs = [(bot, top)]
                case 10: // saddle
                    let avg = (v00 + v10 + v11 + v01) / 4
                    if avg >= level {
                        pairs = [(bot, rgt), (top, lft)]
                    } else {
                        pairs = [(bot, lft), (top, rgt)]
                    }
                case 11: pairs = [(rgt, top)]
                case 12: pairs = [(lft, rgt)]
                case 13: pairs = [(bot, rgt)]
                case 14: pairs = [(bot, lft)]
                default: break
                }

                for (from, to) in pairs {
                    segments.append(GridSegment(x0: from.0, y0: from.1,
                                                x1: to.0,   y1: to.1))
                }
            }
        }
        return segments
    }

    /// Linear interpolation parameter t ∈ [0, 1] for the crossing point.
    private func interp(_ a: Double, _ b: Double, _ level: Double) -> Double {
        guard abs(b - a) > 1e-9 else { return 0.5 }
        return (level - a) / (b - a)
    }

    // MARK: - Segment stitching

    /// Stitch raw grid segments into connected polylines.
    private func stitchSegments(_ segs: [GridSegment], level: Double, grid: TerrainGrid) -> [ContourLine] {
        guard !segs.isEmpty else { return [] }

        // Build adjacency: key = rounded endpoint, value = list of segment indices
        typealias Key = SIMD2<Int32>
        func quantize(_ x: Double, _ y: Double) -> Key {
            Key(Int32(round(x * 1000)), Int32(round(y * 1000)))
        }

        var adjacency: [Key: [Int]] = [:]
        for (i, seg) in segs.enumerated() {
            adjacency[quantize(seg.x0, seg.y0), default: []].append(i)
            adjacency[quantize(seg.x1, seg.y1), default: []].append(i)
        }

        var used = [Bool](repeating: false, count: segs.count)
        var contours: [ContourLine] = []

        for startIdx in 0..<segs.count where !used[startIdx] {
            var chain: [(Double, Double)] = []
            var current = startIdx
            var fromEnd = false   // which end of current segment we're growing from

            // Walk forward
            used[current] = true
            chain.append((segs[current].x0, segs[current].y0))
            chain.append((segs[current].x1, segs[current].y1))
            var tip = (segs[current].x1, segs[current].y1)

            var growing = true
            while growing {
                growing = false
                let key = quantize(tip.0, tip.1)
                guard let candidates = adjacency[key] else { break }
                for nextIdx in candidates where !used[nextIdx] {
                    let s = segs[nextIdx]
                    used[nextIdx] = true
                    let startMatch = abs(s.x0 - tip.0) < 0.002 && abs(s.y0 - tip.1) < 0.002
                    if startMatch {
                        chain.append((s.x1, s.y1))
                        tip = (s.x1, s.y1)
                    } else {
                        chain.append((s.x0, s.y0))
                        tip = (s.x0, s.y0)
                    }
                    growing = true
                    break
                }
            }

            guard chain.count >= minPointsPerContour else { continue }

            // Convert grid-index coordinates to lat/lon
            let coords: [(latitude: Double, longitude: Double)] = chain.map { (gx, gy) in
                let lat = grid.originLatitude  + gy * grid.resolutionDegrees
                let lon = grid.originLongitude + gx * grid.resolutionDegrees
                return (lat, lon)
            }

            let first = chain.first!, last = chain.last!
            let closed = abs(first.0 - last.0) < 0.002 && abs(first.1 - last.1) < 0.002
            contours.append(ContourLine(elevation: level, coordinates: coords, isClosed: closed))
        }
        return contours
    }

    // MARK: - Helper

    private func optionalLet(_ arr: [Double]) -> [Double]? {
        arr.isEmpty ? nil : arr
    }
}
