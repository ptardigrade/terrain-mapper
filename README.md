# TerrainMapper

An iOS app for high-accuracy ground-elevation surveying using sensor fusion: GPS, LiDAR, barometer, and IMU.

## Requirements

- **Mac with Xcode 15+** (required to build and deploy iOS apps)
- **iPhone 12 Pro or later** (LiDAR scanner required)
- **iOS 17.0+** on the target device

## Opening the Project

1. Copy the entire `Terrain Mapper` folder to your Mac.
2. Double-click `TerrainMapper.xcodeproj` to open in Xcode.
3. Select your development team under **Signing & Capabilities** (TerrainMapper target → Signing).
4. Connect your iPhone, select it as the run destination.
5. Press **⌘R** to build and run.

> **Note:** The LiDAR and motion sensors are not available in the iOS Simulator. You must run on a physical device.

---

## Architecture

### Sensor Fusion Core

All sensor managers live under `TerrainMapper/Core/SensorFusion/` and are coordinated by `SensorFusionEngine`.

```
SensorFusionEngine
├── KalmanFilter        — fuses GPS altitude + barometer into a single estimate
├── IMUManager          — tilt angle + stationary gate from accelerometer/gyro
├── BarometerManager    — relative altitude stream + loop-closure drift correction
├── LiDARManager        — ARKit depth capture (90-frame median, tilt-corrected)
└── GPSManager          — CoreLocation stream + pedestrian dead reckoning (PDR)
```

### Kalman Filter (3-state)

State vector: `[altitude, vertical_velocity, baro_bias]`

| State | Description |
|-------|-------------|
| `x[0]` | Altitude (m, WGS-84 ellipsoid) |
| `x[1]` | Vertical velocity (m/s) |
| `x[2]` | Barometer bias (m) — slow drift |

**Predict** is called every ~1 s using the barometric delta as a control input.
**GPS update** (H = [1, 0, 0], R = 25 m²) anchors the absolute altitude.
**Baro update** (H = [1, 0, -1], R = 0.01 m²) provides high-frequency precision.

### Point Capture Sequence

1. **Stationary gate** — IMU variance < 0.005 g² over 30 samples (≈1 s)
2. **Barometer** — snapshot current relative altitude delta
3. **LiDAR** — 90-frame depth median sampled from central 20% ROI
4. **Tilt correction** — `vertical = slant × cos(θ)` using IMU gravity vector
5. **GPS** — current location (or PDR estimate if no fresh fix)
6. **Kalman update** — GPS altitude fed into filter if fix is < 5 s old
7. **Assemble** `SurveyPoint` — `groundElevation = fusedAltitude − lidarDistance`

### Loop-Closure Drift Correction

If the operator returns within 10 m of the session start point, `BarometerManager.applyLoopClosure()` distributes the observed barometric drift linearly across all recorded points, removing the low-frequency pressure drift component.

### Outlier Detection

`SurveySession.detectOutliers()` uses **Median Absolute Deviation (MAD)** to flag points whose ground elevation deviates more than 3σ from the median.  MAD is robust to the very outliers being detected (unlike standard deviation).

---

## Data Model

### `SurveyPoint`

| Field | Type | Description |
|-------|------|-------------|
| `latitude / longitude` | Double | WGS-84 coordinates |
| `fusedAltitude` | Double | Kalman-estimated altitude (m) |
| `lidarDistance` | Double | Tilt-corrected vertical distance to ground (m) |
| `groundElevation` | Double | `fusedAltitude − lidarDistance` (m) |
| `baroAltitudeDelta` | Double | Relative baro height since session start (m) |
| `tiltAngle` | Double | Device tilt from vertical (radians) |
| `isOutlier` | Bool | Flagged by post-processing outlier pass |

### `SurveySession`

Holds the ordered array of `SurveyPoint`s plus configuration: `stickHeight` (fallback when LiDAR is unavailable) and `geoidOffset` (EGM96 undulation for AMSL conversion).

---

## Extending the App

The `ContentView.swift` is a minimal scaffold.  Suggested next steps:

- **Map view** — render `SurveyPoint` coordinates on `MapKit` / `MKMapView`
- **DEM interpolation** — triangulate points into a mesh (Delaunay / TIN)
- **Export** — serialize `SurveySession` to GeoJSON, CSV, or DXF
- **Stick-height config** — let the operator enter stick height before session start
- **Geoid lookup** — integrate an EGM96 grid to convert ellipsoidal → AMSL elevation
- **Bluetooth stick** — pair with a smart survey pole for automated height reading

---

## Permissions Required

The app requests the following permissions at runtime:

| Permission | Purpose |
|-----------|---------|
| Location (when in use) | GPS coordinates for survey points |
| Motion & Fitness | Accelerometer, gyroscope, barometer, pedometer |
| Camera | LiDAR scanner access via ARKit |

These are declared in `Info.plist` with human-readable usage descriptions.

---

## Project Structure

```
Terrain Mapper/
├── README.md
├── TerrainMapper.xcodeproj/
│   └── project.pbxproj
└── TerrainMapper/
    ├── TerrainMapperApp.swift
    ├── Info.plist
    ├── Core/
    │   ├── SensorFusion/
    │   │   ├── KalmanFilter.swift
    │   │   ├── BarometerManager.swift
    │   │   ├── LiDARManager.swift
    │   │   ├── IMUManager.swift
    │   │   ├── GPSManager.swift
    │   │   └── SensorFusionEngine.swift
    │   └── Models/
    │       ├── SurveyPoint.swift
    │       └── SurveySession.swift
    └── Views/
        └── ContentView.swift
```
