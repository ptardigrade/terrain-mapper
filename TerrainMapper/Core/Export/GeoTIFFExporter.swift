import Foundation

final class GeoTIFFExporter {

    func export(terrain: ProcessedTerrain) throws -> Data {
        let grid = terrain.grid

        guard grid.width > 0 && grid.height > 0 else {
            throw ExportError.invalidTerrain
        }

        var data = Data()

        data.append(0x49)
        data.append(0x49)
        data.appendLE(UInt16(42))

        let ifdOffset: UInt32 = 8
        data.appendLE(ifdOffset)

        let pixelDataOffset = ifdOffset + UInt32(calculateIFDSize(tagCount: 14))

        writeIFD(
            to: &data,
            width: UInt32(grid.width),
            height: UInt32(grid.height),
            pixelDataOffset: pixelDataOffset,
            grid: grid
        )

        writePixelData(to: &data, grid: grid)

        return data
    }

    private func calculateIFDSize(tagCount: Int) -> UInt32 {
        return UInt32(2 + (tagCount * 12) + 4)
    }

    private func writeIFD(
        to data: inout Data,
        width: UInt32,
        height: UInt32,
        pixelDataOffset: UInt32,
        grid: TerrainGrid
    ) {
        let pixelDataSize = width * height * 4

        var tags: [(tag: UInt16, type: UInt16, count: UInt32, value: UInt32)] = []

        tags.append((256, 3, 1, UInt32(width)))
        tags.append((257, 3, 1, UInt32(height)))
        tags.append((258, 3, 1, 32))
        tags.append((259, 3, 1, 1))
        tags.append((262, 3, 1, 1))
        tags.append((273, 4, 1, pixelDataOffset))
        tags.append((278, 3, 1, UInt32(height)))
        tags.append((279, 4, 1, pixelDataSize))
        tags.append((284, 3, 1, 1))
        tags.append((339, 3, 1, 3))

        let geoTagOffset = pixelDataOffset + pixelDataSize
        let pixelScaleOffset = geoTagOffset + 36
        let tiepointOffset = pixelScaleOffset + 24
        let geoKeyOffset = tiepointOffset + 48

        tags.append((33550, 12, 3, pixelScaleOffset))
        tags.append((33922, 12, 6, tiepointOffset))
        tags.append((34735, 3, 16, geoKeyOffset))

        tags.sort { $0.tag < $1.tag }

        data.appendLE(UInt16(tags.count))

        for tag in tags {
            data.appendLE(tag.tag)
            data.appendLE(tag.type)
            data.appendLE(tag.count)
            data.appendLE(tag.value)
        }

        data.appendLE(UInt32(0))

        let lonPerPixel = grid.resolutionDegrees
        let latPerPixel = grid.resolutionDegrees

        data.appendFloat64LE(lonPerPixel)
        data.appendFloat64LE(latPerPixel)
        data.appendFloat64LE(0.0)

        data.appendFloat64LE(Double(grid.originLongitude))
        data.appendFloat64LE(Double(grid.originLatitude) + Double(grid.height) * grid.resolutionDegrees)
        data.appendFloat64LE(0.0)

        data.appendFloat64LE(0.0)
        data.appendFloat64LE(0.0)
        data.appendFloat64LE(0.0)
        data.appendFloat64LE(Double(grid.originLongitude))
        data.appendFloat64LE(Double(grid.originLatitude) + Double(grid.height) * grid.resolutionDegrees)
        data.appendFloat64LE(0.0)

        let geoKeys: [UInt16] = [
            1, 1, 0, 4,
            1024, 0, 1, 2,
            1025, 0, 1, 1,
            2048, 0, 1, 4326,
            2054, 0, 1, 9102
        ]

        for key in geoKeys {
            data.appendLE(key)
        }
    }

    private func writePixelData(to data: inout Data, grid: TerrainGrid) {
        let noData = Float(-9999)

        for row in 0..<grid.height {
            for col in 0..<grid.width {
                let elevation = grid.elevation(row: row, col: col) ?? Double(-9999)
                let value = Float(elevation)
                data.appendFloat32LE(value)
            }
        }
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
