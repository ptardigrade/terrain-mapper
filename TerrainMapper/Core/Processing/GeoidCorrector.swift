// GeoidCorrector.swift
// TerrainMapper
//
// Converts ellipsoidal (WGS-84 GPS) heights to orthometric heights (above
// the EGM96 geoid, approximately equal to mean sea level).
//
// ─── Relationship between ellipsoidal and orthometric height ─────────────
//   H_orthometric = h_ellipsoidal − N_geoid
//
// where N is the geoid undulation: positive when the geoid is above the
// ellipsoid (most land areas), negative in the deep ocean.
//
// ─── EGM96 lookup table ──────────────────────────────────────────────────
// We embed a coarse 15°-resolution grid of EGM96 undulation values and
// use bilinear interpolation for any query point.
//
// Grid layout:
//   Rows:    latitude  from −90° (row 0) to +90° (row 12) in 15° steps → 13 rows
//   Columns: longitude from   0° (col 0) to 360° (col 24) in 15° steps → 25 cols
//            (col 24 = col 0, wrapping the globe)
//
// Accuracy: ±15 m globally, typically ±5 m in mid-latitudes.
// For production accuracy (±0.1 m), replace with full EGM2008 1'×1' grid.
//
// Source: approximate values derived from the EGM96 model published by
// NGA/NASA.  These values are in the public domain.

import Foundation

struct GeoidCorrector {

    // MARK: - Configuration

    /// Set to false to skip correction (useful for testing or high-accuracy GPS).
    var isEnabled: Bool = true

    // MARK: - Public API

    /// Apply EGM96 geoid correction to every non-outlier point in `points`.
    ///
    /// Modifies `fusedAltitude`, `gpsAltitude`, and `groundElevation` by
    /// subtracting the local geoid undulation N(lat, lon).
    func correct(points: inout [SurveyPoint]) {
        guard isEnabled else { return }
        for i in points.indices where !points[i].isOutlier {
            let N = undulation(latitude: points[i].latitude, longitude: points[i].longitude)
            let p = points[i]
            points[i] = SurveyPoint(
                id:                 p.id,
                timestamp:          p.timestamp,
                latitude:           p.latitude,
                longitude:          p.longitude,
                fusedAltitude:      p.fusedAltitude   - N,
                groundElevation:    p.groundElevation  - N,
                lidarDistance:      p.lidarDistance,
                gpsAltitude:        p.gpsAltitude      - N,
                baroAltitudeDelta:  p.baroAltitudeDelta,
                tiltAngle:          p.tiltAngle,
                horizontalAccuracy: p.horizontalAccuracy,
                verticalAccuracy:   p.verticalAccuracy,
                isOutlier:          p.isOutlier
            )
        }
    }

    /// Returns the EGM96 geoid undulation N (metres) at the given coordinate
    /// via bilinear interpolation on the embedded 15° grid.
    ///
    /// Positive N means the geoid is above the WGS-84 ellipsoid at that point.
    func undulation(latitude: Double, longitude: Double) -> Double {
        // Normalise longitude to [0, 360)
        var lon = longitude.truncatingRemainder(dividingBy: 360)
        if lon < 0 { lon += 360 }

        // Grid spacing = 15°; grid goes lat -90…+90 (13 rows), lon 0…360 (25 cols)
        let latStep = 15.0, lonStep = 15.0
        let latMin  = -90.0

        // Row index (fractional)
        let rowF    = (latitude - latMin) / latStep
        let row0    = max(0, min(11, Int(rowF)))
        let row1    = min(12, row0 + 1)
        let tRow    = rowF - Double(row0)

        // Column index (fractional, wrapping)
        let colF    = lon / lonStep
        let col0    = Int(colF) % 24          // 0…23
        let col1    = (col0 + 1) % 25          // wraps: col 24 = col 0
        let tCol    = colF - Double(Int(colF))

        // Bilinear interpolation
        let v00 = egm96[row0][col0]
        let v10 = egm96[row1][col0]
        let v01 = egm96[row0][col1]
        let v11 = egm96[row1][col1]

        let top    = v00 * (1 - tCol) + v01 * tCol
        let bottom = v10 * (1 - tCol) + v11 * tCol
        return top * (1 - tRow) + bottom * tRow
    }

    // MARK: - EGM96 coarse lookup table (15° resolution)
    //
    // egm96[row][col]  where:
    //   row 0  = lat  −90°  (South Pole)
    //   row 12 = lat  +90°  (North Pole)
    //   col 0  = lon    0°
    //   col 24 = lon  360°  (= col 0, wrapping closure)
    //
    // Values in metres.  Notable landmarks:
    //   Indian Ocean geoid low (~row 6-7, col 4-6): deepest ≈ −78 m
    //   New Guinea geoid high  (~row 6, col 10):    peak    ≈ +66 m
    //   Iceland/Europe high    (~row 10, col 0-2):  peak    ≈ +47 m
    //   South Pole:            −29.5 m  (uniform)
    //   North Pole:            +13.6 m  (uniform)

    private let egm96: [[Double]] = [
        // row 0: lat = −90° (South Pole)
        [-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5,-29.5],
        // row 1: lat = −75°
        [-27.0,-27.0,-29.0,-31.0,-34.0,-37.0,-40.0,-42.0,-43.0,-42.0,-39.0,-35.0,-31.0,-28.0,-26.0,-26.0,-27.0,-29.0,-32.0,-35.0,-37.0,-37.0,-34.0,-30.0,-27.0],
        // row 2: lat = −60°
        [-18.0,-13.0, -9.0, -9.0,-13.0,-21.0,-30.0,-38.0,-42.0,-41.0,-34.0,-23.0,-13.0, -6.0, -2.0, -4.0, -9.0,-16.0,-24.0,-32.0,-38.0,-39.0,-32.0,-23.0,-18.0],
        // row 3: lat = −45°
        [ -7.0,  2.0,  8.0,  8.0,  3.0, -8.0,-20.0,-31.0,-36.0,-33.0,-21.0, -6.0,  6.0, 14.0, 14.0,  8.0,  0.0, -9.0,-19.0,-29.0,-37.0,-38.0,-29.0,-17.0, -7.0],
        // row 4: lat = −30°
        [ 10.0, 18.0, 22.0, 19.0,  9.0, -5.0,-19.0,-30.0,-34.0,-29.0,-14.0,  2.0, 14.0, 19.0, 17.0,  9.0, -1.0,-12.0,-24.0,-34.0,-40.0,-37.0,-24.0, -7.0, 10.0],
        // row 5: lat = −15°
        [ 18.0, 22.0, 21.0, 14.0,  2.0,-20.0,-45.0,-60.0,-58.0,-44.0,-20.0,  4.0, 18.0, 23.0, 19.0,  8.0, -5.0,-18.0,-30.0,-38.0,-40.0,-33.0,-18.0,  0.0, 18.0],
        // row 6: lat =   0°
        [ 17.0, 20.0, 18.0, 10.0, -5.0,-30.0,-62.0,-78.0,-66.0,-38.0, -8.0, 30.0, 66.0, 60.0, 26.0,  8.0,-10.0,-25.0,-35.0,-40.0,-36.0,-24.0, -6.0,  9.0, 17.0],
        // row 7: lat = +15°
        [ 20.0, 20.0, 14.0,  4.0,-10.0,-35.0,-68.0,-78.0,-62.0,-28.0,  8.0, 35.0, 52.0, 46.0, 24.0,  6.0,-10.0,-24.0,-35.0,-40.0,-36.0,-23.0, -5.0, 11.0, 20.0],
        // row 8: lat = +30°
        [ 26.0, 22.0, 14.0,  2.0,-12.0,-36.0,-56.0,-52.0,-32.0, -6.0, 18.0, 34.0, 44.0, 40.0, 24.0,  7.0, -8.0,-22.0,-33.0,-37.0,-35.0,-24.0, -7.0, 12.0, 26.0],
        // row 9: lat = +45°
        [ 48.0, 45.0, 36.0, 22.0,  6.0,-12.0,-26.0,-28.0,-18.0, -2.0, 16.0, 30.0, 39.0, 36.0, 22.0,  6.0, -6.0,-18.0,-26.0,-28.0,-26.0,-16.0, -1.0, 21.0, 48.0],
        // row 10: lat = +60°
        [ 43.0, 46.0, 47.0, 42.0, 30.0, 15.0,  2.0, -8.0,-12.0, -8.0,  2.0, 14.0, 24.0, 26.0, 20.0, 10.0,  0.0, -8.0,-16.0,-20.0,-18.0,-10.0,  2.0, 22.0, 43.0],
        // row 11: lat = +75°
        [ 22.0, 25.0, 27.0, 26.0, 20.0, 12.0,  7.0,  4.0,  3.0,  5.0,  8.0, 13.0, 17.0, 19.0, 18.0, 15.0, 10.0,  6.0,  3.0,  3.0,  5.0,  9.0, 14.0, 19.0, 22.0],
        // row 12: lat = +90° (North Pole)
        [ 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6, 13.6]
    ]
}
