# TerrainMapper — Claude Code Guide

## Project
iOS app (Swift/SwiftUI) for terrain surveying using iPhone sensors (GPS, LiDAR, IMU, barometer).
Target: iOS 17+, iPhone only.

## Build & Deployment
- **No Mac available** — builds run via GitHub Actions (free macOS runners)
- Workflow: `.github/workflows/build.yml` — triggers on every push to `master`
- Output: unsigned IPA artifact, downloaded from Actions tab and installed via **Sideloadly** on Windows
- Sideloadly re-signs using Apple ID: lukabakhsoliani@gmail.com (free Personal Team)
- App re-sign expires every 7 days — just re-run Sideloadly with same IPA

## Critical Rules
1. **Always verify the Xcode project file** (`TerrainMapper.xcodeproj/project.pbxproj`) includes any new `.swift` files you create. New files must be added to:
   - `PBXBuildFile` section
   - `PBXFileReference` section
   - The correct `PBXGroup` (Views, SensorFusion, Processing, Export, etc.)
   - `PBXSourcesBuildPhase` files list
   Failure to do this causes `cannot find 'X' in scope` errors in CI even though the file exists.

2. **Test compilability before pushing** — the CI build is the only build system available. A broken push = broken app.

3. **Known Swift constraints** in this codebase:
   - Use `fileprivate(set)` instead of `private(set)` when a nested private class needs to write the property
   - `withUnsafeBytes` must use the Swift module-qualified form or explicit type annotations
   - Ad-hoc signing (`CODE_SIGN_IDENTITY="-"`) is blocked by iOS 18 SDK — use `CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` instead

## Repo
GitHub: https://github.com/ptardigrade/terrain-mapper
Branch: master

## Project Structure
```
TerrainMapper/
├── Core/
│   ├── Export/          # PLY, LAS, GeoJSON, GeoTIFF, OBJ, CSV exporters
│   ├── Models/          # SurveyPoint, SurveySession
│   ├── Persistence/     # SessionStore
│   ├── Processing/      # TerrainInterpolator, MeshGenerator, ContourGenerator, etc.
│   └── SensorFusion/    # KalmanFilter, GPS/IMU/LiDAR/Barometer managers, PathTrackRecorder
└── Views/               # ContentView, SurveyView, ResultsView, SettingsView, Theme, etc.
```
