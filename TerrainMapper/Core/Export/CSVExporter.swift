import Foundation

final class CSVExporter {

    func export(terrain: ProcessedTerrain) throws -> Data {
        let allPoints = terrain.validPoints + terrain.outlierPoints

        guard !allPoints.isEmpty else {
            throw ExportError.invalidTerrain
        }

        var csvString = ""

        csvString += "id,timestamp,latitude,longitude,fusedAltitude,groundElevation,lidarDistance,gpsAltitude,baroAltitudeDelta,tiltAngleDeg,horizontalAccuracy,verticalAccuracy,isOutlier\n"

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for point in allPoints {
            let timestamp = isoFormatter.string(from: point.timestamp)
            let tiltDegrees = point.tiltAngle * 180 / Double.pi

            let row = "\(point.id.uuidString),\(timestamp),\(formatCoordinate(point.latitude)),\(formatCoordinate(point.longitude)),\(formatElevation(point.fusedAltitude)),\(formatElevation(point.groundElevation)),\(formatElevation(point.lidarDistance)),\(formatElevation(point.gpsAltitude)),\(formatElevation(point.baroAltitudeDelta)),\(formatElevation(tiltDegrees)),\(formatAccuracy(point.horizontalAccuracy)),\(formatAccuracy(point.verticalAccuracy)),\(point.isOutlier ? "true" : "false")\n"

            csvString += row
        }

        guard let data = csvString.data(using: .utf8) else {
            throw ExportError.invalidTerrain
        }

        return data
    }

    private func formatCoordinate(_ value: Double) -> String {
        String(format: "%.8f", value)
    }

    private func formatElevation(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private func formatAccuracy(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
