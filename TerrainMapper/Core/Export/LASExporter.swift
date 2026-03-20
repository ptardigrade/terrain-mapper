import Foundation

final class LASExporter {

    func export(terrain: ProcessedTerrain) throws -> Data {
        let validPoints = terrain.validPoints
        let outlierPoints = terrain.outlierPoints
        let allPoints = validPoints + outlierPoints

        guard !allPoints.isEmpty else {
            throw ExportError.invalidTerrain
        }

        var data = Data()

        let (minX, maxX, minY, maxY, minZ, maxZ) = computeBounds(points: allPoints)

        let xScale = 0.001
        let yScale = 0.001
        let zScale = 0.001

        let xOffset = minX
        let yOffset = minY
        let zOffset = minZ

        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: now) ?? 1
        let year = UInt16(components.year ?? 2026)

        writeHeader(
            to: &data,
            pointCount: UInt32(min(UInt32.max, allPoints.count)),
            pointCountExtended: UInt64(allPoints.count),
            dayOfYear: UInt16(dayOfYear),
            year: year,
            xScale: xScale, yScale: yScale, zScale: zScale,
            xOffset: xOffset, yOffset: yOffset, zOffset: zOffset,
            minX: minX, maxX: maxX,
            minY: minY, maxY: maxY,
            minZ: minZ, maxZ: maxZ
        )

        for (index, point) in allPoints.enumerated() {
            writePointRecord(
                to: &data,
                point: point,
                xScale: xScale, yScale: yScale, zScale: zScale,
                xOffset: xOffset, yOffset: yOffset, zOffset: zOffset,
                index: index
            )
        }

        return data
    }

    private func computeBounds(points: [SurveyPoint]) -> (minX: Double, maxX: Double, minY: Double, maxY: Double, minZ: Double, maxZ: Double) {
        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity
        var minZ = Double.infinity
        var maxZ = -Double.infinity

        for point in points {
            let x = point.longitude
            let y = point.latitude
            let z = point.groundElevation

            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
            minZ = min(minZ, z)
            maxZ = max(maxZ, z)
        }

        return (minX, maxX, minY, maxY, minZ, maxZ)
    }

    private func writeHeader(
        to data: inout Data,
        pointCount: UInt32,
        pointCountExtended: UInt64,
        dayOfYear: UInt16,
        year: UInt16,
        xScale: Double, yScale: Double, zScale: Double,
        xOffset: Double, yOffset: Double, zOffset: Double,
        minX: Double, maxX: Double,
        minY: Double, maxY: Double,
        minZ: Double, maxZ: Double
    ) {
        data.append(contentsOf: [UInt8(ascii: "L"), UInt8(ascii: "A"), UInt8(ascii: "S"), UInt8(ascii: "F")])

        data.appendLE(UInt16(0))
        data.appendLE(UInt16(1))

        for _ in 0..<16 {
            data.append(0)
        }

        data.append(1)
        data.append(4)

        let systemID = "TerrainMapper".padded(toLength: 32)
        data.append(contentsOf: systemID.utf8)

        let software = "TerrainMapper iOS".padded(toLength: 32)
        data.append(contentsOf: software.utf8)

        data.appendLE(dayOfYear)
        data.appendLE(year)

        data.appendLE(UInt16(375))
        data.appendLE(UInt32(375))

        data.appendLE(UInt32(0))
        data.append(0)

        data.appendLE(UInt16(20))

        data.appendLE(pointCount)

        // Legacy return counts (5 entries): index 0 = all points (single return),
        // indices 1–4 = zero (no multi-return data from a handheld survey device).
        data.appendLE(pointCount)   // return count 1
        for _ in 0..<4 {
            data.appendLE(UInt32(0))   // return counts 2–5
        }

        data.appendFloat64LE(xScale)
        data.appendFloat64LE(yScale)
        data.appendFloat64LE(zScale)

        data.appendFloat64LE(xOffset)
        data.appendFloat64LE(yOffset)
        data.appendFloat64LE(zOffset)

        // LAS 1.4 spec order: Max X, Min X, Max Y, Min Y, Max Z, Min Z
        data.appendFloat64LE(maxX)
        data.appendFloat64LE(minX)
        data.appendFloat64LE(maxY)
        data.appendFloat64LE(minY)
        data.appendFloat64LE(maxZ)
        data.appendFloat64LE(minZ)

        data.appendLE(UInt64(0))
        data.appendLE(UInt64(0))

        data.appendLE(UInt32(0))
        data.appendLE(pointCountExtended)

        // Extended return counts (15 entries): index 0 = all points (single return),
        // indices 1–14 = zero (no multi-return data from a handheld survey device).
        data.appendLE(pointCountExtended)   // return count 1
        for _ in 0..<14 {
            data.appendLE(UInt64(0))   // return counts 2–15
        }
    }

    private func writePointRecord(
        to data: inout Data,
        point: SurveyPoint,
        xScale: Double, yScale: Double, zScale: Double,
        xOffset: Double, yOffset: Double, zOffset: Double,
        index: Int
    ) {
        let xScaled = Int32((point.longitude - xOffset) / xScale)
        let yScaled = Int32((point.latitude - yOffset) / yScale)
        let zScaled = Int32((point.groundElevation - zOffset) / zScale)

        data.appendLE(xScaled)
        data.appendLE(yScaled)
        data.appendLE(zScaled)

        let intensity = UInt16(min(65535, max(0, Int(point.horizontalAccuracy * 100))))
        data.appendLE(intensity)

        data.append(0x01)
        data.append(2)

        let tiltDegrees = Int8(max(-90, min(90, Int(point.tiltAngle * 180 / Double.pi))))
        data.append(UInt8(bitPattern: tiltDegrees))

        data.append(0)

        let sourceID = UInt16(index % 65536)
        data.appendLE(sourceID)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var mutableValue = value.littleEndian
        withUnsafeBytes(of: &mutableValue) { buffer in
            self.append(contentsOf: buffer)
        }
    }

    mutating func appendFloat32LE(_ value: Float) {
        var mutableValue = value.bitPattern.littleEndian
        withUnsafeBytes(of: &mutableValue) { buffer in
            self.append(contentsOf: buffer)
        }
    }

    mutating func appendFloat64LE(_ value: Double) {
        var mutableValue = value.bitPattern.littleEndian
        withUnsafeBytes(of: &mutableValue) { buffer in
            self.append(contentsOf: buffer)
        }
    }
}

private extension String {
    func padded(toLength length: Int) -> String {
        if self.count >= length {
            return String(self.prefix(length))
        }
        return self + String(repeating: "\0", count: length - self.count)
    }
}
