import Foundation

final class GeoTIFFExporter {

    func export(terrain: ProcessedTerrain) throws -> Data {
        let grid = terrain.grid

        guard grid.width > 0 && grid.height > 0 else {
            throw ExportError.invalidTerrain
        }

        // ── Fixed byte-layout map ───────────────────────────────────────────
        //
        //  Offset   Size   Content
        //  ──────   ────   ───────────────────────────────────────────────────
        //       0      8   TIFF header  (II, 42, ifdOffset=8)
        //       8    162   IFD          (2-byte count + 13×12-byte entries + 4-byte next=0)
        //     170     24   ModelPixelScaleTag data  (3 × float64)
        //     194     48   ModelTiepointTag data     (6 × float64)
        //     242     40   GeoKeyDirectoryTag data   (20 × uint16)
        //     282  w×h×4   Pixel data               (float32 per cell, N→S row order)
        //
        let ifdOffset:        UInt32 = 8
        let pixelScaleOffset: UInt32 = 170
        let tiepointOffset:   UInt32 = 194
        let geoKeyOffset:     UInt32 = 242
        let pixelDataOffset:  UInt32 = 282
        let pixelDataSize:    UInt32 = UInt32(grid.width) * UInt32(grid.height) * 4

        var data = Data()
        data.reserveCapacity(Int(pixelDataOffset) + Int(pixelDataSize))

        // ── TIFF header ────────────────────────────────────────────────────
        data.append(0x49)               // 'I' — little-endian byte order
        data.append(0x49)
        data.appendLE(UInt16(42))       // TIFF magic number
        data.appendLE(ifdOffset)        // offset of first (and only) IFD

        // ── IFD (13 entries, sorted ascending by tag number) ───────────────
        // Each entry: tag(2) type(2) count(4) value_or_offset(4) = 12 bytes
        //   type 3  = SHORT  (2 bytes)
        //   type 4  = LONG   (4 bytes)
        //   type 12 = DOUBLE (8 bytes)
        //
        // For SHORT/LONG with count=1 the value fits in the 4-byte field
        // directly (LE-padded to 4 bytes).  For DOUBLE and multi-value fields
        // the 4-byte field holds the file offset to the data written below.
        let width  = UInt32(grid.width)
        let height = UInt32(grid.height)

        let ifdEntries: [(tag: UInt16, type: UInt16, count: UInt32, value: UInt32)] = [
            (256,   3,  1, width),              // ImageWidth
            (257,   3,  1, height),             // ImageLength
            (258,   3,  1, 32),                 // BitsPerSample = 32
            (259,   3,  1, 1),                  // Compression = None
            (262,   3,  1, 1),                  // PhotometricInterpretation = BlackIsZero
            (273,   4,  1, pixelDataOffset),    // StripOffsets
            (278,   4,  1, height),             // RowsPerStrip (single strip)
            (279,   4,  1, pixelDataSize),      // StripByteCounts
            (284,   3,  1, 1),                  // PlanarConfiguration = Chunky
            (339,   3,  1, 3),                  // SampleFormat = IEEE float
            (33550, 12, 3, pixelScaleOffset),   // ModelPixelScaleTag → offset 170
            (33922, 12, 6, tiepointOffset),     // ModelTiepointTag   → offset 194
            (34735, 3, 20, geoKeyOffset),       // GeoKeyDirectoryTag → offset 242
        ]

        data.appendLE(UInt16(ifdEntries.count))     // number of directory entries
        for e in ifdEntries {
            data.appendLE(e.tag)
            data.appendLE(e.type)
            data.appendLE(e.count)
            data.appendLE(e.value)
        }
        data.appendLE(UInt32(0))   // next IFD offset = 0 (end of IFD chain)

        // ── ModelPixelScaleTag data (at offset 170) ───────────────────────
        // [ScaleX, ScaleY, ScaleZ] — degrees per pixel, Z unused.
        data.appendFloat64LE(grid.resolutionDegrees)    // X: longitude per pixel
        data.appendFloat64LE(grid.resolutionDegrees)    // Y: latitude per pixel (magnitude)
        data.appendFloat64LE(0.0)                       // Z

        // ── ModelTiepointTag data (at offset 194) ─────────────────────────
        // Format: [I, J, K, X, Y, Z]
        //   (I, J, K) = raster pixel coordinate of the tie point = (0, 0, 0)
        //   (X, Y, Z) = geographic coordinate = (originLon, northEdgeLat, 0)
        //
        // Pixel data is written N→S, so raster row 0 = north edge of the grid.
        // Readers compute:  lat = northEdgeLat − row × resolutionDegrees
        let northEdgeLat = grid.originLatitude + Double(grid.height) * grid.resolutionDegrees
        data.appendFloat64LE(0.0)                       // I
        data.appendFloat64LE(0.0)                       // J
        data.appendFloat64LE(0.0)                       // K
        data.appendFloat64LE(grid.originLongitude)      // X
        data.appendFloat64LE(northEdgeLat)              // Y
        data.appendFloat64LE(0.0)                       // Z

        // ── GeoKeyDirectoryTag data (at offset 242) ───────────────────────
        // Header:  [KeyDirectoryVersion=1, KeyRevision=1, MinorRevision=0, NumberOfKeys=4]
        // 4 keys × 4 UInt16 = 16 UInt16s + 4-UInt16 header = 20 UInt16s total (40 bytes).
        let geoKeys: [UInt16] = [
            1, 1, 0, 4,         // GeoKey directory header (version 1.1, 4 keys)
            1024, 0, 1, 2,      // GTModelTypeGeoKey       = ModelTypeGeographic
            1025, 0, 1, 1,      // GTRasterTypeGeoKey      = RasterPixelIsArea
            2048, 0, 1, 4326,   // GeographicTypeGeoKey    = GCS_WGS_84
            2054, 0, 1, 9102,   // GeogAngularUnitsGeoKey  = Angular_Degree
        ]
        for key in geoKeys { data.appendLE(key) }

        // ── Pixel data (at offset 282) ────────────────────────────────────
        // Written north-to-south so that raster row 0 aligns with the tiepoint
        // at the north edge (standard GeoTIFF convention, compatible with GDAL).
        // No-data value = -9999 for cells with nil elevation.
        for row in stride(from: grid.height - 1, through: 0, by: -1) {
            for col in 0..<grid.width {
                let elevation = grid.elevation(row: row, col: col) ?? -9999.0
                data.appendFloat32LE(Float(elevation))
            }
        }

        return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }

    mutating func appendFloat32LE(_ value: Float) {
        var v = value.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }

    mutating func appendFloat64LE(_ value: Double) {
        var v = value.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }
}
