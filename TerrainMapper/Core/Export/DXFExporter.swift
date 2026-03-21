// DXFExporter.swift
// TerrainMapper
//
// Exports contour lines as AutoCAD DXF (Drawing Exchange Format).
// Produces a single .dxf file containing:
//   - 2D LWPOLYLINE entities on layer "CONTOUR_2D" (elevation in attributes)
//   - 3D POLYLINE entities on layer "CONTOUR_3D" (Z = elevation on every vertex)
//
// Coordinates are in the mesh's local East-North metre frame so that DXF
// imports at real-world scale.  The origin is the survey centroid.
//
// DXF Reference:
//   https://help.autodesk.com/view/OARX/2024/ENU/?guid=GUID-235B22E0-A567-4CF6-92D3-38A2306D73F3

import Foundation

final class DXFExporter {

    func export(terrain: ProcessedTerrain) throws -> Data {
        let contours = terrain.contours
        guard !contours.isEmpty else { throw ExportError.invalidTerrain }

        let originLat = terrain.mesh.originLatitude
        let originLon = terrain.mesh.originLongitude

        var dxf = ""

        // ── HEADER section ──────────────────────────────────────────────
        dxf += "0\nSECTION\n2\nHEADER\n"
        dxf += "9\n$ACADVER\n1\nAC1015\n"   // AutoCAD 2000 compatibility
        dxf += "9\n$INSUNITS\n70\n6\n"       // 6 = metres
        dxf += "0\nENDSEC\n"

        // ── TABLES section (layers) ─────────────────────────────────────
        dxf += "0\nSECTION\n2\nTABLES\n"
        dxf += "0\nTABLE\n2\nLAYER\n70\n2\n"
        // Layer: CONTOUR_2D — colour 3 (green)
        dxf += "0\nLAYER\n2\nCONTOUR_2D\n70\n0\n62\n3\n6\nCONTINUOUS\n"
        // Layer: CONTOUR_3D — colour 5 (blue)
        dxf += "0\nLAYER\n2\nCONTOUR_3D\n70\n0\n62\n5\n6\nCONTINUOUS\n"
        dxf += "0\nENDTAB\n"
        dxf += "0\nENDSEC\n"

        // ── ENTITIES section ────────────────────────────────────────────
        dxf += "0\nSECTION\n2\nENTITIES\n"

        for contour in contours {
            guard contour.coordinates.count >= 2 else { continue }

            // Convert geographic coordinates to local East-North metres
            let localPts = contour.coordinates.map { coord in
                latLonToEN(lat: coord.latitude, lon: coord.longitude,
                           originLat: originLat, originLon: originLon)
            }

            // ── 2D LWPOLYLINE (flat, elevation stored as attribute) ─────
            let vertexCount = localPts.count
            dxf += "0\nLWPOLYLINE\n8\nCONTOUR_2D\n"
            dxf += "90\n\(vertexCount)\n"       // vertex count
            dxf += "70\n\(contour.isClosed ? 1 : 0)\n"  // closed flag
            dxf += "38\n\(String(format: "%.4f", contour.elevation))\n"  // elevation
            for pt in localPts {
                dxf += "10\n\(String(format: "%.6f", pt.east))\n"
                dxf += "20\n\(String(format: "%.6f", pt.north))\n"
            }

            // ── 3D POLYLINE (vertices carry Z = elevation) ──────────────
            dxf += "0\nPOLYLINE\n8\nCONTOUR_3D\n"
            dxf += "66\n1\n"   // vertices follow
            dxf += "70\n\(contour.isClosed ? 9 : 8)\n"  // 8 = 3D polyline, +1 = closed
            for pt in localPts {
                dxf += "0\nVERTEX\n8\nCONTOUR_3D\n"
                dxf += "10\n\(String(format: "%.6f", pt.east))\n"
                dxf += "20\n\(String(format: "%.6f", pt.north))\n"
                dxf += "30\n\(String(format: "%.4f", contour.elevation))\n"
                dxf += "70\n32\n"  // 32 = 3D polyline vertex
            }
            dxf += "0\nSEQEND\n8\nCONTOUR_3D\n"
        }

        dxf += "0\nENDSEC\n"
        dxf += "0\nEOF\n"

        guard let data = dxf.data(using: .utf8) else {
            throw ExportError.invalidTerrain
        }
        return data
    }
}
