// GPSManager.swift
// TerrainMapper
//
// Wraps CoreLocation to stream CLLocation updates via Combine and to fill in
// position gaps between GPS fixes using Pedestrian Dead Reckoning (PDR).
//
// ─── Pedestrian Dead Reckoning (PDR) ─────────────────────────────────────
// GPS on modern iPhones updates at ~1 Hz with a typical horizontal accuracy
// of 3–15 m.  Between fixes, the operator may have moved significantly.
//
// PDR improves position estimates between fixes using:
//   • Step count from CMPedometer (counts and cadence)
//   • Heading from CLLocationManager (CLHeading, fused mag + gyro)
//
// Each step of typical stride length S (default 0.75 m) in direction θ:
//   Δlat = S × cos(θ) / R_earth
//   Δlon = S × sin(θ) / (R_earth × cos(lat))
//
// The PDR position is reset to the GPS fix whenever a new CLLocation arrives,
// preventing unbounded drift.
//
// ─── Coordinate conventions ──────────────────────────────────────────────
// Heading: degrees clockwise from true north (CLHeading.trueHeading).
// Latitude increases northward; longitude increases eastward.

import CoreLocation
import CoreMotion
import Combine
import Foundation

@MainActor
final class GPSManager: NSObject, ObservableObject {

    // MARK: - Public

    /// Publishes each new GPS fix (or PDR-refined position).
    var locationPublisher: AnyPublisher<CLLocation, Never> {
        locationSubject.eraseToAnyPublisher()
    }

    /// The most recent location (GPS or PDR-derived).
    @Published private(set) var currentLocation: CLLocation?

    /// Current heading (degrees clockwise from true north).
    @Published private(set) var currentHeading: Double = 0.0

    /// Authorization status.
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    // MARK: - Private

    private let locationManager = CLLocationManager()
    private let pedometer       = CMPedometer()
    private let locationSubject = PassthroughSubject<CLLocation, Never>()

    /// Latest cumulative step count delivered by the pedometer streaming callback.
    /// Updated on every CMPedometer event so we can anchor to it on GPS fix.
    private var latestTotalStepCount: Int = 0

    /// Cumulative step count at the moment of the most recent GPS fix.
    /// `newSteps = latestTotalStepCount - lastFixStepCount` gives steps since fix.
    private var lastFixStepCount: Int = 0

    /// Cumulative step count at the moment of the last PDR update.
    /// Used to compute incremental steps (delta since last callback) for accurate PDR.
    private var lastPDRStepCount: Int = 0

    /// PDR-extrapolated position (updated each time a new step event arrives).
    private var pdrLatitude:  Double = 0
    private var pdrLongitude: Double = 0

    /// Typical pedestrian stride length in metres.  Could be calibrated per user.
    private let kStrideLength = 0.75

    private let kEarthRadius  = 6_371_000.0  // metres

    // MARK: - Lifecycle

    func start() {
        locationManager.delegate                 = self
        locationManager.desiredAccuracy          = kCLLocationAccuracyBest
        locationManager.distanceFilter           = kCLDistanceFilterNone
        locationManager.headingFilter            = 1.0    // update every 1° change
        locationManager.pausesLocationUpdatesAutomatically = false

        requestAuthorization()
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
        startPedometerUpdates()
    }

    func stop() {
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        pedometer.stopUpdates()
    }

    // MARK: - Authorization

    private func requestAuthorization() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            break   // already granted
        default:
            print("[GPSManager] Location authorization denied or restricted.")
        }
    }

    // MARK: - CMPedometer

    private func startPedometerUpdates() {
        guard CMPedometer.isStepCountingAvailable() else {
            print("[GPSManager] Step counting unavailable.")
            return
        }
        pedometer.startUpdates(from: Date()) { [weak self] data, error in
            guard let self, let data, error == nil else { return }
            Task { @MainActor in
                self.handlePedometerData(data)
            }
        }
    }

    private func handlePedometerData(_ data: CMPedometerData) {
        let totalSteps      = data.numberOfSteps.intValue
        latestTotalStepCount = totalSteps          // keep running total up to date
        let newSteps        = totalSteps - lastPDRStepCount
        guard newSteps > 0  else { return }

        // PDR: project each new step in current heading direction
        let headingRad      = currentHeading * .pi / 180.0
        let distanceMetres  = Double(newSteps) * kStrideLength

        let Δlat = distanceMetres * cos(headingRad) / kEarthRadius
        let Δlon = distanceMetres * sin(headingRad) / (kEarthRadius * cos(pdrLatitude * .pi / 180))

        pdrLatitude  += Δlat * 180 / .pi
        pdrLongitude += Δlon * 180 / .pi
        lastPDRStepCount = totalSteps

        // Emit a synthetic PDR-derived location (low accuracy, altitude from last GPS)
        guard let lastFix = currentLocation else { return }
        let pdrCoord    = CLLocationCoordinate2D(latitude: pdrLatitude, longitude: pdrLongitude)
        let pdrLocation = CLLocation(
            coordinate:           pdrCoord,
            altitude:             lastFix.altitude,
            horizontalAccuracy:   lastFix.horizontalAccuracy + Double(newSteps) * 0.5,  // growing uncertainty
            verticalAccuracy:     lastFix.verticalAccuracy,
            course:               currentHeading,
            speed:                lastFix.speed,
            timestamp:            Date()
        )
        locationSubject.send(pdrLocation)
    }

    // MARK: - PDR refinement on recorded points

    /// Refines the horizontal positions of survey points captured between GPS
    /// fixes by re-interpolating them along the PDR track.
    ///
    /// This is a post-processing step called when the session ends.  It
    /// replaces the GPS position stored at capture time with the PDR
    /// estimate anchored between the nearest preceding and following GPS fixes.
    func refineWithPDR(points: inout [SurveyPoint]) {
        // Identify points that were captured with low GPS accuracy (> 10 m)
        // and interpolate their position between neighbouring high-accuracy fixes.
        guard points.count >= 2 else { return }

        var fixIndices: [Int] = []
        for (i, p) in points.enumerated() where p.horizontalAccuracy <= 10.0 {
            fixIndices.append(i)
        }
        guard fixIndices.count >= 2 else { return }

        for segStart in 0..<(fixIndices.count - 1) {
            let iA = fixIndices[segStart]
            let iB = fixIndices[segStart + 1]
            guard iB - iA > 1 else { continue }

            let pA = points[iA]
            let pB = points[iB]
            let segLen = Double(iB - iA)

            for i in (iA + 1)..<iB {
                let t = Double(i - iA) / segLen   // 0…1 along segment
                let newLat = pA.latitude  + t * (pB.latitude  - pA.latitude)
                let newLon = pA.longitude + t * (pB.longitude - pA.longitude)

                points[i] = SurveyPoint(
                    id:                 points[i].id,
                    timestamp:          points[i].timestamp,
                    latitude:           newLat,
                    longitude:          newLon,
                    fusedAltitude:      points[i].fusedAltitude,
                    groundElevation:    points[i].groundElevation,
                    lidarDistance:      points[i].lidarDistance,
                    gpsAltitude:        points[i].gpsAltitude,
                    baroAltitudeDelta:  points[i].baroAltitudeDelta,
                    tiltAngle:          points[i].tiltAngle,
                    horizontalAccuracy: points[i].horizontalAccuracy,
                    verticalAccuracy:   points[i].verticalAccuracy,
                    isOutlier:          points[i].isOutlier
                )
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension GPSManager: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedWhenInUse ||
               manager.authorizationStatus == .authorizedAlways {
                manager.startUpdatingLocation()
                manager.startUpdatingHeading()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // Filter out stale or inaccurate fixes
        guard location.horizontalAccuracy > 0,
              location.horizontalAccuracy < 100,
              -location.timestamp.timeIntervalSinceNow < 5 else { return }

        Task { @MainActor in
            self.currentLocation  = location
            // Anchor PDR to the new fix: use the streaming total, not a separate query
            self.pdrLatitude      = location.coordinate.latitude
            self.pdrLongitude     = location.coordinate.longitude
            self.lastFixStepCount = self.latestTotalStepCount
            self.lastPDRStepCount = self.latestTotalStepCount
            self.locationSubject.send(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }  // negative = invalid
        Task { @MainActor in
            // Use trueHeading if available (requires location), else magnetic.
            self.currentHeading = newHeading.trueHeading >= 0
                ? newHeading.trueHeading
                : newHeading.magneticHeading
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        print("[GPSManager] Location error: \(error.localizedDescription)")
    }

}
