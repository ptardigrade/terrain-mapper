// MeshGenerator.swift
// TerrainMapper
//
// Generates a `TerrainMesh` from either survey points or a `TerrainGrid`
// using the Bowyer-Watson incremental Delaunay triangulation algorithm.
//
// ─── Bowyer-Watson overview ───────────────────────────────────────────────
// Given a set of 2D points P = {p₁…pₙ}:
//
//  1. Start with a super-triangle large enough to enclose all points.
//  2. For each new point p:
//     a. Find all existing triangles whose circumcircle contains p
//        (the "bad triangles").
//     b. Identify the polygonal boundary of the bad-triangle cavity
//        (edges shared by exactly one bad triangle).
//     c. Remove bad triangles.  Re-triangulate the cavity by connecting
//        each boundary edge to p.
//  3. Remove all triangles that share a vertex with the super-triangle.
//
// The result is the Delaunay triangulation, which maximises the minimum
// angle across all triangles (avoids thin slivers).
//
// ─── Coordinate system ────────────────────────────────────────────────────
// Triangulation is performed in local East-North metres (flat-Earth approx).
// Z (elevation) is attached after triangulation and not used in the 2D math.
// The origin of the local frame is the survey centroid.
//
// ─── Normal computation ───────────────────────────────────────────────────
// Per-vertex normals are computed as the average of adjacent face normals,
// weighted by face area.  Face normals use the right-hand cross product of
// two edge vectors, giving an upward-facing (+Z) normal for CCW triangles.

import Foundation

struct MeshGenerator {

    // MARK: - Public API

    /// Build a Delaunay mesh from survey points.
    func generateMesh(from points: [SurveyPoint]) -> TerrainMesh {
        guard points.count >= 3 else {
            return TerrainMesh(vertices: [], triangles: [],
                               originLatitude: 0, originLongitude: 0,
                               elevationMin: 0, elevationMax: 0)
        }
        let centLat = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let centLon = points.map(\.longitude).reduce(0, +) / Double(points.count)

        let local2D: [(x: Double, y: Double, z: Double)] = points.map { p in
            let (e, n) = latLonToEN(lat: p.latitude, lon: p.longitude,
                                    originLat: centLat, originLon: centLon)
            return (e, n, p.groundElevation)
        }
        return buildMesh(points2D: local2D, originLat: centLat, originLon: centLon)
    }

    /// Build a mesh from a regular grid (connects adjacent cells into triangles).
    func generateMesh(from grid: TerrainGrid) -> TerrainMesh {
        guard grid.width > 1 && grid.height > 1 else {
            return TerrainMesh(vertices: [], triangles: [],
                               originLatitude: grid.originLatitude,
                               originLongitude: grid.originLongitude,
                               elevationMin: 0, elevationMax: 0)
        }

        let centLat = grid.originLatitude  + Double(grid.height) * grid.resolutionDegrees / 2
        let centLon = grid.originLongitude + Double(grid.width)  * grid.resolutionDegrees / 2

        // Collect valid grid nodes as 2D points
        var pts: [(x: Double, y: Double, z: Double)] = []
        var rowColIndex = [[Int?]](repeating: [Int?](repeating: nil, count: grid.width),
                                   count: grid.height)

        for row in 0..<grid.height {
            for col in 0..<grid.width {
                guard let elev = grid.elevation(row: row, col: col) else { continue }
                let coord = grid.coordinate(row: row, col: col)
                let (e, n) = latLonToEN(lat: coord.latitude, lon: coord.longitude,
                                        originLat: centLat, originLon: centLon)
                rowColIndex[row][col] = pts.count
                pts.append((e, n, elev))
            }
        }

        // Generate triangles by splitting each valid 2×2 cell into 2 triangles
        var triangles: [(Int, Int, Int)] = []
        for row in 0..<(grid.height - 1) {
            for col in 0..<(grid.width - 1) {
                guard let v00 = rowColIndex[row][col],
                      let v10 = rowColIndex[row + 1][col],
                      let v01 = rowColIndex[row][col + 1],
                      let v11 = rowColIndex[row + 1][col + 1] else { continue }
                // Split into two CCW triangles
                triangles.append((v00, v01, v11))
                triangles.append((v00, v11, v10))
            }
        }

        return finalise(pts: pts, triangles: triangles,
                        originLat: centLat, originLon: centLon)
    }

    // MARK: - Bowyer-Watson Delaunay triangulation

    private func buildMesh(points2D pts: [(x: Double, y: Double, z: Double)],
                            originLat: Double, originLon: Double) -> TerrainMesh {
        let n = pts.count
        guard n >= 3 else {
            return TerrainMesh(vertices: [], triangles: [],
                               originLatitude: originLat, originLongitude: originLon,
                               elevationMin: 0, elevationMax: 0)
        }

        // ── Step 1: Build a super-triangle ──────────────────────────────
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!
        let minY = ys.min()!, maxY = ys.max()!
        let dx = maxX - minX, dy = maxY - minY
        let deltaMax = max(dx, dy)
        let midX = (minX + maxX) / 2, midY = (minY + maxY) / 2

        // Super-triangle vertices (indices n, n+1, n+2 in augmented points array)
        let superPts: [(x: Double, y: Double, z: Double)] = [
            (midX - 20 * deltaMax, midY - deltaMax,   0),
            (midX,                 midY + 20 * deltaMax, 0),
            (midX + 20 * deltaMax, midY - deltaMax,   0)
        ]
        var allPts = pts + superPts
        let sA = n, sB = n + 1, sC = n + 2

        // ── Step 2: Incrementally insert points ─────────────────────────
        struct Tri { let a, b, c: Int }
        struct Edge: Hashable { let a, b: Int
            init(_ p: Int, _ q: Int) { a = min(p,q); b = max(p,q) }
        }

        var triangulation: [Tri] = [Tri(a: sA, b: sB, c: sC)]

        for pIdx in 0..<n {
            let p = allPts[pIdx]

            // Find all triangles whose circumcircle contains p
            var bad: [Tri] = []
            for t in triangulation {
                if inCircumcircle(p: (p.x, p.y), tri: t, pts: allPts) {
                    bad.append(t)
                }
            }

            // Find the boundary polygon of the bad-triangle cavity
            var edgeCount: [Edge: Int] = [:]
            for t in bad {
                for edge in [Edge(t.a, t.b), Edge(t.b, t.c), Edge(t.c, t.a)] {
                    edgeCount[edge, default: 0] += 1
                }
            }
            let boundary = edgeCount.filter { $0.value == 1 }.map(\.key)

            // Remove bad triangles
            triangulation.removeAll { t in
                bad.contains(where: { $0.a == t.a && $0.b == t.b && $0.c == t.c })
            }

            // Re-triangulate the cavity
            for edge in boundary {
                // Ensure CCW winding relative to new point
                let t = Tri(a: edge.a, b: edge.b, c: pIdx)
                if isCCW(a: allPts[t.a], b: allPts[t.b], c: allPts[t.c]) {
                    triangulation.append(t)
                } else {
                    triangulation.append(Tri(a: edge.b, b: edge.a, c: pIdx))
                }
            }
        }

        // ── Step 3: Remove triangles sharing super-triangle vertices ────
        triangulation.removeAll { t in
            t.a >= n || t.b >= n || t.c >= n
        }

        // ── Step 4: Convert to (Int, Int, Int) array ────────────────────
        let indexedTriangles = triangulation.map { ($0.a, $0.b, $0.c) }
        return finalise(pts: pts, triangles: indexedTriangles,
                        originLat: originLat, originLon: originLon)
    }

    // MARK: - Circumcircle test

    /// Returns true if point `p` lies strictly inside the circumcircle of triangle `tri`.
    private func inCircumcircle(
        p: (x: Double, y: Double),
        tri: (a: Int, b: Int, c: Int),
        pts: [(x: Double, y: Double, z: Double)]
    ) -> Bool {
        let ax = pts[tri.a].x, ay = pts[tri.a].y
        let bx = pts[tri.b].x, by = pts[tri.b].y
        let cx = pts[tri.c].x, cy = pts[tri.c].y
        let px = p.x, py = p.y

        let D = 2 * (ax*(by-cy) + bx*(cy-ay) + cx*(ay-by))
        guard abs(D) > 1e-12 else { return false }

        let ux = ((ax*ax+ay*ay)*(by-cy) + (bx*bx+by*by)*(cy-ay) + (cx*cx+cy*cy)*(ay-by)) / D
        let uy = ((ax*ax+ay*ay)*(cx-bx) + (bx*bx+by*by)*(ax-cx) + (cx*cx+cy*cy)*(bx-ax)) / D

        let r2 = (ax-ux)*(ax-ux) + (ay-uy)*(ay-uy)
        let d2 = (px-ux)*(px-ux) + (py-uy)*(py-uy)
        return d2 < r2 - 1e-10
    }

    /// Returns true if points a→b→c are counter-clockwise (positive signed area).
    private func isCCW(
        a: (x: Double, y: Double, z: Double),
        b: (x: Double, y: Double, z: Double),
        c: (x: Double, y: Double, z: Double)
    ) -> Bool {
        let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        return cross > 0
    }

    // MARK: - Finalisation (normals, elevation range, vertex assembly)

    private func finalise(
        pts: [(x: Double, y: Double, z: Double)],
        triangles: [(Int, Int, Int)],
        originLat: Double,
        originLon: Double
    ) -> TerrainMesh {
        guard !pts.isEmpty else {
            return TerrainMesh(vertices: [], triangles: [],
                               originLatitude: originLat, originLongitude: originLon,
                               elevationMin: 0, elevationMax: 0)
        }

        let elevMin = pts.map(\.z).min() ?? 0
        let elevMax = pts.map(\.z).max() ?? 0
        let elevRange = max(1e-6, elevMax - elevMin)

        // Accumulate area-weighted normals per vertex
        var normals = [(nx: Double, ny: Double, nz: Double)](
            repeating: (0, 0, 0), count: pts.count)

        for (i0, i1, i2) in triangles {
            let v0 = pts[i0], v1 = pts[i1], v2 = pts[i2]
            let ex = v1.x - v0.x, ey = v1.y - v0.y, ez = v1.z - v0.z
            let fx = v2.x - v0.x, fy = v2.y - v0.y, fz = v2.z - v0.z
            // Cross product e × f
            let nx = ey * fz - ez * fy
            let ny = ez * fx - ex * fz
            let nz = ex * fy - ey * fx
            let area = sqrt(nx*nx + ny*ny + nz*nz) / 2
            for idx in [i0, i1, i2] {
                normals[idx].nx += nx * area
                normals[idx].ny += ny * area
                normals[idx].nz += nz * area
            }
        }

        // Build TerrainVertex array
        let vertices: [TerrainVertex] = pts.enumerated().map { idx, p in
            var n = normals[idx]
            let len = sqrt(n.nx*n.nx + n.ny*n.ny + n.nz*n.nz)
            if len > 1e-9 { n.nx /= len; n.ny /= len; n.nz /= len }
            else { n = (0, 0, 1) }
            let u = (p.z - elevMin) / elevRange   // UV by elevation
            return TerrainVertex(x: p.x, y: p.y, z: p.z,
                                 nx: n.nx, ny: n.ny, nz: n.nz,
                                 elevation: p.z, u: u, v: 0)
        }

        let indexedTris = triangles.map { (i0: $0.0, i1: $0.1, i2: $0.2) }
        return TerrainMesh(vertices: vertices, triangles: indexedTris,
                           originLatitude: originLat, originLongitude: originLon,
                           elevationMin: elevMin, elevationMax: elevMax)
    }
}
