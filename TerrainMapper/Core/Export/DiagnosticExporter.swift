// DiagnosticExporter.swift
// TerrainMapper
//
// Developer-only export that dumps the complete raw sensor data for a survey
// session as a structured JSON file.  Intended for offline calibration and
// algorithm tuning — not user-facing export.
//
// The JSON contains:
//   - Session metadata (name, start/end, stick height, geoid offset)
//   - Every captured point with ALL raw sensor fields
//   - Every path-track breadcrumb
//   - Per-point derived fields (groundElevation, fusedAltitude, lidarDistance,
//     gpsAltitude, baroAltitudeDelta, tiltAngle, accuracies, captureType)
//   - Grid metadata (origin, resolution, dimensions)
//   - Processing stats

import Foundation

final class DiagnosticExporter {

    func export(terrain: ProcessedTerrain) throws -> Data {
        let session = terrain.session

        // Build the top-level dictionary
        var root: [String: Any] = [:]

        // ── Session metadata ────────────────────────────────────────────
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        root["session"] = [
            "id": session.id.uuidString,
            "name": session.name,
            "startTime": iso.string(from: session.startTime),
            "endTime": session.endTime.map { iso.string(from: $0) } as Any,
            "stickHeight_m": session.stickHeight,
            "geoidOffset_m": session.geoidOffset,
            "capturePointCount": session.points.count,
            "pathTrackPointCount": session.pathTrackPoints.count
        ]

        // ── All captured points (full raw data) ─────────────────────────
        root["capturePoints"] = session.points.map { pointDict($0, formatter: iso) }

        // ── All path-track breadcrumbs ──────────────────────────────────
        root["pathTrackPoints"] = session.pathTrackPoints.map { pointDict($0, formatter: iso) }

        // ── Grid metadata ───────────────────────────────────────────────
        let grid = terrain.grid
        root["grid"] = [
            "originLatitude": grid.originLatitude,
            "originLongitude": grid.originLongitude,
            "resolutionDegrees": grid.resolutionDegrees,
            "resolutionMeters": grid.resolutionMeters,
            "width": grid.width,
            "height": grid.height,
            "validCellCount": grid.validElevations.count,
            "totalCellCount": grid.width * grid.height
        ]

        // ── Processing stats ────────────────────────────────────────────
        let stats = terrain.stats
        root["processingStats"] = [
            "inputPointCount": stats.inputPointCount,
            "validPointCount": stats.validPointCount,
            "outlierCount": stats.outlierCount,
            "surveyedAreaM2": stats.surveyedAreaM2,
            "elevationMin_m": stats.elevationMin,
            "elevationMax_m": stats.elevationMax,
            "rmsAccuracyEstimate_m": stats.rmsAccuracyEstimate,
            "processingTimeSeconds": stats.processingTimeSeconds,
            "loopClosureApplied": stats.loopClosureApplied,
            "geoidCorrectionApplied": stats.geoidCorrectionApplied
        ]

        // ── Mesh summary ────────────────────────────────────────────────
        root["mesh"] = [
            "vertexCount": terrain.mesh.vertexCount,
            "triangleCount": terrain.mesh.triangleCount,
            "originLatitude": terrain.mesh.originLatitude,
            "originLongitude": terrain.mesh.originLongitude,
            "elevationMin_m": terrain.mesh.elevationMin,
            "elevationMax_m": terrain.mesh.elevationMax
        ]

        // ── Contour summary ─────────────────────────────────────────────
        root["contourCount"] = terrain.contours.count

        // ── Inter-point distances (for grid calibration analysis) ───────
        if session.points.count >= 2 {
            var distances: [[String: Any]] = []
            for i in 0..<session.points.count {
                for j in (i+1)..<session.points.count {
                    let a = session.points[i]
                    let b = session.points[j]
                    let (eA, nA) = latLonToEN(lat: a.latitude, lon: a.longitude,
                                               originLat: (a.latitude + b.latitude) / 2,
                                               originLon: (a.longitude + b.longitude) / 2)
                    let (eB, nB) = latLonToEN(lat: b.latitude, lon: b.longitude,
                                               originLat: (a.latitude + b.latitude) / 2,
                                               originLon: (a.longitude + b.longitude) / 2)
                    let hDist = sqrt((eA - eB) * (eA - eB) + (nA - nB) * (nA - nB))
                    let vDist = abs(a.groundElevation - b.groundElevation)
                    distances.append([
                        "pointA_index": i,
                        "pointB_index": j,
                        "horizontalDistance_m": round(hDist * 1000) / 1000,
                        "elevationDifference_m": round(vDist * 1000) / 1000,
                        "gpsAltitudeDiff_m": round(abs(a.gpsAltitude - b.gpsAltitude) * 1000) / 1000,
                        "fusedAltitudeDiff_m": round(abs(a.fusedAltitude - b.fusedAltitude) * 1000) / 1000,
                        "baroDeltaDiff_m": round(abs(a.baroAltitudeDelta - b.baroAltitudeDelta) * 1000) / 1000
                    ])
                }
            }
            root["interPointDistances"] = distances
        }

        let jsonData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return jsonData
    }

    // MARK: - Helpers

    private func pointDict(_ p: SurveyPoint, formatter: ISO8601DateFormatter) -> [String: Any] {
        return [
            "id": p.id.uuidString,
            "timestamp": formatter.string(from: p.timestamp),
            "latitude": p.latitude,
            "longitude": p.longitude,
            "fusedAltitude_m": round(p.fusedAltitude * 1_000_000) / 1_000_000,
            "groundElevation_m": round(p.groundElevation * 1_000_000) / 1_000_000,
            "lidarDistance_m": round(p.lidarDistance * 1_000_000) / 1_000_000,
            "gpsAltitude_m": round(p.gpsAltitude * 1_000_000) / 1_000_000,
            "baroAltitudeDelta_m": round(p.baroAltitudeDelta * 1_000_000) / 1_000_000,
            "tiltAngle_rad": round(p.tiltAngle * 1_000_000) / 1_000_000,
            "tiltAngle_deg": round(p.tiltAngle * 180.0 / .pi * 100) / 100,
            "horizontalAccuracy_m": round(p.horizontalAccuracy * 100) / 100,
            "verticalAccuracy_m": round(p.verticalAccuracy * 100) / 100,
            "isOutlier": p.isOutlier,
            "captureType": p.captureType.rawValue,
            "interpolationWeight": p.interpolationWeight
        ]
    }
}
