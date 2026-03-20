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
import CoreMotion
import CoreLocation

struct SurveyView: View {

    // MARK: - Inputs

    var onSessionEnded: (SurveySession) -> Void

    // MARK: - Dependencies

    @EnvironmentObject private var engine:   SensorFusionEngine
    @EnvironmentObject private var settings: AppSettings

    // MARK: - State

    @State private var capturedPoints:   [SurveyPoint] = []
    @State private var cameraPosition:   MapCameraPosition = .automatic
    @State private var isCapturing:      Bool = false
    @State private var captureError:     String?
    @State private var showError:        Bool = false
    @State private var elapsedSeconds:   Int = 0
    @State private var sessionStarted:   Bool = false
    @State private var captureCountdown: Int = 0   // LiDAR frames remaining
    @State private var gravityX:         Double = 0
    @State private var gravityY:         Double = 0

    // Elevation range for colour mapping (updated as points arrive)
    @State private var elevMin: Double = 0
    @State private var elevMax: Double = 1

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let motionManager = CMMotionManager()

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
                        Button("Start") { startSession() }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if sessionStarted {
                        Button("End Survey") { endSession() }
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            if sessionStarted { elapsedSeconds += 1 }
        }
        .onAppear { startGravityUpdates() }
        .onDisappear { motionManager.stopDeviceMotionUpdates() }
        .onChange(of: engine.imuIsStationary) { _, _ in }
        .alert("Capture Error", isPresented: $showError, presenting: captureError) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in Text(msg) }
    }

    // MARK: - Sensor status row

    private var sensorStatusRow: some View {
        HStack(spacing: 0) {
            // Spirit level
            TiltMeterView(
                tiltAngle: engine.tiltAngleDegrees * .pi / 180,
                gravityX:  gravityX,
                gravityY:  gravityY,
                isStationary: engine.imuIsStationary
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
            VStack(spacing: 3) {
                Image(systemName: "arrow.up.and.down")
                    .foregroundStyle(.blue)
                Text("ALT")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(String(format: "%.1f m", engine.currentAltitude))
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Capture button

    private var captureButton: some View {
        Button(action: { Task { await capturePoint() } }) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(captureButtonColor)
                HStack(spacing: 10) {
                    if isCapturing {
                        ProgressView().progressViewStyle(.circular).tint(.white)
                        Text("Sampling LiDAR…")
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
        .disabled(!sessionStarted || isCapturing || !engine.isSessionActive)
        .animation(.easeInOut(duration: 0.2), value: isCapturing)
        .animation(.easeInOut(duration: 0.2), value: engine.imuIsStationary)
    }

    private var captureButtonColor: Color {
        if isCapturing                { return .blue }
        if !engine.imuIsStationary    { return .orange }
        return .blue
    }

    // MARK: - Session footer

    private var sessionFooter: some View {
        HStack {
            Label("\(capturedPoints.count) point\(capturedPoints.count == 1 ? "" : "s")",
                  systemImage: "mappin")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Label(formattedElapsed, systemImage: "clock")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
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
        if acc <= 5  { return .green }
        if acc <= 15 { return .yellow }
        return .red
    }

    // MARK: - Actions

    private func startSession() {
        capturedPoints = []
        elapsedSeconds = 0
        elevMin = 0; elevMax = 1
        engine.startSession(stickHeight: settings.stickHeight)
        sessionStarted = true
    }

    private func endSession() {
        let session = engine.endSession()
        sessionStarted = false
        onSessionEnded(session)
    }

    private func capturePoint() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        do {
            let point = try await engine.capturePoint()
            capturedPoints.append(point)

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
        } catch {
            captureError = error.localizedDescription
            showError    = true
        }
    }

    // MARK: - IMU gravity for TiltMeterView

    private func startGravityUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: .main) { motion, _ in
            guard let m = motion else { return }
            gravityX = m.gravity.x
            gravityY = m.gravity.y
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

private extension SurveyPoint {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
