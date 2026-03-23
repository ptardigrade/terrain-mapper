// TerrainTypes.swift
// TerrainMapper
//
// Shared data types used across the post-processing pipeline, 3D rendering,
// contour generation, and export system.

import Foundation
import CoreLocation

// MARK: - TerrainGrid

/// A regular geographic raster of elevation values produced by IDW or kriging
/// interpolation.
///
/// Coordinate convention:
/// - `originLatitude` / `originLongitude` refer to the **south-west** (min lat, min lon) corner.
/// - Row index increases northward; column index increases eastward.
/// - Cell (row, col) covers the area:
///     lat ∈ [originLat + row·resDeg, originLat + (row+1)·resDeg]
///     lon ∈ [originLon + col·resDeg, originLon + (col+1)·resDeg]
struct TerrainGrid {
    /// South-west corner latitude (degrees, WGS-84).
    let originLatitude: Double
    /// South-west corner longitude (degrees, WGS-84).
    let originLongitude: Double
    /// Cell size in degrees (same for latitude and longitude).
    let resolutionDegrees: Double
    /// Approximate cell size in metres (computed at the grid centroid).
    let resolutionMeters: Double
    /// Number of columns (east-west).
    let width: Int
    /// Number of rows (north-south).
    let height: Int
    /// Elevation values in metres.  `nil` = no-data (outside convex hull).
    /// Indexed as `elevations[row][col]`.
    var elevations: [[Double?]]

    /// Elevation at (row, col).  Returns nil for out-of-bounds indices.
    func elevation(row: Int, col: Int) -> Double? {
        guard row >= 0, row < height, col >= 0, col < width else { return nil }
        return elevations[row][col]
    }

    /// Geographic coordinates of the centre of cell (row, col).
    func coordinate(row: Int, col: Int) -> CLLocationCoordinate2D {
        let lat = originLatitude  + (Double(row) + 0.5) * resolutionDegrees
        let lon = originLongitude + (Double(col) + 0.5) * resolutionDegrees
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// All non-nil elevation values (used for statistics).
    var validElevations: [Double] {
        elevations.flatMap { $0 }.compactMap { $0 }
    }

    /// Laplacian smoothing: replaces each cell's elevation with a weighted
    /// average of itself (0.5) and its non-nil 8-neighbours (0.5).
    /// Nil cells remain nil.  Uses a temporary copy per iteration to avoid
    /// read-during-write artifacts.
    mutating func smooth(iterations: Int) {
        for _ in 0..<iterations {
            var next = elevations
            for row in 0..<height {
                for col in 0..<width {
                    guard let center = elevations[row][col] else { continue }
                    var sum = 0.0
                    var count = 0
                    for dr in -1...1 {
                        for dc in -1...1 {
                            if dr == 0 && dc == 0 { continue }
                            let nr = row + dr, nc = col + dc
                            guard nr >= 0, nr < height, nc >= 0, nc < width,
                                  let val = elevations[nr][nc] else { continue }
                            sum += val
                            count += 1
                        }
                    }
                    if count >= 3 {
                        next[row][col] = 0.5 * center + 0.5 * (sum / Double(count))
                    }
                }
            }
            elevations = next
        }
    }
}

// MARK: - TerrainMesh

/// A 3-D triangulated surface built from survey points.
///
/// Vertex positions are stored in a local East-North-Up coordinate frame
/// (metres from `originLatitude` / `originLongitude`):
///   x = east  (metres)
///   y = north (metres)
///   z = up    (metres, = elevation)
struct TerrainVertex {
    /// Local east offset from mesh origin (metres).
    var x: Double
    /// Local north offset from mesh origin (metres).
    var y: Double
    /// Elevation / up (metres).
    var z: Double
    /// Unit normal (nx, ny, nz).
    var nx: Double
    var ny: Double
    var nz: Double
    /// Original elevation value (before local-frame conversion) — used for colouring.
    var elevation: Double
    /// UV texture coordinates mapped by elevation (0 = min, 1 = max).
    var u: Double
    var v: Double
}

struct TerrainMesh {
    var vertices: [TerrainVertex]
    /// Counter-clockwise triangles (when viewed from above).
    var triangles: [(i0: Int, i1: Int, i2: Int)]
    /// Origin of the local coordinate frame.
    var originLatitude:  Double
    var originLongitude: Double
    var elevationMin: Double
    var elevationMax: Double

    /// Triangle count.
    var triangleCount: Int { triangles.count }
    /// Vertex count.
    var vertexCount:   Int { vertices.count }
}

// MARK: - ContourLine

/// A single contour iso-line at a given elevation.
struct ContourLine {
    let elevation: Double
    /// Ordered geographic coordinates forming the line (or closed loop).
    var coordinates: [(latitude: Double, longitude: Double)]
    /// True if the first and last coordinates are the same (closed contour).
    var isClosed: Bool
}

// MARK: - Processing stats

struct ProcessingStats {
    let inputPointCount:     Int
    let validPointCount:     Int
    let outlierCount:        Int
    let surveyedAreaM2:      Double
    let elevationMin:        Double
    let elevationMax:        Double
    /// Root-mean-square of GPS vertical accuracy values across valid points.
    let rmsAccuracyEstimate: Double
    let processingTimeSeconds: Double
    let loopClosureApplied:  Bool
    let geoidCorrectionApplied: Bool
}

// MARK: - ProcessedTerrain

/// The full output of the ProcessingPipeline for a completed SurveySession.
struct ProcessedTerrain {
    let session:      SurveySession
    let validPoints:  [SurveyPoint]
    let outlierPoints: [SurveyPoint]
    let grid:         TerrainGrid
    let mesh:         TerrainMesh
    let contours:     [ContourLine]
    let stats:        ProcessingStats
}

// MARK: - Enumerations

/// Spatial interpolation method for grid generation.
enum InterpolationMethod: String, CaseIterable, Identifiable {
    case idw     = "IDW"
    case kriging = "Kriging"
    var id: String { rawValue }
    var displayName: String { rawValue }
}

/// Supported export file formats.
enum ExportFormat: String, CaseIterable, Hashable, Identifiable {
    case ply     = "PLY"
    case las     = "LAS"
    case geoJSON = "GeoJSON"
    case geoTIFF = "GeoTIFF"
    case obj     = "OBJ"
    case dxf     = "DXF"
    case csv     = "CSV"
    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .ply:     return "ply"
        case .las:     return "las"
        case .geoJSON: return "geojson"
        case .geoTIFF: return "tif"
        case .obj:     return "obj"
        case .dxf:     return "dxf"
        case .csv:     return "csv"
        }
    }
    var description: String {
        switch self {
        case .ply:     return "3D Point Cloud (PLY)"
        case .las:     return "LiDAR LAS 1.4"
        case .geoJSON: return "GeoJSON"
        case .geoTIFF: return "GeoTIFF Raster"
        case .obj:     return "Wavefront OBJ Mesh"
        case .dxf:     return "AutoCAD DXF Contours (2D+3D)"
        case .csv:     return "Survey Points CSV"
        }
    }
}

// MARK: - Local coordinate helpers

/// Convert a WGS-84 coordinate to local East-North metres from a reference origin.
func latLonToEN(lat: Double, lon: Double,
                originLat: Double, originLon: Double) -> (east: Double, north: Double) {
    let R     = 6_371_000.0
    let east  = (lon - originLon) * (.pi / 180) * R * cos(originLat * .pi / 180)
    let north = (lat - originLat) * (.pi / 180) * R
    return (east, north)
}

/// Convert local East-North metres back to WGS-84.
func enToLatLon(east: Double, north: Double,
                originLat: Double, originLon: Double) -> (lat: Double, lon: Double) {
    let R   = 6_371_000.0
    let lat = originLat + north / R * (180 / .pi)
    let lon = originLon + east  / (R * cos(originLat * .pi / 180)) * (180 / .pi)
    return (lat, lon)
}
