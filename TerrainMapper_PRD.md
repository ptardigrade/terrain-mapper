# TerrainMapper — Full Technical Architecture
### iPhone 16 Pro Terrain Survey App
**Target accuracy: ±0.3–0.5m relative vertical, ±1–2m absolute vertical, ±0.5–1.5m horizontal**

---

## Table of Contents

1. [Accuracy Model & Theoretical Basis](#1-accuracy-model--theoretical-basis)
2. [Sensor Inventory & Roles](#2-sensor-inventory--roles)
3. [System Architecture Overview](#3-system-architecture-overview)
4. [Core Data Models](#4-core-data-models)
5. [Session State Machine](#5-session-state-machine)
6. [Sensor Fusion Engine — Kalman Filter Design](#6-sensor-fusion-engine--kalman-filter-design)
7. [Point Storage Protocol](#7-point-storage-protocol)
8. [LiDAR Ground Measurement](#8-lidar-ground-measurement)
9. [Tilt Correction Geometry](#9-tilt-correction-geometry)
10. [Pedestrian Dead Reckoning (PDR)](#10-pedestrian-dead-reckoning-pdr)
11. [Barometric Loop Closure](#11-barometric-loop-closure)
12. [Post-Processing Pipeline](#12-post-processing-pipeline)
13. [Interpolation & DEM Generation](#13-interpolation--dem-generation)
14. [ARKit Local Mesh Layer](#14-arkit-local-mesh-layer)
15. [Export Formats](#15-export-formats)
16. [UI/UX Architecture](#16-uiux-architecture)
17. [Swift Technology Stack & APIs](#17-swift-technology-stack--apis)
18. [File & Storage Architecture](#18-file--storage-architecture)
19. [Accuracy Audit — What Gets You to Sub-0.5m](#19-accuracy-audit--what-gets-you-to-sub-05m)
20. [Known Limitations & Honest Caveats](#20-known-limitations--honest-caveats)

---

## 1. Accuracy Model & Theoretical Basis

### 1.1 The Fundamental Constraint

GPS vertical accuracy is limited by satellite geometry. The Dilution of Precision in the vertical axis (VDOP) is inherently worse than horizontal because satellites are visible only above the horizon — you never have geometry below you. iPhone 16 Pro's L1+L5 dual-frequency GNSS reduces ionospheric error (a major vertical error source) by computing the frequency-dependent delay and cancelling it, which is why it materially outperforms older single-frequency devices.

**Single fix vertical accuracy:**
- iPhone 14 and older (L1 only): ±8–15m
- iPhone 16 Pro (L1+L5, calm conditions, open sky): ±3–5m, `verticalAccuracy` reported by CoreLocation is a 68% confidence interval (1σ)

**Sample averaging:**
Random measurement noise reduces by √n with n independent samples. Taking 25 samples over ~3 seconds:
```
σ_averaged = σ_single / √n = 4m / √25 = 0.8m
```
However, GPS errors are **not fully independent** — multipath and atmospheric errors are correlated over seconds. In practice, averaging reduces noise by a factor of ~2–3×, not the full √n. Realistic post-averaging vertical accuracy: **±1.5–2.5m**.

This means GPS alone **cannot** achieve sub-0.5m accuracy. The path to sub-0.5m is:

1. Use GPS only as an **absolute anchor** (global position reference)
2. Use the **barometer** for accurate *relative* elevation differences between points
3. Use **LiDAR** to precisely measure the stick-to-ground offset, removing the largest remaining systematic error
4. Use **IMU tilt correction** to remove geometric stick lean error
5. Apply **barometric loop closure** to detect and distribute session-wide pressure drift

### 1.2 Relative vs. Absolute Accuracy — Critical Distinction

| Accuracy Type | Definition | Achievable |
|---|---|---|
| **Relative (local)** | Elevation difference between two points within the same survey session | ±0.2–0.4m with this system |
| **Absolute (geodetic)** | Elevation above WGS84 ellipsoid or a geoid model | ±1–2m limited by GPS |

**For terrain mapping purposes, relative accuracy is what matters.** The shape of the terrain — slopes, valleys, ridges, terraces — is defined by relative elevation differences. The absolute anchor (GPS) places the model correctly on the globe. This app achieves excellent relative accuracy and good absolute accuracy.

### 1.3 Error Budget — Vertical Accuracy Per Point

| Error Source | Magnitude | Mitigation | Residual |
|---|---|---|---|
| GPS vertical noise | ±3–5m (1σ) | 25-sample averaging + baro fusion | ±1–2m absolute anchor |
| Barometric pressure-to-altitude conversion | ±0.1m relative | Short sessions, loop closure | ±0.05–0.15m |
| Stick height measurement | ±1–3cm (human measurement) | Store as calibration constant | ±0.01–0.03m |
| Stick tilt error | varies with angle (see §9) | LiDAR + IMU correction | ±0.01–0.02m |
| LiDAR ground measurement | ±2–5cm at 1.5m range outdoors | Average 30 LiDAR frames | ±0.01–0.03m |
| Vegetation/surface offset | 0–5cm depending on ground cover | Cannot be fully corrected | ±0–0.05m |
| **Total relative error (RMS)** | | | **±0.15–0.35m** |
| **Total absolute error (RMS)** | | | **±1.0–2.0m** |

---

## 2. Sensor Inventory & Roles

### 2.1 GNSS/GPS — `CLLocationManager`

**Hardware:** Apple-designed GNSS chip, dual-frequency L1 (1575.42 MHz) + L5 (1176.45 MHz)
**Update rate:** Up to 1Hz for `CLLocation` (sufficient; more frequent via `allowsBackgroundLocationUpdates`)
**Data provided:**
- `coordinate.latitude` / `coordinate.longitude` — horizontal position (WGS84)
- `altitude` — altitude above WGS84 ellipsoid in meters
- `horizontalAccuracy` — 68% confidence radius in meters (discard if > 8m)
- `verticalAccuracy` — 68% confidence interval in meters (discard if > 10m)
- `speed`, `course` — velocity vector
- `timestamp` — GPS time, very precise

**Why L5 matters:** L5 signals are transmitted at higher power and have a wider bandwidth, making them more resistant to multipath interference (signals reflecting off buildings/terrain). This is the primary vertical accuracy improvement over older iPhones.

**Configuration:**
```swift
locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
locationManager.distanceFilter = kCLDistanceFilterNone
locationManager.headingFilter = kCLHeadingFilterNone
locationManager.activityType = .otherNavigation // prevents iOS from throttling
```

### 2.2 Barometric Altimeter — `CMAltimeter`

**Hardware:** Bosch BMP390 (or equivalent) MEMS pressure sensor
**Resolution:** ~0.016 Pa → ~0.013m altitude resolution at sea level
**Practical relative altitude resolution:** ~0.1m
**Update rate:** Up to 1Hz via `startRelativeAltitudeUpdates`
**Data provided:**
- `relativeAltitude` — altitude change from session start in meters (NSMeasurement)
- `pressure` — absolute atmospheric pressure in kPa

**Critical behavior:** `relativeAltitude` is computed from pressure using the **barometric formula**:
```
Δh = (T₀ / L) × (1 - (P / P₀)^(R×L / g×M))
```
Where T₀ = reference temperature (assumed standard), L = lapse rate. iOS uses a simplified version. Crucially, it uses the **change in pressure** from when `startRelativeAltitudeUpdates` was called — it is always relative, never absolute.

**Drift mechanism:** If atmospheric pressure changes during a session (weather front, wind, temperature), the barometer reading drifts. Over 30 minutes of stable weather, drift is typically < 0.5m. Over a 2-hour session in changing conditions, drift can reach 2–5m. This is mitigated by loop closure (§11).

### 2.3 Accelerometer — `CMMotionManager`

**Hardware:** 3-axis MEMS accelerometer
**Update rate:** Up to 100Hz
**Range:** ±16g
**Data provided:** `CMAccelerometerData.acceleration` — 3-axis acceleration in g, device frame

**Roles in this app:**
1. **Tilt measurement** (combined with gyroscope via `CMDeviceMotion` — see §2.5)
2. **Stationary detection** — during point storage, confirm variance of acceleration is below threshold
3. **Step detection** — magnitude peaks for PDR (see §10)

### 2.4 Gyroscope — `CMMotionManager`

**Hardware:** 3-axis MEMS gyroscope
**Update rate:** Up to 100Hz
**Data provided:** `CMGyroData.rotationRate` — angular velocity in rad/s, device frame

**Role:** Combined with accelerometer in the sensor fusion (`CMDeviceMotion`) to give stable orientation. Not used independently.

### 2.5 Device Motion (Fused IMU) — `CMDeviceMotion`

**This is the correct API to use** — it combines accelerometer, gyroscope, and magnetometer via an onboard sensor fusion algorithm (complementary filter) to produce stable, drift-corrected orientation.

**Update rate:** Up to 100Hz (`CMMotionManager.deviceMotionUpdateInterval = 0.01`)
**Reference frame:** `CMAttitudeReferenceFrameXArbitraryZVertical` — Z-axis locked to gravity direction
**Data provided:**
- `CMDeviceMotion.attitude` — `CMAttitude` with `roll`, `pitch`, `yaw` in radians and a `rotationMatrix`
- `CMDeviceMotion.gravity` — gravity vector in device frame (unit vector pointing down)
- `CMDeviceMotion.userAcceleration` — acceleration with gravity removed
- `CMDeviceMotion.rotationRate` — gyroscope data

**Key use:** `gravity` vector gives precise tilt of the device from vertical. If phone is mounted facing up on the stick, the tilt angle from vertical:
```swift
let tiltFromVertical = acos(abs(motion.gravity.z)) // radians
let tiltDegrees = tiltFromVertical * (180 / .pi)
```

### 2.6 Magnetometer — `CMMagnetometer` / `CLHeading`

**Hardware:** 3-axis Hall-effect magnetometer
**Data provided:**
- `CMDeviceMotion.heading` (when using `xMagneticNorthZVertical` reference frame) — true heading
- `CLLocationManager.heading` — `CLHeading` with `magneticHeading`, `trueHeading`, `headingAccuracy`

**Role:** Heading input for PDR step-direction tracking. Use `CLHeading.trueHeading` (corrected for local declination by CoreLocation). Flag readings where `headingAccuracy < 0` (unreliable, usually due to magnetic interference).

### 2.7 LiDAR Scanner — `ARKit` / `RealityKit`

**Hardware:** Apple-designed dToF (direct Time-of-Flight) LiDAR scanner
**Range:** 0.5cm – ~5m (reliable outdoor range at 1.5m: excellent)
**Angular resolution:** ~0.5° effective
**Frame rate:** 30fps
**Outdoor performance note:** dToF LiDAR performs well in sunlight at distances under 2m. Beyond 3m in bright sunlight, ambient IR noise reduces reliability. At stick height (0.8–1.8m), you are well within the reliable range.

**Two distinct use modes in this app:**

**Mode A — Ground Distance Measurement (§8):**
Fire LiDAR downward from the stick mount. Use `ARDepthData` to sample the depth directly below the device. Average the central region of the depth map to get the measured stick-to-ground distance. This replaces the assumed stick height constant with a measured one, updated every frame.

**Mode B — Local Mesh Capture (§14):**
At stored points, capture ARKit's `ARMeshAnchor` geometry within a 3m radius. This gives a local high-resolution terrain mesh with centimeter-level relative accuracy, positioned globally by the GPS anchor of that point.

**API:** `ARWorldTrackingConfiguration` with `sceneReconstruction = .mesh`

### 2.8 Camera — `AVFoundation` / `ARKit`

**Roles:**
1. **Visual Odometry via ARKit:** ARKit's visual-inertial odometry (VIO) tracks device position between GPS fixes with ~1–3cm relative precision over short distances (degrades with distance and texture-poor surfaces). Provides a high-rate position stream between GPS updates.
2. **Optional photogrammetry:** Burst capture at stored points for RealityKit photogrammetry post-processing.

**Note on ARKit VIO drift:** ARKit's world coordinate origin drifts over large surveys (>50m from origin). Over a 100m × 100m survey, VIO drift can reach 0.5–2m. This system uses ARKit VIO only for **local, short-duration position refinement** between GPS fixes — the GPS anchor always overrides for global positioning.

---

## 3. System Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         SENSOR LAYER                            │
│                                                                  │
│  CLLocationManager    CMAltimeter    CMDeviceMotion    ARKit    │
│  (GPS L1+L5)          (Barometer)    (IMU Fusion)    (LiDAR+VIO)│
│       │                    │               │              │     │
└───────┼────────────────────┼───────────────┼──────────────┼─────┘
        │                    │               │              │
        ▼                    ▼               ▼              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      SENSOR FUSION ENGINE                        │
│                                                                  │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │        Altitude Kalman Filter (AltitudeKF)              │   │
│   │  State: [altitude, vertical_velocity, baro_bias]        │   │
│   │  Observations: GPS altitude, barometric delta           │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │    Tilt & Ground Distance Processor (StickGeometry)     │   │
│   │  Inputs: CMDeviceMotion.gravity, ARDepthData center     │   │
│   │  Output: corrected_ground_elevation                     │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │       Pedestrian Dead Reckoning (PDRTracker)            │   │
│   │  Inputs: CMDeviceMotion.userAcceleration, CLHeading     │   │
│   │  Output: refined_horizontal_position                    │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │     Stationary Gate (StationaryValidator)               │   │
│   │  Inputs: CMDeviceMotion.userAcceleration (variance)     │   │
│   │  Output: isStationary: Bool, stationaryDuration: Double │   │
│   └─────────────────────────────────────────────────────────┘   │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                      SESSION MANAGER                             │
│                                                                  │
│  SessionState: idle / active / pointCapture / ended             │
│  Manages: raw data stream, stored points, ARKit session         │
│  Emits: LiveSessionData (to UI), RawDataLog (to disk)          │
└────────────────────────────┬────────────────────────────────────┘
                             │
              ┌──────────────┴──────────────┐
              ▼                             ▼
┌─────────────────────┐         ┌─────────────────────────┐
│   CONTINUOUS LOG    │         │    STORED POINT STORE   │
│                     │         │                         │
│  RawSample[]:       │         │  SurveyPoint[]:         │
│  - timestamp        │         │  - fused position       │
│  - gps_fix          │         │  - confidence score     │
│  - baro_relative    │         │  - lidar_ground_dist    │
│  - imu_attitude     │         │  - local_mesh_anchor    │
│  - lidar_depth      │         │  - metadata             │
│  - arkit_pose       │         │                         │
└─────────────────────┘         └────────────┬────────────┘
                                             │
                                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                   POST-PROCESSING PIPELINE                       │
│                                                                  │
│  1. Outlier rejection (IQR + accuracy thresholds)               │
│  2. Barometric loop closure & drift correction                   │
│  3. PDR-assisted horizontal position refinement                 │
│  4. Local mesh georeferencing (GPS anchor + ARKit geometry)     │
│  5. Ground elevation computation per point                       │
│  6. DEM grid interpolation (IDW with kriging fallback)          │
│  7. Contour line generation                                      │
│  8. Mesh triangulation (Delaunay)                               │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                        EXPORT ENGINE                             │
│  PLY (point cloud) │ GeoJSON │ CSV │ OBJ/USDZ │ GeoTIFF (DEM) │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. Core Data Models

### 4.1 RawSample
Captured continuously at ~10Hz throughout the session.

```swift
struct RawSample {
    let timestamp: TimeInterval          // CACurrentMediaTime(), monotonic clock
    let gpsTimestamp: Date?              // CLLocation.timestamp (may be nil if no fix)

    // GPS
    let latitude: Double?                // WGS84 degrees
    let longitude: Double?               // WGS84 degrees
    let gpsAltitude: Double?             // meters above WGS84 ellipsoid
    let horizontalAccuracy: Double?      // meters (1σ, 68% confidence)
    let verticalAccuracy: Double?        // meters (1σ, 68% confidence)
    let gpsCourse: Double?               // degrees true north
    let gpsSpeed: Double?                // m/s

    // Barometer
    let baroRelativeAltitude: Double     // meters from session start
    let baroPressure: Double             // kPa

    // IMU (from CMDeviceMotion)
    let gravityX: Double                 // device frame, unit vector
    let gravityY: Double
    let gravityZ: Double
    let userAccelX: Double               // gravity-removed, in g
    let userAccelY: Double
    let userAccelZ: Double
    let roll: Double                     // radians
    let pitch: Double                    // radians
    let yaw: Double                      // radians
    let rotationRateX: Double            // rad/s
    let rotationRateY: Double
    let rotationRateZ: Double

    // LiDAR
    let lidarGroundDistance: Double?     // meters, nil if no valid LiDAR reading
    let lidarConfidence: Float?          // ARDepthData confidence 0.0–1.0

    // ARKit VIO
    let arkitPositionX: Float?           // ARKit world coordinates (meters)
    let arkitPositionY: Float?
    let arkitPositionZ: Float?
    let arkitTrackingState: ARCamera.TrackingState.Reason? // nil = .normal

    // Kalman filter output (running estimate)
    let kalmanAltitude: Double           // fused altitude, meters
    let kalmanAltitudeVariance: Double   // posterior variance from KF
}
```

### 4.2 SurveyPoint
Created when the user presses "Store Point" and the acceptance criteria are met.

```swift
struct SurveyPoint: Identifiable, Codable {
    let id: UUID
    let sessionID: UUID
    let userIndex: Int                   // human-readable index (1, 2, 3...)
    let captureTimestamp: Date

    // GPS (averaged over capture window)
    let latitude: Double                 // weighted mean of N GPS samples
    let longitude: Double                // weighted mean of N GPS samples
    let gpsAltitude: Double              // weighted mean GPS altitude
    let gpsAltitudeStdDev: Double        // std dev of the N samples
    let gpsHorizontalAccuracy: Double    // mean horizontal accuracy
    let gpsSampleCount: Int              // how many GPS samples were averaged

    // Barometric
    let baroRelativeAtCapture: Double    // baro reading at this point
    let baroFusedAltitude: Double        // Kalman filter output altitude

    // Stick geometry
    let stickHeight: Double              // user-configured stick height (m)
    let lidarMeasuredDistance: Double?   // LiDAR-measured slant range (m)
    let tiltAngleRad: Double            // device tilt from vertical at capture (rad)
    let tiltCorrectedStickHeight: Double // computed vertical component (m)
    let groundElevation: Double          // baroFusedAltitude - tiltCorrectedStickHeight

    // Confidence
    let stationaryDuration: Double       // seconds device was stationary before capture
    let imuTiltMean: Double             // mean tilt during capture window (rad)
    let imuTiltMaxDeviation: Double     // max tilt deviation during window (rad)
    let confidenceScore: Double         // 0.0–1.0 composite score (see §7.4)
    let isOutlier: Bool                 // set during post-processing

    // ARKit
    let arkitMeshAnchorID: UUID?        // reference to local mesh, if captured
    let arkitWorldPosition: simd_float3? // ARKit world coords at capture

    // PDR-refined position (post-processing)
    var pdrRefinedLatitude: Double?
    var pdrRefinedLongitude: Double?
}
```

### 4.3 SurveySession

```swift
struct SurveySession: Identifiable, Codable {
    let id: UUID
    let startDate: Date
    var endDate: Date?

    let stickHeight: Double              // user-configured (m)
    let deviceModel: String             // e.g. "iPhone16,2"
    let appVersion: String

    // Calibration
    let baroReferenceAtStart: Double     // baro pressure at session start (kPa)
    var baroReferenceAtEnd: Double?     // for loop closure
    let gpsAltitudeAtStart: Double?     // GPS anchor at session start

    // Points
    var surveyPoints: [SurveyPoint]
    var pointCount: Int { surveyPoints.count }

    // Computed bounds
    var boundingBox: (minLat: Double, maxLat: Double,
                      minLon: Double, maxLon: Double,
                      minElev: Double, maxElev: Double)?

    // Processing state
    var isProcessed: Bool
    var processingVersion: String?
    var baroDriftCorrectionApplied: Double? // meters of drift corrected
}
```

### 4.4 DEMGrid (Post-Processing Output)

```swift
struct DEMGrid: Codable {
    let sessionID: UUID
    let generatedDate: Date

    // Grid definition
    let originLatitude: Double           // SW corner latitude
    let originLongitude: Double          // SW corner longitude
    let cellSizeMeters: Double           // e.g. 0.5m, 1.0m, 2.0m
    let gridWidth: Int                   // number of columns
    let gridHeight: Int                  // number of rows

    // Elevation data
    let elevations: [[Double?]]          // row-major, nil = no data
    let confidences: [[Double]]          // interpolation confidence 0–1

    // Statistics
    let minElevation: Double
    let maxElevation: Double
    let elevationRange: Double
    let noDataFraction: Double           // fraction of cells with no coverage
}
```

---

## 5. Session State Machine

```
                    ┌─────────┐
                    │  IDLE   │◄──────────────────────────────┐
                    └────┬────┘                               │
                         │ user taps "Start Session"          │
                         │ enters stick height                │
                         ▼                                    │
                  ┌─────────────┐                            │
            ┌────►│  STARTING   │                            │
            │     │             │                            │
            │     │ · GPS warm-up (wait for vAcc < 8m)      │
            │     │ · Baro reference captured               │
            │     │ · ARKit session initialized             │
            │     │ · KF initialized                        │
            │     └──────┬──────┘                           │
            │            │ GPS ready + sensors nominal       │
            │            ▼                                   │
            │     ┌─────────────┐                           │
            │     │   WALKING   │◄────────────────┐         │
            │     │  (ACTIVE)   │                 │         │
            │     │             │                 │         │
            │     │ All sensors │                 │         │
            │     │ logging at  │                 │         │
            │     │ full rate   │                 │         │
            │     └──────┬──────┘                │         │
            │            │ user taps             │         │
            │            │ "Store Point"         │         │
            │            ▼                       │         │
            │     ┌─────────────┐                │         │
            │     │  CAPTURING  │                │         │
            │     │   POINT     │                │         │
            │     │             │                │         │
            │     │ · Stationary│                │         │
            │     │   check     │                │         │
            │     │ · Tilt check│                │         │
            │     │ · 3s window │                │         │
            │     │ · LiDAR avg │                │         │
            │     │ · GPS avg   │                │         │
            │     │ · Baro snap │                │         │
            │     └──┬──────┬───┘                │         │
            │        │      │ acceptance          │         │
            │  reject│      │ criteria met        │         │
            │  (show │      ▼                     │         │
            │  reason│  ┌──────────┐              │         │
            │        │  │  POINT   │              │         │
            │        │  │ ACCEPTED │──────────────┘         │
            │        │  └──────────┘ continue walking       │
            │        └──────────────────────────────────────┘
            │                   (user can delete last point)
            │
            │ user taps "End Session" (min 3 points)
            ▼
     ┌─────────────┐
     │  PROCESSING │
     │             │
     │ · Outlier   │
     │   rejection │
     │ · Baro loop │
     │   closure   │
     │ · PDR refine│
     │ · DEM gen   │
     │ · Mesh stitch│
     └──────┬──────┘
            │
            ▼
     ┌─────────────┐
     │  COMPLETED  │───────────────────────────────────────┘
     │  (Results)  │ user views results, exports, or starts new
     └─────────────┘
```

### 5.1 State Transition Guards

**STARTING → WALKING:**
- `CLLocation.verticalAccuracy < 8.0m` sustained for 5 seconds
- `CMAltimeter` returning updates
- `CMDeviceMotion` available at 50Hz
- ARKit tracking state = `.normal`

**WALKING → CAPTURING:**
- Immediate on button press; transition to WALKING resumes after accept/reject

**CAPTURING → POINT ACCEPTED:**
- Device stationary for ≥ 2.5 seconds (IMU variance gate, see §7.1)
- Tilt ≤ 5° from vertical sustained for ≥ 2.0 seconds (or user manually overrides)
- ≥ 5 GPS samples with `verticalAccuracy < 10m` available in the window
- LiDAR returned ≥ 10 valid depth readings (if LiDAR active)

**CAPTURING → REJECTED:**
- Motion detected during countdown (IMU variance exceeded threshold)
- Tilt > 15° (uncorrectable geometry)
- Zero valid GPS fixes in window (complete signal loss)
- User taps cancel

---

## 6. Sensor Fusion Engine — Kalman Filter Design

The altitude Kalman filter is the mathematical core of the accuracy system. It maintains a running optimal estimate of altitude by fusing GPS (high noise, absolute reference) with the barometer (low noise, relative only).

### 6.1 State Vector

```
x = [altitude, vertical_velocity, baro_bias]
```

- `altitude` (meters, absolute WGS84): the quantity we want to estimate
- `vertical_velocity` (m/s): allows the filter to predict movement between updates
- `baro_bias` (meters): the running estimate of the barometer's offset from GPS altitude

### 6.2 State Transition Model (Prediction Step)

At each timestep `dt`, the predicted state is:
```
x_predicted = F × x_previous
```
Where F (state transition matrix) is:
```
F = [1,  dt,  0  ]
    [0,  1,   0  ]
    [0,  0,   1  ]
```
This says: altitude = previous_altitude + velocity × dt; velocity unchanged; bias unchanged. The bias is modeled as a random walk (process noise handles its evolution).

**Process noise covariance Q:**
Tuned empirically:
- Altitude process noise: 0.01 m²/s (smooth terrain, low dynamics)
- Velocity process noise: 0.1 m²/s² (accounts for walking speed changes)
- Baro bias process noise: 0.0001 m²/s (bias changes slowly = pressure drift)

### 6.3 GPS Observation Model

GPS observes absolute altitude directly:
```
z_gps = H_gps × x + noise_gps
H_gps = [1, 0, 0]
R_gps = verticalAccuracy² (dynamic, from CLLocation.verticalAccuracy)
```
The measurement noise is set **dynamically** per GPS fix using the reported `verticalAccuracy`. When accuracy is poor, R is large and the filter trusts GPS less. When accuracy is good, R is small and GPS updates pull the estimate strongly.

### 6.4 Barometer Observation Model

The barometer observes altitude minus its own bias:
```
z_baro = H_baro × x + noise_baro
H_baro = [1, 0, -1]   // altitude - bias = baro reading offset to GPS
R_baro = 0.1² = 0.01 m²  (fixed, from sensor spec)
```
The `(1, 0, -1)` observation matrix means: "the baro reading equals true altitude minus the baro bias." This allows the filter to simultaneously estimate both altitude and the growing bias over time.

### 6.5 Implementation Notes

```swift
class AltitudeKalmanFilter {
    // State
    var x: SIMD3<Double>        // [altitude, velocity, baro_bias]
    var P: matrix_double3x3     // Covariance matrix

    // Process noise (tuned)
    let Q: matrix_double3x3

    // Fixed baro noise
    let R_baro: Double = 0.01

    func predict(dt: Double) { /* F × x, F × P × F.T + Q */ }

    func updateGPS(altitude: Double, verticalAccuracy: Double) {
        let R_gps = verticalAccuracy * verticalAccuracy
        let H: SIMD3<Double> = [1, 0, 0]
        // Standard Kalman update: K, innovation, posterior
    }

    func updateBaro(relativeAltitude: Double, sessionStartGPSAltitude: Double) {
        let baroAbsolute = sessionStartGPSAltitude + relativeAltitude
        let H: SIMD3<Double> = [1, 0, -1]
        let R_baro = 0.01
        // Standard Kalman update
    }

    var estimatedAltitude: Double { x[0] }
    var estimatedBaroBias: Double { x[2] }
    var altitudeUncertainty: Double { sqrt(P[0, 0]) }
}
```

**Update scheduling:**
- Barometer updates: every new `CMAltimeter` callback (~1Hz) → call `updateBaro`
- GPS updates: every new `CLLocation` with `verticalAccuracy < 15m` → call `updateGPS`
- Prediction: every `CMDeviceMotion` callback (50Hz) → call `predict(dt:)`
- Between GPS fixes, the filter propagates on baro + inertial data alone

---

## 7. Point Storage Protocol

### 7.1 Stationary Validation

**IMU variance gate:** Compute the variance of `userAcceleration` magnitude over a sliding 1-second window.

```swift
struct StationaryValidator {
    private var accelerationBuffer: RingBuffer<Double> // last 50 samples at 50Hz = 1 second
    private let threshold: Double = 0.005 // g² variance threshold

    var isStationary: Bool {
        let mean = accelerationBuffer.mean
        let variance = accelerationBuffer.map { ($0 - mean) * ($0 - mean) }.mean
        return variance < threshold
    }

    var stationaryDurationSeconds: Double // rolling counter reset on motion detection
}
```

**Tilt gate:** Device must be within ±5° of vertical (configurable). This is computed from `CMDeviceMotion.gravity.z`:
```swift
let tiltAngle = acos(abs(motion.gravity.z)) // 0 = perfectly vertical
let isAcceptableTilt = tiltAngle < (5.0 * .pi / 180)
```

**Countdown UI:** A 3-second circular progress indicator. Resets to zero if:
- Motion exceeds stationary threshold
- Tilt exceeds limit (tilt warning shown in red)
- User removes finger from button

### 7.2 GPS Sample Averaging During Capture Window

During the 3-second capture window, collect all `CLLocation` updates where `verticalAccuracy < 10m`.

**Inverse-variance weighting** — more accurate GPS fixes get higher weight:
```swift
let weights = fixes.map { 1.0 / ($0.verticalAccuracy * $0.verticalAccuracy) }
let totalWeight = weights.reduce(0, +)
let weightedAlt = zip(fixes, weights)
    .map { $0.0.altitude * $0.1 }
    .reduce(0, +) / totalWeight
let weightedLat = zip(fixes, weights)
    .map { $0.0.coordinate.latitude * $0.1 }
    .reduce(0, +) / totalWeight
let weightedLon = zip(fixes, weights)
    .map { $0.0.coordinate.longitude * $0.1 }
    .reduce(0, +) / totalWeight
```

On average, 3 seconds captures 3 GPS fixes (1Hz). The Kalman filter running estimate provides a better altitude than any single GPS fix, so `baroFusedAltitude` from the KF output is used as the primary elevation, with the GPS average as the absolute anchor.

### 7.3 LiDAR Sample Averaging During Capture

During the capture window, ARKit delivers `ARDepthData` at 30fps → 90 depth frames. For each frame:

1. Extract the central N×N pixel region of the depth map (corresponding to the ground below the stick)
2. Filter pixels by confidence ≥ `ARConfidenceLevel.medium`
3. Compute the median depth value (median is more robust to outliers than mean)
4. Apply tilt correction: `verticalComponent = depthReading × |cos(tiltAngle)|`

Average the median values across all 90 frames → `lidarMeasuredDistance` with estimated ±2–4cm accuracy at 1.5m range outdoors.

**What LiDAR replaces:**
The stick height is no longer a fixed constant — it is a continuously-measured variable. This eliminates the largest systematic error in the system: the assumption that "stick = X meters."

### 7.4 Confidence Score Computation

Each stored point receives a `confidenceScore` (0.0–1.0) used for weighting during interpolation.

```swift
func computeConfidence(point: SurveyPoint) -> Double {
    var score = 1.0

    // GPS accuracy penalty
    let gpsAccuracyFactor = max(0, 1.0 - (point.gpsAltitudeStdDev / 3.0))
    score *= gpsAccuracyFactor

    // Stationary duration bonus
    let stationaryFactor = min(1.0, point.stationaryDuration / 3.0)
    score *= stationaryFactor

    // Tilt penalty
    let tiltDeg = point.tiltAngleRad * (180 / .pi)
    let tiltFactor = max(0, 1.0 - (tiltDeg / 10.0))
    score *= tiltFactor

    // LiDAR availability bonus
    if point.lidarMeasuredDistance != nil {
        score = min(1.0, score * 1.2)
    }

    // GPS sample count factor
    let sampleFactor = min(1.0, Double(point.gpsSampleCount) / 5.0)
    score *= sampleFactor

    return score
}
```

---

## 8. LiDAR Ground Measurement

### 8.1 Physical Setup Requirements

The iPhone must be mounted on the stick with the **rear cameras facing downward toward the ground**. The LiDAR scanner is co-located with the rear camera cluster on iPhone 16 Pro.

**Mount orientation:** The stick mount holds the phone with cameras pointing down and slightly toward the direction of travel. The exact mounting angle is not critical because tilt correction handles the geometry.

### 8.2 ARDepthData Sampling

```swift
// In ARSessionDelegate
func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard let depthMap = frame.sceneDepth?.depthMap,
          let confidenceMap = frame.sceneDepth?.confidenceMap else { return }

    let width = CVPixelBufferGetWidth(depthMap)
    let height = CVPixelBufferGetHeight(depthMap)

    // Sample the central 20% region — this is directly below the stick
    let centerX = width / 2
    let centerY = height / 2
    let regionSize = min(width, height) / 5

    var validDepths: [Float] = []

    CVPixelBufferLockBaseAddress(depthMap, .readOnly)
    CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
    }

    // Iterate central region
    for row in (centerY - regionSize/2)..<(centerY + regionSize/2) {
        for col in (centerX - regionSize/2)..<(centerX + regionSize/2) {
            let confidence = getConfidence(confidenceMap, col, row)
            if confidence >= ARConfidenceLevel.medium.rawValue {
                let depth = getDepth(depthMap, col, row) // Float, meters
                if depth > 0.3 && depth < 3.0 { // sanity bounds
                    validDepths.append(depth)
                }
            }
        }
    }

    if validDepths.count > 10 {
        validDepths.sort()
        let median = validDepths[validDepths.count / 2]
        lidarRingBuffer.append(Double(median))
    }
}
```

### 8.3 Computing Ground Elevation

```swift
func computeGroundElevation(
    fusedAltitude: Double,    // Kalman filter altitude of the PHONE
    lidarSlantRange: Double,  // measured distance along stick axis
    tiltAngle: Double         // radians from vertical
) -> Double {
    // Vertical component of the slant range
    let verticalStickHeight = lidarSlantRange * cos(tiltAngle)

    // Ground elevation = phone altitude - vertical stick component
    return fusedAltitude - verticalStickHeight
}
```

**Fallback (no LiDAR):** If LiDAR returns insufficient valid readings (e.g., very bright sunlight degrading IR, or no ARKit session), fall back to the user-configured stick height with the tilt correction applied.

---

## 9. Tilt Correction Geometry

### 9.1 The Geometric Error

If the stick is tilted by angle θ from vertical, and the true stick length is L, the actual vertical height component is:
```
h_vertical = L × cos(θ)
```
The error introduced by ignoring tilt:
```
error = L × (1 - cos(θ))
```

| Stick length | Tilt 2° | Tilt 5° | Tilt 10° | Tilt 15° |
|---|---|---|---|---|
| 1.0m | 0.6mm | 3.8mm | 15.2mm | 33.9mm |
| 1.5m | 0.9mm | 5.7mm | 22.8mm | 50.8mm |
| 2.0m | 1.2mm | 7.6mm | 30.4mm | 67.8mm |

At ≤5° tilt, error is < 6mm for a 1.5m stick — negligible. At 10°, error reaches 23mm — still within acceptable bounds but worth correcting. Beyond 15°, error exceeds 50mm and the app should warn the user.

### 9.2 Using LiDAR Instead

When LiDAR is active, the measured slant range already encodes the actual distance along the stick axis (accounting for any bending or uncertainty in the stick length). The correction is simply applying `cos(θ)` to get the vertical component, which is more accurate than assuming a fixed stick length.

### 9.3 IMU Tilt Measurement

`CMDeviceMotion.gravity` provides a unit vector in the direction of gravity in the device frame. When the device (and stick) are perfectly vertical, `gravity.z = -1.0` (z-axis points up on a face-down mounted phone, or +1.0 if face up — depends on mount). The tilt angle from vertical:

```swift
let gravityMagnitude = sqrt(motion.gravity.x * motion.gravity.x +
                            motion.gravity.y * motion.gravity.y +
                            motion.gravity.z * motion.gravity.z)
// Should be ~1.0; normalize for safety
let gz_normalized = motion.gravity.z / gravityMagnitude
let tiltFromVertical = acos(abs(gz_normalized))
```

This is valid regardless of the device's rotational orientation around the vertical axis (yaw), which is irrelevant to the height calculation.

---

## 10. Pedestrian Dead Reckoning (PDR)

PDR provides refined horizontal position between GPS fixes, reducing the horizontal positioning error from ±3–5m down to ±0.5–1.5m for positions between GPS updates.

### 10.1 Step Detection

From `CMDeviceMotion.userAcceleration` (gravity removed), the vertical component (`userAcceleration.z` when phone is mounted vertically with screen facing a certain direction — the specific axis depends on mount orientation and must be calibrated at session start):

```swift
// Peak detection on acceleration magnitude
let accelMagnitude = sqrt(pow(userAccel.x, 2) + pow(userAccel.y, 2) + pow(userAccel.z, 2))

// Step detected when magnitude crosses threshold from below
let stepThreshold: Double = 0.15  // g
let minStepInterval: TimeInterval = 0.25  // 240ms minimum (max ~4 steps/second)

if accelMagnitude > stepThreshold && previousMagnitude <= stepThreshold
   && (currentTime - lastStepTime) > minStepInterval {
    lastStepTime = currentTime
    detectStep()
}
```

### 10.2 Step Length Estimation

Step length is estimated from cadence and acceleration magnitude (Weinberg model):
```swift
func estimateStepLength(accelMagnitude: Double, cadenceHz: Double) -> Double {
    // Weinberg model: L = K × (amax - amin)^(1/4)
    let K: Double = 0.45  // calibration constant (tune per user)
    let accelRange = recentAccelMax - recentAccelMin
    return K * pow(accelRange, 0.25)
}
```

Typical step length: 0.6–0.8m (shorter when traversing rough terrain). The calibration constant K can be set by the user walking a known distance at session start.

### 10.3 Direction

Heading is taken from `CLHeading.trueHeading` (CoreLocation fuses magnetometer with GPS for declination). Updates are timestamped and interpolated to align with step events.

**Magnetic interference check:** If `CLHeading.headingAccuracy < 0` (invalid) or `headingAccuracy > 20°`, flag the PDR position as uncertain and fall back to GPS-only for that segment.

### 10.4 PDR Integration

Between two stored GPS-anchored points A and B:
```
position_PDR(t) = position_A + Σ(stepLength_i × direction_i)
```

After session ends, the PDR track is **corrected using the GPS anchors**: if PDR integration from point A reaches a position that differs from the GPS position of point B, the error is distributed linearly across all PDR steps between A and B (dead-reckoning correction / map-matching).

---

## 11. Barometric Loop Closure

### 11.1 The Drift Problem

If the user returns to a point previously visited (or ends near the start), the barometric reading at the "return" position should equal the reading when the point was first visited. Any difference is pressure drift accumulated over the session.

### 11.2 Detecting Loop Closure

At the end of a session, compare the barometer reading at the end point to the reading at start:
```swift
let totalBaroDrift = session.baroReferenceAtEnd - session.baroReferenceAtStart
```

If a surveyed point is within 5m of another surveyed point (different time during session), a local loop is detected:
```swift
func detectLoops(points: [SurveyPoint]) -> [(SurveyPoint, SurveyPoint)] {
    return points.enumerated().compactMap { i, p1 in
        points.enumerated().compactMap { j, p2 in
            guard j > i + 5 else { return nil } // not adjacent
            let dist = haversineDistance(p1, p2)
            return dist < 5.0 ? (p1, p2) : nil
        }
    }.flatMap { $0 }
}
```

### 11.3 Drift Correction

If total session baro drift is D meters and the session spans T total time:
```swift
func applyBaroDriftCorrection(points: inout [SurveyPoint], totalDrift: Double, sessionDuration: TimeInterval) {
    for i in points.indices {
        let timeFraction = points[i].captureTimestamp.timeIntervalSince(sessionStart) / sessionDuration
        let correctionAtPoint = -totalDrift * timeFraction  // linear model
        points[i].groundElevation += correctionAtPoint
        // Re-mark confidence if large correction needed
        if abs(correctionAtPoint) > 0.3 {
            points[i].confidenceScore *= 0.8
        }
    }
}
```

**Note:** This assumes drift is linear over time (reasonable for stable weather). If the pressure changes nonlinearly (e.g., sudden weather system passage), linear correction will be imperfect. A quadratic model can be used if 3 or more loop closure points are available.

---

## 12. Post-Processing Pipeline

The pipeline runs after "End Session" is tapped, on-device in a background `Task`. Progress is shown with a step-by-step progress UI.

### Step 1: Data Validation & Outlier Rejection
```
For each SurveyPoint:
  - Compute Z-score of groundElevation relative to session mean
  - Flag as outlier if |Z| > 3.0
  - Also flag if gpsAltitudeStdDev > 4.0m (very noisy GPS window)
  - Also flag if stationaryDuration < 1.5s (not stationary enough)
  - Also flag if imuTiltMaxDeviation > 0.15 rad during capture (too much sway)
  - Count flagged points; if > 20% of total, warn user
```

### Step 2: Barometric Loop Closure
- Detect loop closures (§11)
- Compute per-point drift correction
- Apply to all `groundElevation` values

### Step 3: PDR Position Refinement
- Run PDR integration across continuous log data
- For each pair of adjacent stored points, compute GPS anchor correction
- Apply position corrections to `SurveyPoint.pdrRefinedLatitude/Longitude`

### Step 4: Geoid Correction (Optional)
WGS84 altitude (what GPS gives) differs from orthometric altitude (elevation above mean sea level, EGM2008 geoid) by the geoid undulation N:
```
h_orthometric = h_WGS84 - N
```
The geoid undulation varies from -105m to +85m globally. For terrain mapping, this is irrelevant if all points use the same datum (they do). However, for absolute elevation display ("elevation above sea level"), apply the EGM2008 correction. A simplified geoid model can be embedded as a lookup table (~2MB for 1° resolution, interpolated bilinearly).

### Step 5: Ground Elevation Finalization
For each point, compute final `groundElevation`:
```
groundElevation = baroFusedAltitude - tiltCorrectedStickHeight + baroDriftCorrection + geoidCorrection
```

### Step 6: DEM Interpolation (§13)

### Step 7: Mesh Triangulation
Delaunay triangulation of the point cloud → triangle mesh. Using the `CGAL` algorithm port or a pure Swift implementation of the Bowyer-Watson algorithm.

### Step 8: Contour Generation
March over the DEM grid using marching squares to generate contour polylines at specified intervals (e.g., every 0.5m, 1m, or 2m depending on elevation range).

### Step 9: Export Package Generation (§15)

---

## 13. Interpolation & DEM Generation

### 13.1 Grid Setup

The output DEM is a regular grid. Cell size is chosen based on average point spacing:
```swift
func chooseCellSize(points: [SurveyPoint]) -> Double {
    let avgSpacing = averageNearestNeighborDistance(points)
    // Cell size = half the average spacing, minimum 0.25m, maximum 5.0m
    return max(0.25, min(5.0, avgSpacing / 2.0))
}
```

### 13.2 IDW (Inverse Distance Weighting)

For each grid cell center, elevation is computed as:
```
z(p) = Σ(wᵢ × zᵢ) / Σ(wᵢ)
where wᵢ = confidenceScore_i / distance(p, pᵢ)^power
```
- `power = 2` (standard IDW)
- Search radius = 3 × cellSize
- Minimum 3 points required within search radius; otherwise mark as `noData`

**Confidence weighting:** Each point's `confidenceScore` (§7.4) is multiplied into the distance weight. A high-confidence nearby point outweighs a low-confidence slightly closer point.

### 13.3 Kriging (Optional Upgrade)

If point count > 50 and spatial distribution is adequate, use ordinary kriging with a spherical variogram model. Kriging provides an interpolation variance estimate per cell — cells with high variance are flagged in the output. This is computationally heavier (~10–30s for 200 points on iPhone 16 Pro) but gives statistically optimal estimates.

A pre-computed variogram:
```
γ(h) = nugget + sill × [1.5(h/range) - 0.5(h/range)³]  for h ≤ range
γ(h) = nugget + sill                                      for h > range
```
Parameters (nugget, sill, range) are fit by least-squares to the empirical variogram of the session data.

### 13.4 DEM Smoothing

Apply a Gaussian kernel with σ = 1.5 cells to the final DEM to reduce interpolation artifacts. Preserve the original unsmoothed DEM as well (both exported).

---

## 14. ARKit Local Mesh Layer

### 14.1 What This Provides

At each stored point, ARKit has been continuously building a scene mesh via `ARWorldTrackingConfiguration.sceneReconstruction = .mesh`. The mesh within a ~3m radius of a stored point has centimeter-level **relative** accuracy. The GPS position of the stored point gives it **global** (absolute) coordinates.

By assembling all the local meshes and georeferencing each via its GPS anchor, a hybrid product is created:
- **Global accuracy:** ±1–2m (GPS-limited)
- **Local relative accuracy:** ±2–5cm (LiDAR mesh)
- **Result:** A richly detailed terrain mesh with accurate local shape, correctly placed in global coordinates

### 14.2 Mesh Capture at Point Storage

```swift
func captureMeshAtPoint(session: ARSession, anchor: SurveyPoint) {
    let currentMeshAnchors = session.currentFrame?.anchors
        .compactMap { $0 as? ARMeshAnchor } ?? []

    // Filter to anchors within 3m of the stored point (ARKit world coords)
    let nearbyAnchors = currentMeshAnchors.filter { meshAnchor in
        let pos = meshAnchor.transform.columns.3
        let dist = distance(SIMD3(pos.x, pos.y, pos.z),
                           anchor.arkitWorldPosition ?? .zero)
        return dist < 3.0
    }

    // Snapshot the geometry of nearby anchors
    let geometrySnapshots = nearbyAnchors.map { ($0.identifier, $0.geometry.snapshot()) }
    // Store snapshots linked to this SurveyPoint
}
```

### 14.3 Mesh Georeferencing

Each ARKit mesh anchor has coordinates in ARKit's world coordinate system (origin = wherever ARKit session started). To convert to GPS coordinates:

1. At the stored point, we have:
   - `arkitWorldPosition`: ARKit coords of the phone at capture time
   - `latitude, longitude`: GPS coords of that same location

2. The transform from ARKit world space to GPS space is estimated by collecting 5+ stored points and fitting a rigid-body transform (translation + scale + rotation) using least-squares.

3. This transform is applied to all mesh vertices to produce GPS-referenced mesh coordinates.

**Caveat:** ARKit VIO drifts over large surveys. For surveys > 50m extent, the mesh stitching introduces increasing error. Over a 100m × 100m survey, expect ±0.5–1.5m mesh positioning error at the periphery. The mesh is most useful for local terrain texture, not absolute positioning.

---

## 15. Export Formats

### 15.1 PLY (Point Cloud)
ASCII or binary PLY file with per-point attributes:
```
ply
format ascii 1.0
element vertex N
property float x        // longitude-offset in meters (local origin)
property float y        // latitude-offset in meters (local origin)
property float z        // elevation (ground elevation)
property float confidence
property float gps_accuracy
property uchar red      // elevation-colorized
property uchar green
property uchar blue
end_header
...data...
```
Compatible with CloudCompare, MeshLab, QGIS, Blender.

### 15.2 LAS 1.4 (Geospatial Point Cloud)
Standard geospatial LiDAR format. Points encoded with:
- X, Y, Z as scaled integers (scale: 0.001m precision)
- GPS week time
- Classification: 2 = Ground, 0 = Unclassified
- Point Source ID: session identifier

Header includes WGS84 coordinate reference system (EPSG:4326) definition.
Compatible with QGIS, ArcGIS, PDAL, CloudCompare.

### 15.3 GeoJSON (Point Collection)
```json
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "geometry": { "type": "Point", "coordinates": [lon, lat, elevation] },
      "properties": {
        "index": 1,
        "groundElevation": 123.45,
        "confidence": 0.92,
        "gpsSamples": 4,
        "lidarMeasured": true,
        "tiltDegrees": 1.2,
        "timestamp": "2024-03-01T10:32:15Z"
      }
    }
  ]
}
```

### 15.4 GeoTIFF (DEM Raster)
Single-band float32 GeoTIFF with:
- Projection: WGS84 geographic (EPSG:4326) or UTM (user choice)
- NoData value: -9999.0
- Band 1: elevation in meters
- Metadata: session ID, date, accuracy estimate

Generated using a minimal GeoTIFF encoder (no external library needed; GeoTIFF is a TIFF with geo-tags — implementable in ~300 lines of Swift).

### 15.5 OBJ / USDZ (3D Mesh)
Triangulated mesh for visualization in:
- Blender, Cinema 4D (OBJ)
- Reality Composer Pro, Quick Look, Xcode (USDZ)
- Vertex colors encode elevation with a terrain colormap

### 15.6 CSV (Raw Data)
Full session data dump:
```
index,latitude,longitude,groundElevation,gpsAltitude,gpsAccuracy,baroRelative,lidarDist,tiltDeg,confidence,timestamp
1,41.6941,44.8337,523.42,525.03,2.8,0.00,1.487,0.8,0.94,2024-03-01T10:32:15Z
...
```

---

## 16. UI/UX Architecture

### 16.1 Screen Flow

```
LaunchScreen
└── MainMenuView
    ├── NewSessionView (setup)
    │   ├── StickHeightInputView (numeric input + AR measurement assist)
    │   └── GPSWarmupView (wait for good fix)
    ├── ActiveSessionView (main capture screen)
    │   ├── LiveMapView (MapKit, all stored points overlaid)
    │   ├── StatusBarView (GPS accuracy, baro, KF estimate, tilt indicator)
    │   ├── StorePointButton (large, contextual state display)
    │   ├── PointCounterView
    │   └── NearestPointDistanceView (live ring visualization)
    ├── PointCaptureOverlayView (full-screen during countdown)
    │   ├── TiltMeterView (spirit level analog display)
    │   ├── CountdownRingView (resets on motion)
    │   ├── GPSQualityView (live accuracy + sample count)
    │   ├── LiDARReadingView (live depth measurement)
    │   └── AcceptRejectView (result)
    ├── ProcessingView (post-session)
    │   └── StepProgressView (7 processing steps)
    ├── ResultsView
    │   ├── 3DTerrainView (SceneKit mesh, touch to rotate)
    │   ├── ContourMapView (MapKit + contour overlay)
    │   ├── PointCloudView (SceneKit scatter)
    │   ├── StatisticsView (accuracy metrics, point count, coverage)
    │   └── ExportView (format selection + share sheet)
    └── SessionHistoryView (past sessions, load & compare)
```

### 16.2 LiveMapView

Built on `MapKit` with `MKMapView` (or `Map` in SwiftUI).

- Background: satellite imagery (`MKMapType.satellite`)
- Each `SurveyPoint` rendered as an `MKAnnotation` with:
  - Color: elevation-coded (cool blue = low, warm red = high), scale set at end of session
  - Size: proportional to confidence score
  - Ring: dashed circle showing 1m radius (helps user maintain spacing)
- Live position: pulsing blue dot (standard)
- PDR track: thin white polyline (shows inferred path between GPS fixes)
- Nearest point distance: displayed as text overlay + arc on map
- "Coverage heat" overlay: semitransparent polygon showing area covered (convex hull of stored points)

### 16.3 TiltMeterView (Spirit Level)

A circular spirit level visualization rendered in SwiftUI Canvas:
- Bubble position computed from `CMDeviceMotion.gravity.x` and `.y`
- Green zone: ≤ 3° radius (ideal)
- Yellow zone: 3–5° (acceptable, slight penalty)
- Red zone: > 5° (countdown halted)
- Target crosshair at center
- Numerical readout in degrees

### 16.4 Point Proximity Visualization

As the user walks, a distance arc shows the direction and distance to the nearest stored point:
```swift
// Compute bearing + distance to nearest stored point
let (bearing, distance) = nearestPoint(from: currentLocation, in: storedPoints)

// Display a colored arc with an arrowhead on the map edge
// Color: green (<1.5m, too close), yellow (1.5–3m, good), blue (>3m, getting far)
```

This is the key UX affordance that helps the user walk an optimal survey pattern without looking at a grid.

### 16.5 StatusBar (Active Session)

Persistent HUD showing:
```
GPS: 2.1m ↕  BARO: +1.23m  KF: 523.4m  TILT: 1.2°  POINTS: 14  DURATION: 12:34
```

---

## 17. Swift Technology Stack & APIs

### Frameworks
| Framework | Purpose |
|---|---|
| `CoreLocation` | GPS, heading |
| `CoreMotion` | IMU, barometer, device motion |
| `ARKit` | LiDAR depth, scene mesh, VIO |
| `RealityKit` | Mesh rendering, optional photogrammetry |
| `MapKit` | Live map, survey visualization |
| `SceneKit` | 3D terrain mesh visualization |
| `SwiftUI` | All UI |
| `Combine` | Reactive sensor data pipelines |
| `Accelerate` | Matrix operations (Kalman filter) |
| `CoreData` | Session persistence |
| `UniformTypeIdentifiers` | Export file type declarations |

### Key API Details

**`CMMotionManager` — use one instance app-wide (singleton), shared across all consumers**

**`ARWorldTrackingConfiguration` setup for LiDAR:**
```swift
let config = ARWorldTrackingConfiguration()
config.sceneReconstruction = .mesh
config.frameSemantics = [.sceneDepth, .smoothedSceneDepth] // smoothed for stability
config.worldAlignment = .gravityAndHeading // aligns ARKit Y to gravity, Z to north
arSession.run(config)
```

**Barometer sample rate:** `CMAltimeter` delivers updates approximately once per second. This is not configurable — it is a fixed hardware reporting rate.

**GPS background updates:** Enable `Background Modes > Location updates` in entitlements. Use:
```swift
locationManager.allowsBackgroundLocationUpdates = true
locationManager.pausesLocationUpdatesAutomatically = false
```

**`Accelerate` for Kalman filter:** Use `simd_double3x3` for the 3×3 covariance matrix operations. The `Accelerate` framework provides BLAS/LAPACK routines for matrix inversion needed in the Kalman gain computation.

---

## 18. File & Storage Architecture

### 18.1 Directory Structure
```
Documents/
└── TerrainMapper/
    ├── sessions/
    │   └── {sessionUUID}/
    │       ├── session_metadata.json       // SurveySession struct
    │       ├── survey_points.json          // [SurveyPoint] array
    │       ├── raw_log.bin                 // binary packed RawSample stream
    │       ├── arkit_meshes/
    │       │   ├── {anchorUUID}.usda       // per-point ARKit mesh snapshot
    │       │   └── ...
    │       └── exports/
    │           ├── {sessionUUID}_points.ply
    │           ├── {sessionUUID}_points.geojson
    │           ├── {sessionUUID}_dem.tiff
    │           ├── {sessionUUID}_mesh.obj
    │           └── {sessionUUID}_raw.csv
    └── calibrations/
        └── user_calibration.json           // stick height, step length K, etc.
```

### 18.2 Raw Log Format (binary)

Each `RawSample` is packed as 128 bytes in a binary log file for efficient storage. At 10Hz and 128 bytes/sample, a 30-minute session generates:
```
10 × 60 × 30 × 128 = 2.3 MB
```
Very compact — no concern about storage.

Binary packing uses `Data` with `withUnsafeBytes` / `withUnsafeMutableBytes` for zero-copy serialization.

### 18.3 CoreData Schema

`NSPersistentContainer` for session index (searchable list of past sessions without loading full data):
- `SessionEntity`: id, startDate, endDate, pointCount, boundsWKT, isProcessed
- `ExportLogEntity`: sessionID, format, exportDate, fileSize

---

## 19. Accuracy Audit — What Gets You to Sub-0.5m

This section is a critical self-check. We claim ±0.3–0.5m relative vertical accuracy. Here is the precise argument for each component.

### 19.1 What "Relative Accuracy" Means Here

When comparing two nearby stored points A and B, the elevation difference `z_B - z_A` has an uncertainty. The claim is that this uncertainty is ±0.2–0.4m (1σ) when:
- Points are stored correctly (stationary, upright, 3-second window)
- LiDAR is operational
- Barometric data is available

This is relative to the survey area, not to any external datum.

### 19.2 The Dominant Remaining Error: Absolute GPS Anchor

The **absolute** altitude of the model (e.g., "the ridge is at 523.4m MSL") is bounded by GPS accuracy at ±1–2m even after averaging. For terrain shape analysis, this doesn't matter — you care about the shape, not the absolute number.

### 19.3 Why LiDAR Is The Key Enabler

Without LiDAR, the stick height is a human-measured constant (±1–3cm measurement error, but zero knowledge of vegetation offset, stick sinking, etc.). With LiDAR, every stored point has a precisely measured `lidarMeasuredDistance` (±2–4cm at 1.5m range) that automatically corrects for:
- Exact stick position (variable between points)
- Slight stick compression/extension under weight
- Mounting variations

This converts a systematic unknown into a per-point measured variable, which is a qualitative accuracy improvement.

### 19.4 Why the Barometer Is The Key Enabler Between Points

GPS altitude noise is ~±3–5m per fix. The Kalman filter fuses GPS with the barometer, and between GPS updates, the barometer drives the altitude estimate. The barometer's relative altitude resolution of ~0.1m means that if you store two points 10m apart horizontally, the **elevation difference between them** is determined primarily by the barometer delta, not the GPS. This is the mechanism that achieves sub-0.5m *relative* accuracy despite GPS being ±1–2m absolute.

The math:
- GPS contribution to relative error between adjacent points: ~±0.2–0.5m (correlation helps — same atmospheric conditions for both fixes)
- Barometer contribution to relative error: ~±0.05–0.15m
- After Kalman fusion: ~±0.1–0.3m (the barometer dominates for relative measurement)

### 19.5 Conditions for Best Results

| Condition | Effect |
|---|---|
| Open sky, no buildings or tree canopy | Best GPS accuracy |
| Stable weather (no pressure fronts) | Minimal baro drift |
| Short sessions (< 45 minutes) | Less baro drift accumulation |
| Slow, careful movement; 2.5–3s holds | Better GPS averaging |
| Consistent 1–2m point spacing | Good interpolation confidence |
| LiDAR active (phone mounted correctly) | Precise stick height per point |
| Loop closure at end of session | Drift correction applied |
| < 10° tilt during point capture | Negligible tilt error |

---

## 20. Known Limitations & Honest Caveats

### 20.1 Absolute vs. Relative Accuracy
**Sub-0.5m relative accuracy is achievable. Sub-0.5m absolute accuracy is not achievable with this system.** For terrain shape analysis, only relative accuracy matters. For integrating with external datasets (DEM comparison, surveying to a datum), expect ±1–2m absolute uncertainty.

### 20.2 LiDAR in Bright Sunlight
iPhone LiDAR uses infrared light. In direct sunlight, ambient IR noise can degrade readings beyond 1.5m. At stick height (0.8–1.5m), performance is typically adequate, but on bright sunny days, readings will have more noise. The system falls back to configured stick height automatically if LiDAR quality is insufficient.

### 20.3 Vegetation
LiDAR measures the **surface it illuminates first** — long grass, vegetation, or loose surface materials produce a reading to the top of the vegetation, not bare earth. In dense grass (>5cm), add ~3–10cm systematic elevation bias. This cannot be corrected without multi-return LiDAR. Document the vegetation type when recording sessions.

### 20.4 ARKit World Tracking Drift
Over surveys larger than ~50m, ARKit VIO drift accumulates. The mesh stitching has ±0.5–2m positional uncertainty at the periphery of large surveys. This affects the **visual quality** of the stitched mesh but not the numerical point cloud accuracy (which is GPS-anchored per point).

### 20.5 Barometric Sensitivity to Wind
A brisk wind across the barometric vent can cause momentary pressure fluctuations that register as 0.1–0.5m altitude spikes. The Kalman filter smooths these, but in very windy conditions, baro accuracy degrades. Shield the phone from direct wind gusts where possible, especially during point captures.

### 20.6 Magnetic Interference for PDR
Metal objects, power lines, reinforced concrete, or even a metal stick can corrupt magnetometer readings and degrade PDR heading. The app flags `headingAccuracy > 20°` and falls back to GPS-only positioning for affected segments.

### 20.7 Minimum Point Requirements
Reliable DEM generation requires:
- Minimum 10 stored points for any interpolation
- Minimum 1 point per ~4–9 m² of surveyed area for 0.5m cell DEM
- Coverage of all terrain features of interest (ridges, valleys, edges must have points)

The user must survey methodically — a random sparse scatter of 5 points produces a poor model regardless of per-point accuracy.

### 20.8 iOS Privacy Requirements
The app requires explicit user authorization for:
- Location (Always, for background logging): `NSLocationAlwaysAndWhenInUseUsageDescription`
- Motion & Fitness: `NSMotionUsageDescription`
- Camera (for ARKit): `NSCameraUsageDescription`

---

*Document version 1.0 — Architecture specification for TerrainMapper iOS app*
*Target device: iPhone 16 Pro (minimum iPhone 15 Pro for LiDAR; degrades gracefully on non-LiDAR devices)*
