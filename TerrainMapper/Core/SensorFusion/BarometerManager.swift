// BarometerManager.swift
// TerrainMapper
//
// Wraps CMAltimeter to publish relative altitude changes via Combine and
// handle barometric drift correction via loop-closure.
//
// ─── Barometric drift model ──────────────────────────────────────────────
// CMAltimeter reports *relative* altitude (Δh) from the moment startRelativeAltitudeUpdates
// is called.  It uses the onboard pressure sensor; the reading drifts slowly
// (~1–2 m/hour) due to weather-induced pressure changes.
//
// ─── Loop-closure drift correction ───────────────────────────────────────
// If the operator walks back to within `kLoopClosureRadiusM` metres of the
// session start point (detected by GPSManager), we know the true altitude
// change is zero (or matches the starting GPS alt).  Any residual barometric
// delta at that moment is pure drift.  We distribute that drift linearly
// across all previously recorded points:
//
//   corrected_delta[i] = raw_delta[i] − drift × (i / N)
//
// This is equivalent to a first-order linear drift model.

import CoreMotion
import Combine
import Foundation

@MainActor
final class BarometerManager: ObservableObject {

    // MARK: - Public

    /// Publishes the current CMAltimeter relative altitude delta (metres from
    /// session start).  Delivers on the main thread.
    var relativeAltitudePublisher: AnyPublisher<Double, Never> {
        relativeAltitudeSubject.eraseToAnyPublisher()
    }

    /// Latest relative altitude (metres from session start).
    @Published private(set) var currentRelativeAltitude: Double = 0.0

    // MARK: - Private

    private let altimeter = CMAltimeter()
    private let relativeAltitudeSubject = PassthroughSubject<Double, Never>()

    /// Rolling circular buffer of recent baro readings for drift detection.
    private var recentReadings: [Double] = []
    private let kBaselineWindowSize = 60   // samples

    /// Baseline pressure altitude captured at session start (absolute, hPa).
    private var sessionStartPressure: Double? = nil

    /// Loop-closure detection threshold (metres horizontal distance).
    private let kLoopClosureRadiusM = 10.0

    // MARK: - Lifecycle

    /// Start receiving barometer updates.  The first reading seeds the baseline.
    func start() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            print("[BarometerManager] Relative altitude unavailable on this device.")
            return
        }
        currentRelativeAltitude = 0.0
        recentReadings.removeAll()

        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self, let data, error == nil else { return }
            self.handleAltimeterData(data)
        }
    }

    func stop() {
        altimeter.stopRelativeAltitudeUpdates()
        recentReadings.removeAll()
    }

    // MARK: - Data handling

    private func handleAltimeterData(_ data: CMAltitudeData) {
        let delta = data.relativeAltitude.doubleValue   // metres from start

        currentRelativeAltitude = delta
        relativeAltitudeSubject.send(delta)

        // Maintain rolling baseline window
        recentReadings.append(delta)
        if recentReadings.count > kBaselineWindowSize {
            recentReadings.removeFirst()
        }
    }

    // MARK: - Drift detection

    /// Returns the estimated drift rate (m/sample) based on the current
    /// rolling window.  A perfectly stable barometer returns 0.
    ///
    /// We fit a linear trend to the recent readings using least-squares:
    ///   slope = (n·Σxy − Σx·Σy) / (n·Σx² − (Σx)²)
    var estimatedDriftRatePerSample: Double {
        let n = Double(recentReadings.count)
        guard n > 2 else { return 0 }

        var sumX  = 0.0, sumY = 0.0
        var sumXY = 0.0, sumX2 = 0.0

        for (i, y) in recentReadings.enumerated() {
            let x = Double(i)
            sumX  += x
            sumY  += y
            sumXY += x * y
            sumX2 += x * x
        }

        let denom = n * sumX2 - sumX * sumX
        guard abs(denom) > 1e-9 else { return 0 }
        return (n * sumXY - sumX * sumY) / denom
    }

    // MARK: - Loop-closure correction

    /// Applies a linear drift correction to the `baroAltitudeDelta` field of
    /// every SurveyPoint in the provided array.
    ///
    /// Call this when loop closure is detected (operator returned to start).
    ///
    /// - Parameters:
    ///   - points: The survey points to correct (mutated in place).
    ///   - observedDrift: The total measured drift in metres at loop closure
    ///     (= current baro reading when the operator is back at start, since
    ///      the true delta should be 0 at the closed loop).
    func applyLoopClosure(points: inout [SurveyPoint], observedDrift: Double) {
        guard !points.isEmpty else { return }
        let count = Double(points.count)

        for i in points.indices {
            // Linear interpolation: point i gets (i/N) × total_drift removed.
            let fractionOfDrift = Double(i) / count
            let correction = observedDrift * fractionOfDrift
            // We rebuild the point with the corrected baro delta.
            // SurveyPoint is a value type so we create an updated copy.
            points[i] = SurveyPoint(
                id:                  points[i].id,
                timestamp:           points[i].timestamp,
                latitude:            points[i].latitude,
                longitude:           points[i].longitude,
                fusedAltitude:       points[i].fusedAltitude,
                groundElevation:     points[i].groundElevation,
                lidarDistance:       points[i].lidarDistance,
                gpsAltitude:         points[i].gpsAltitude,
                baroAltitudeDelta:   points[i].baroAltitudeDelta - correction,
                tiltAngle:           points[i].tiltAngle,
                horizontalAccuracy:  points[i].horizontalAccuracy,
                verticalAccuracy:    points[i].verticalAccuracy,
                isOutlier:           points[i].isOutlier
            )
        }
    }

    // MARK: - Loop-closure detection helper

    /// Returns `true` if `currentLocation` is within `kLoopClosureRadiusM` of
    /// `startLocation`, indicating a potential loop closure.
    func isLoopClosed(
        startLatitude:  Double,
        startLongitude: Double,
        currentLatitude:  Double,
        currentLongitude: Double
    ) -> Bool {
        let dist = haversineMetres(
            lat1: startLatitude,  lon1: startLongitude,
            lat2: currentLatitude, lon2: currentLongitude
        )
        return dist <= kLoopClosureRadiusM
    }

    // MARK: - Haversine distance

    private func haversineMetres(
        lat1: Double, lon1: Double,
        lat2: Double, lon2: Double
    ) -> Double {
        let R    = 6_371_000.0   // Earth radius in metres
        let φ1   = lat1 * .pi / 180
        let φ2   = lat2 * .pi / 180
        let Δφ   = (lat2 - lat1) * .pi / 180
        let Δλ   = (lon2 - lon1) * .pi / 180
        let a    = sin(Δφ/2)*sin(Δφ/2) + cos(φ1)*cos(φ2)*sin(Δλ/2)*sin(Δλ/2)
        let c    = 2 * atan2(sqrt(a), sqrt(1-a))
        return R * c
    }
}
