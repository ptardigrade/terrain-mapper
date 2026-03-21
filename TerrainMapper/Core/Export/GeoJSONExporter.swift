import Foundation

final class GeoJSONExporter {

    func export(terrain: ProcessedTerrain) throws -> Data {
        var json = ""

        json += "{\n"
        json += "  \"type\": \"FeatureCollection\",\n"
        json += "  \"features\": [\n"

        var features: [String] = []

        let allPoints = terrain.validPoints + terrain.outlierPoints

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for point in allPoints {
            let timestamp = isoFormatter.string(from: point.timestamp)

            let tiltDegrees = point.tiltAngle * 180 / Double.pi

            let feature = """
            {
              "type": "Feature",
              "geometry": {
                "type": "Point",
                "coordinates": [\(formatCoordinate(point.longitude, decimals: 8)), \(formatCoordinate(point.latitude, decimals: 8)), \(formatElevation(point.groundElevation))]
              },
              "properties": {
                "id": "\(point.id.uuidString)",
                "timestamp": "\(timestamp)",
                "groundElevation": \(formatElevation(point.groundElevation)),
                "lidarDistance": \(formatElevation(point.lidarDistance)),
                "fusedAltitude": \(formatElevation(point.fusedAltitude)),
                "gpsAltitude": \(formatElevation(point.gpsAltitude)),
                "baroAltitudeDelta": \(formatElevation(point.baroAltitudeDelta)),
                "tiltAngleDeg": \(formatElevation(tiltDegrees)),
                "horizontalAccuracy": \(formatAccuracy(point.horizontalAccuracy)),
                "verticalAccuracy": \(formatAccuracy(point.verticalAccuracy)),
                "isOutlier": \(point.isOutlier ? "true" : "false")
              }
            }
            """
            features.append(feature)
        }

        for contour in terrain.contours {
            let coords = contour.coordinates
                .map { "[\(formatCoordinate($0.longitude, decimals: 8)), \(formatCoordinate($0.latitude, decimals: 8)), \(formatElevation(contour.elevation))]" }
                .joined(separator: ", ")

            let feature = """
            {
              "type": "Feature",
              "geometry": {
                "type": "LineString",
                "coordinates": [\(coords)]
              },
              "properties": {
                "elevation": \(formatElevation(contour.elevation)),
                "isClosed": \(contour.isClosed ? "true" : "false")
              }
            }
            """
            features.append(feature)
        }

        json += features.joined(separator: ",\n    ")
        json += "\n  ]\n"
        json += "}\n"

        guard let data = json.data(using: .utf8) else {
            throw ExportError.invalidTerrain
        }

        return data
    }

    private func formatCoordinate(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }

    private func formatElevation(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private func formatAccuracy(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
