// KalmanFilter.swift
// TerrainMapper
//
// A 3-state discrete-time Kalman filter for fusing GPS altitude and
// barometric relative altitude into a single low-noise altitude estimate.
//
// ─── State vector x (3 × 1) ────────────────────────────────────────────────
//   x[0]  altitude          (metres, WGS-84 ellipsoid)
//   x[1]  vertical_velocity (m/s, positive = ascending)
//   x[2]  baro_bias         (metres) – slowly drifting offset between the
//                            barometer's relative reading and true altitude
//
// ─── Process model (predict step) ──────────────────────────────────────────
// The barometer gives a *delta* in relative altitude Δh_baro.  We use it as a
// known input (control input u = Δh_baro) rather than treating it purely as
// a measurement, which greatly reduces the filter's reliance on GPS.
//
//   x[0]  ← x[0] + x[1]·dt + Δh_baro          (altitude integrates velocity
//                                                plus the barometric increment)
//   x[1]  ← x[1]                                (velocity random walk)
//   x[2]  ← x[2]                                (bias random walk)
//
// State-transition matrix F:
//   ┌ 1  dt  0 ┐
//   │ 0   1  0 │
//   └ 0   0  1 ┘
//
// Control-input matrix B (maps scalar Δh_baro → state increment):
//   ┌ 1 ┐
//   │ 0 │
//   └ 0 ┘
//
// ─── Measurement models ────────────────────────────────────────────────────
// GPS altitude (absolute, high noise σ ≈ 5 m):
//   z_gps  = x[0]           →  H_gps  = [1, 0, 0]
//
// Barometer delta (relative, low noise σ ≈ 0.1 m):
//   z_baro = x[0] − x[2]    →  H_baro = [1, 0, −1]
//   (The baro reads x[0] corrupted by the estimated bias x[2])
//
// ─── Noise matrices ────────────────────────────────────────────────────────
// Process noise Q models how much we trust the process model each step.
// Measurement noise R is diagonal with per-sensor variances.

import Foundation

/// A 3×3 matrix stored as a flat row-major array of 9 Double values.
/// Index mapping: element (row, col) = data[row * 3 + col]
struct Matrix3x3 {
    var data: [Double]   // always 9 elements

    static let identity = Matrix3x3(data: [
        1, 0, 0,
        0, 1, 0,
        0, 0, 1
    ])

    static let zero = Matrix3x3(data: Array(repeating: 0.0, count: 9))

    subscript(row: Int, col: Int) -> Double {
        get { data[row * 3 + col] }
        set { data[row * 3 + col] = newValue }
    }

    // Matrix × Matrix
    static func * (lhs: Matrix3x3, rhs: Matrix3x3) -> Matrix3x3 {
        var result = Matrix3x3.zero
        for r in 0..<3 {
            for c in 0..<3 {
                var sum = 0.0
                for k in 0..<3 { sum += lhs[r, k] * rhs[k, c] }
                result[r, c] = sum
            }
        }
        return result
    }

    // Matrix + Matrix
    static func + (lhs: Matrix3x3, rhs: Matrix3x3) -> Matrix3x3 {
        Matrix3x3(data: zip(lhs.data, rhs.data).map(+))
    }

    // Matrix - Matrix
    static func - (lhs: Matrix3x3, rhs: Matrix3x3) -> Matrix3x3 {
        Matrix3x3(data: zip(lhs.data, rhs.data).map(-))
    }

    // Transpose
    var T: Matrix3x3 {
        var result = Matrix3x3.zero
        for r in 0..<3 {
            for c in 0..<3 { result[r, c] = self[c, r] }
        }
        return result
    }

    // Scalar multiply
    static func * (lhs: Matrix3x3, rhs: Double) -> Matrix3x3 {
        Matrix3x3(data: lhs.data.map { $0 * rhs })
    }

    // Matrix × column vector (3-element array)
    func multiply(vector v: [Double]) -> [Double] {
        (0..<3).map { r in (0..<3).reduce(0.0) { $0 + self[r, $1] * v[$1] } }
    }
}

// MARK: - KalmanFilter

/// Altitude-estimation Kalman filter.
///
/// Typical usage:
/// ```swift
/// var kf = KalmanFilter()
/// kf.predict(dt: 1.0, baroAltitudeDelta: delta)
/// kf.updateGPS(altitude: gpsAlt)
/// let altitude = kf.state[0]
/// ```
final class KalmanFilter {

    // MARK: - State

    /// State vector [altitude (m), vertical_velocity (m/s), baro_bias (m)]
    var state: [Double]

    /// 3×3 state covariance matrix P.
    /// High initial values express that we don't know the altitude yet.
    var covariance: Matrix3x3

    // MARK: - Noise parameters (tunable)

    /// Process noise variances [altitude, velocity, bias].
    /// These model how much each state component drifts per second.
    var processNoiseVariance: [Double]

    /// GPS altitude measurement noise variance (σ² in m²).  σ ≈ 5 m → σ² = 25.
    var gpsAltitudeNoiseVariance: Double

    /// Barometer delta measurement noise variance (σ² in m²).  σ ≈ 0.1 m → σ² = 0.01.
    var baroNoiseVariance: Double

    // MARK: - Init

    init(
        initialAltitude: Double = 0.0,
        processNoiseVariance: [Double] = [0.01, 0.1, 0.001],
        gpsAltitudeNoiseVariance: Double = 25.0,   // (5 m)²
        baroNoiseVariance: Double = 0.01            // (0.1 m)²
    ) {
        // Start with zero velocity and zero bias; large uncertainty on altitude
        self.state = [initialAltitude, 0.0, 0.0]

        // Large initial covariance → we'll trust the first GPS fix heavily
        self.covariance = Matrix3x3(data: [
            100, 0, 0,
              0, 1, 0,
              0, 0, 1
        ])

        self.processNoiseVariance       = processNoiseVariance
        self.gpsAltitudeNoiseVariance   = gpsAltitudeNoiseVariance
        self.baroNoiseVariance          = baroNoiseVariance
    }

    // MARK: - Predict

    /// Propagates the state and covariance forward by `dt` seconds.
    ///
    /// - Parameters:
    ///   - dt: Time elapsed since the last predict call (seconds).
    ///   - baroAltitudeDelta: Change in barometric relative altitude since the
    ///     last call (metres).  Used as a control input, not a measurement.
    func predict(dt: Double, baroAltitudeDelta: Double) {
        // State-transition matrix F
        var F = Matrix3x3.identity
        F[0, 1] = dt     // altitude += velocity * dt

        // Control input: barometer increment updates altitude directly.
        // B = [1, 0, 0]ᵀ  →  x ← F·x + B·Δh_baro
        var newState = F.multiply(vector: state)
        newState[0] += baroAltitudeDelta

        // Process noise Q — diagonal, scaled by dt so noise accumulates with time
        let qScale = dt
        let Q = Matrix3x3(data: [
            processNoiseVariance[0] * qScale, 0, 0,
            0, processNoiseVariance[1] * qScale, 0,
            0, 0, processNoiseVariance[2] * qScale
        ])

        // Covariance prediction: P ← F·P·Fᵀ + Q
        let newCov = F * covariance * F.T + Q

        state      = newState
        covariance = newCov
    }

    // MARK: - Update (GPS)

    /// Applies a GPS altitude measurement to the filter.
    ///
    /// Measurement model:  z = H·x + noise
    /// H_gps = [1, 0, 0]  (GPS measures altitude directly)
    ///
    /// - Parameter altitude: GPS altitude in metres (WGS-84 ellipsoidal).
    func updateGPS(altitude: Double) {
        // H = [1, 0, 0] — only the first state component is measured
        let H: [Double] = [1, 0, 0]
        update(measurement: altitude, H: H, measurementVariance: gpsAltitudeNoiseVariance)
    }

    // MARK: - Update (Barometer)

    /// Applies an *absolute* barometric altitude measurement.
    ///
    /// The barometer is anchored to an absolute altitude at session start
    /// (e.g., first GPS fix), so subsequent barometric readings express
    /// altitude = true_altitude − bias.
    ///
    /// Measurement model:  z = H·x + noise
    /// H_baro = [1, 0, −1]  →  z = x[0] − x[2]
    ///
    /// - Parameter altitudeDelta: Barometric altitude delta (metres) from
    ///   session start.  Pass `currentBaro − sessionStartBaro`.
    func updateBaro(altitudeDelta: Double) {
        // Reconstruct the absolute barometric reading anchored at session start.
        // The barometer measures x[0] with bias x[2], so z = x[0] − x[2].
        // H = [1, 0, −1]
        let H: [Double] = [1, 0, -1]
        update(measurement: altitudeDelta, H: H, measurementVariance: baroNoiseVariance)
    }

    // MARK: - Generic scalar update

    /// Kalman update for a scalar measurement z = H·x + noise.
    ///
    /// Standard equations:
    ///   Innovation:  y  = z − H·x̂
    ///   Innovation covariance:  S = H·P·Hᵀ + R
    ///   Kalman gain: K = P·Hᵀ / S
    ///   Updated state:       x̂ ← x̂ + K·y
    ///   Updated covariance:  P  ← (I − K·H)·P
    private func update(measurement z: Double, H: [Double], measurementVariance R: Double) {
        // H·x̂ — predicted measurement
        let hx = zip(H, state).map(*).reduce(0, +)

        // Innovation y = z − H·x̂
        let y = z - hx

        // P·Hᵀ — 3-element column vector
        var PHt = [Double](repeating: 0, count: 3)
        for r in 0..<3 {
            for c in 0..<3 { PHt[r] += covariance[r, c] * H[c] }
        }

        // Innovation variance S = H·P·Hᵀ + R
        let S = zip(H, PHt).map(*).reduce(0, +) + R
        guard S > 0 else { return }

        // Kalman gain K = P·Hᵀ / S  (3-element vector)
        let K = PHt.map { $0 / S }

        // State update: x̂ ← x̂ + K·y
        state = zip(state, K).map { $0 + $1 * y }

        // Covariance update: P ← (I − K·H)·P
        // Compute K·H as an outer product → 3×3 matrix
        var KH = Matrix3x3.zero
        for r in 0..<3 {
            for c in 0..<3 { KH[r, c] = K[r] * H[c] }
        }
        let IminusKH = Matrix3x3.identity - KH
        covariance = IminusKH * covariance

        // Joseph form (numerically stabilised):
        //   P ← (I−KH)·P·(I−KH)ᵀ + K·R·Kᵀ
        // Uncomment if numerical drift becomes an issue at long session lengths.
    }
}
