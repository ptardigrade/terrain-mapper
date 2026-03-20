// SurveyView.swift
// TerrainMapper
//
// Live survey screen.  Shows a satellite map with captured points overlaid as
// elevation-coloured circles, and a bottom panel with sensor status + controls.
//
// Layout:
//   ┌──────────────────────────────────┐
//   │  Top bar: session title + End    │
//   ├──────────────────────────────────┤
//   │                                  │
//   │    MKMapView (satellite)         │
//   │    • captured points as circles  │
//   │    • colour gradient by elev     │
//   │                                  │
//   ├──────────────────────────────────┤
//   │  Bottom panel (sheet-style)      │
//   │  Spirit level | GPS | Baro | Alt │
//   │  [────── Capture Point ──────]   │
//   │  N points · HH:MM:SS elapsed     │
//   └──────────────────────────────────┘

import SwiftUI
import MapKit
import CoreLocation

struct SurveyView: View {

    // MARK: - Inputs

    var onSessionEnded: (SurveySession) -> Void

    // MARK: - Dependencies

    @EnvironmentObject private var engine:       SensorFusionEngine
    @EnvironmentObject private var settings:     AppSettings
    @EnvironmentObject private var sessionStore: SessionStore

    // MARK: - State

    @State private var capturedPoints:        [SurveyPoint] = []
    @State private var pathTrackCoordinates:  [CLLocationCoordinate2D] = []
    @State private var cameraPosition:        MapCameraPosition = .automatic
    @State private var isCapturing:           Bool = false
    @State private var captureError:     String?
    @State private var showError:        Bool = false
    @State private var elapsedSeconds:   Int = 0
    @State private var sessionStarted:   Bool = false
    @State private var showLiDARFallbackAlert: Bool = false
    @State private var showEndWarning: Bool = false
    @State private var sessionName:      String = ""
    @State private var showNameSheet:    Bool   = false

    // Elevation range for colour mapping (updated as points arrive)
    @State private var elevMin: Double = 0
    @State private var elevMax: Double = 1

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Map ───────────────────────────────────────────────────
                Map(position: $cameraPosition) {
                    ForEach(capturedPoints) { point in
                        Annotation("", coordinate: point.clCoordinate) {
                            SurveyPointMarker(
                                elevation: point.groundElevation,
                                elevMin:   elevMin,
                                elevMax:   elevMax,
                                isOutlier: point.isOutlier
                            )
                        }
                    }
                    // Survey path polyline (explicit captures)
                    if capturedPoints.count >= 2 {
                        MapPolyline(coordinates: capturedPoints.map(\.clCoordinate))
                            .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                    }
                    // Passive GPS path-track breadcrumbs — faint teal trail
                    if pathTrackCoordinates.count >= 2 {
                        MapPolyline(coordinates: pathTrackCoordinates)
                            .stroke(.teal.opacity(0.45), style: StrokeStyle(lineWidth: 1.5))
                    }
                }
                .mapStyle(.imagery(elevation: .realistic))
                .mapControls {
                    MapCompass()
                    MapUserLocationButton()
                }
                .ignoresSafeArea(edges: .top)

                // ── Bottom panel ──────────────────────────────────────────
                VStack(spacing: 0) {
                    Divider()
                    sensorStatusRow
                        .padding(.horizontal)
                        .padding(.top, 12)
                    captureButton
                        .padding(.horizontal)
                        .padding(.top, 10)
                    sessionFooter
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                }
                .background(.regularMaterial)
            }
            .navigationTitle(sessionStarted ? "Surveying" : "Ready to Survey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !sessionStarted {
                        Button("Start") { showNameSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if sessionStarted && !capturedPoints.isEmpty {
                        Button {
                            if let removed = engine.undoLastPoint() {
                                capturedPoints.removeAll { $0.id == removed.id }
                                let all = capturedPoints.map(\.groundElevation)
                                elevMin = all.min() ?? 0
                                elevMax = max(elevMin + 0.01, all.max() ?? 1)
                            }
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if capturedPoints.count >= 2 {
                        Button {
                            fitMapToPoints()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if sessionStarted {
                        Button("End Survey") { checkEndSession() }
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            if sessionStarted { elapsedSeconds += 1 }
        }
        .onReceive(engine.$latestPathTrackPoint.compactMap { $0 }) { point in
            pathTrackCoordinates.append(point.clCoordinate)
        }
        .alert("Capture Error", isPresented: $showError, presenting: captureError) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in Text(msg) }
        .alert("LiDAR Unavailable", isPresented: $showLiDARFallbackAlert) {
            Button("Use Stick Height") {
                Task { await captureWithStickHeight() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Depth data could not be read (reflective or sunlit surface). Use the configured stick height (\(String(format: "%.1f", settings.stickHeight)) m) instead?")
        }
        .alert("Too Few Points", isPresented: $showEndWarning) {
            Button("End Anyway", role: .destructive) { endSession() }
            Button("Keep Surveying", role: .cancel) {}
        } message: {
            Text("You have \(capturedPoints.count) point\(capturedPoints.count == 1 ? "" : "s"). At least 6 are recommended for accurate terrain modelling.")
        }
        .sheet(isPresented: $showNameSheet) {
            NavigationStack {
                Form {
                    Section {
                        TextField("e.g. Front paddock, North fence line…", text: $sessionName)
                            .autocorrectionDisabled(false)
                    } header: {
                        Text("Session Name (optional)")
                    } footer: {
                        Text("Leave blank to auto-name by date and time.")
                    }
                }
                .navigationTitle("New Survey Session")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { showNameSheet = false }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Start") {
                            showNameSheet = false
                            startSession()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - Sensor status row

    private var sensorStatusRow: some View {
        HStack(spacing: 0) {
            // Spirit level
            TiltMeterView(
                tiltAngle: engine.tiltAngleDegrees * .pi / 180,
                gravityX:  engine.gravityX,
                gravityY:  engine.gravityY,
                isStationary: engine.imuIsStationary,
                stationaryProgress: engine.stationaryProgress
            )
            .frame(width: 80)

            Divider().frame(height: 60)

            // GPS
            VStack(spacing: 3) {
                Image(systemName: "location.fill")
                    .foregroundStyle(gpsColor)
                Text("GPS")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("±\(Int(engine.gpsAccuracy)) m")
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(gpsColor)
            }
            .frame(maxWidth: .infinity)

            Divider().frame(height: 60)

            // IMU
            VStack(spacing: 3) {
                Image(systemName: engine.imuIsStationary ? "checkmark.circle.fill" : "waveform.path")
                    .foregroundStyle(engine.imuIsStationary ? .green : .orange)
                Text("MOTION")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(engine.imuIsStationary ? "STILL" : "MOVING")
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(engine.imuIsStationary ? .green : .orange)
            }
            .frame(maxWidth: .infinity)

            Divider().frame(height: 60)

            // Altitude
            VStack(spacing: 2) {
                Image(systemName: "arrow.up.and.down")
                    .foregroundStyle(.blue)
                Text("ALT")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(String(format: "%.1f m", engine.currentAltitude))
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.blue)
                Text(String(format: "±%.1f", engine.altitudeUncertainty))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.blue.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Capture button

    /// True when GPS accuracy is too poor to record a reliable position (>30 m).
    private var gpsTooInaccurate: Bool { engine.gpsAccuracy > 30 }

    private var captureButton: some View {
        Button(action: { Task { await capturePoint() } }) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(captureButtonColor)
                HStack(spacing: 10) {
                    if isCapturing {
                        VStack(spacing: 6) {
                            Text("Sampling LiDAR…")
                                .font(.headline).foregroundStyle(.white)
                            ProgressView(value: engine.lidarCaptureProgress)
                                .progressViewStyle(.linear)
                                .tint(.white)
                                .frame(maxWidth: 200)
                        }
                    } else if gpsTooInaccurate {
                        Image(systemName: "location.slash.fill")
                            .foregroundStyle(.white)
                        Text("Weak GPS — Move to open sky")
                            .font(.headline).foregroundStyle(.white)
                    } else if !engine.imuIsStationary {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.white)
                        Text("Hold Steady")
                            .font(.headline).foregroundStyle(.white)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3).foregroundStyle(.white)
                        Text("Capture Point")
                            .font(.headline).foregroundStyle(.white)
                    }
                }
                .padding(.vertical, 14)
            }
        }
        .disabled(!sessionStarted || isCapturing || !engine.isSessionActive || gpsTooInaccurate)
        .animation(.easeInOut(duration: 0.2), value: isCapturing)
        .animation(.easeInOut(duration: 0.2), value: engine.imuIsStationary)
        .animation(.easeInOut(duration: 0.3), value: gpsTooInaccurate)
    }

    private var captureButtonColor: Color {
        if isCapturing             { return .blue }
        if gpsTooInaccurate        { return .red.opacity(0.8) }
        if !engine.imuIsStationary { return .orange }
        return .blue
    }

    // MARK: - Session footer

    private var sessionFooter: some View {
        HStack {
            Label("\(capturedPoints.count) point\(capturedPoints.count == 1 ? "" : "s")",
                  systemImage: "mappin")
                .font(.caption).foregroundStyle(.secondary)

            // Live elevation range — appears once we have ≥ 2 points
            if capturedPoints.count >= 2 {
                Spacer()
                Text(liveElevationRange)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Label(formattedElapsed, systemImage: "clock")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var liveElevationRange: String {
        String(format: "↕ %.1f–%.1f m", elevMin, elevMax)
    }

    private var formattedElapsed: String {
        let h = elapsedSeconds / 3600
        let m = (elapsedSeconds % 3600) / 60
        let s = elapsedSeconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private var gpsColor: Color {
        let acc = engine.gpsAccuracy
        if acc <= 8  { return .green }
        if acc <= 20 { return .yellow }
        return .red
    }

    // MARK: - Actions

    private func startSession() {
        capturedPoints       = []
        pathTrackCoordinates = []
        elapsedSeconds = 0
        elevMin = 0; elevMax = 1
        engine.startSession(stickHeight: settings.stickHeight, name: sessionName)
        sessionStarted = true
    }

    private func endSession() {
        let session = engine.endSession()
        sessionStarted = false
        sessionStore.archive(session: session)
        onSessionEnded(session)
    }

    private func checkEndSession() {
        if capturedPoints.count < 6 {
            showEndWarning = true
        } else {
            endSession()
        }
    }

    private func fitMapToPoints() {
        guard !capturedPoints.isEmpty else { return }
        let lats = capturedPoints.map(\.latitude)
        let lons = capturedPoints.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        let spanLat = max(0.001, (maxLat - minLat) * 1.5)
        let spanLon = max(0.001, (maxLon - minLon) * 1.5)
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
            ))
        }
    }

    private func capturePoint() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        do {
            let point = try await engine.capturePoint()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            capturedPoints.append(point)

            // Persist incrementally after every successful capture
            if let snapshot = engine.currentSessionSnapshot {
                sessionStore.save(session: snapshot)
            }

            // Update elevation range
            let all = capturedPoints.map(\.groundElevation)
            elevMin = all.min() ?? 0
            elevMax = max(elevMin + 0.01, all.max() ?? 1)

            // Re-centre map on the new point
            let coord = CLLocationCoordinate2D(latitude: point.latitude,
                                               longitude: point.longitude)
            withAnimation {
                cameraPosition = .region(MKCoordinateRegion(
                    center: coord,
                    latitudinalMeters: 100, longitudinalMeters: 100
                ))
            }
        } catch SensorFusionError.lidarCaptureFailed(let inner) {
            if case LiDARError.depthDataUnavailable = inner {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                showLiDARFallbackAlert = true
                return
            }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            captureError = SensorFusionError.lidarCaptureFailed(inner).localizedDescription
            showError = true
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            captureError = error.localizedDescription
            showError    = true
        }
    }

    private func captureWithStickHeight() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        // Build a point using GPS + stick height instead of LiDAR
        guard let location = engine.gpsManager.currentLocation else {
            captureError = "No GPS location available."
            showError = true
            return
        }
        let fusedAlt = engine.currentAltitude
        let groundElev = fusedAlt - settings.stickHeight
        let point = SurveyPoint(
            id:                  UUID(),
            timestamp:           Date(),
            latitude:            location.coordinate.latitude,
            longitude:           location.coordinate.longitude,
            fusedAltitude:       fusedAlt,
            groundElevation:     groundElev,
            lidarDistance:       settings.stickHeight,
            gpsAltitude:         location.altitude,
            baroAltitudeDelta:   engine.barometerManager.currentRelativeAltitude,
            tiltAngle:           engine.imuManager.tiltAngle,
            horizontalAccuracy:  location.horizontalAccuracy,
            verticalAccuracy:    max(location.verticalAccuracy, 0),
            captureType:         .stickHeight
        )
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        engine.appendPoint(point)
        capturedPoints.append(point)
        // Persist after stick-height fallback capture
        if let snapshot = engine.currentSessionSnapshot {
            sessionStore.save(session: snapshot)
        }
        let all = capturedPoints.map(\.groundElevation)
        elevMin = all.min() ?? 0
        elevMax = max(elevMin + 0.01, all.max() ?? 1)
        let coord = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(
                center: coord, latitudinalMeters: 100, longitudinalMeters: 100
            ))
        }
    }

}

// MARK: - Supporting views

private struct SurveyPointMarker: View {
    let elevation: Double
    let elevMin:   Double
    let elevMax:   Double
    let isOutlier: Bool

    private var fraction: Double {
        guard elevMax > elevMin else { return 0.5 }
        return max(0, min(1, (elevation - elevMin) / (elevMax - elevMin)))
    }

    private var markerColor: Color {
        if isOutlier { return .orange.opacity(0.5) }
        // Blue (low) → Green (mid) → Red (high)
        if fraction < 0.5 {
            return Color(hue: 0.67 - fraction * 0.67, saturation: 0.8, brightness: 0.9)
        } else {
            return Color(hue: 0.33 - (fraction - 0.5) * 0.33, saturation: 0.9, brightness: 0.9)
        }
    }

    var body: some View {
        Circle()
            .fill(markerColor)
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
    }
}

