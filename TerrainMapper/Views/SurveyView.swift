// SurveyView.swift
// TerrainMapper
//
// Live survey screen — "Digital Theodolite" layout.
// Full-bleed satellite map; floating glassmorphism header and bottom panel.
//
// Layout (no NavigationStack):
//   ┌──────────────────────────────────────┐
//   │  ◈ TERRAIN MAPPER   [undo][fit][End] │  ← floating topBar
//   │                                      │
//   │    Full-bleed MKMapView              │
//   │    (extends behind status bar)       │
//   │                                      │
//   │  ┌────────────────────────────────┐  │
//   │  │ TILT  GPS ACC  MOTION    ALT   │  │  ← glassmorphism panel
//   │  │ [──────── Capture Point ─────] │  │
//   │  │ TELEMETRY        viridis ████  │  │
//   │  └────────────────────────────────┘  │
//   └──────────────────────────────────────┘

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
    @State private var captureError:          String?
    @State private var showError:             Bool = false
    @State private var elapsedSeconds:        Int = 0
    @State private var sessionStarted:        Bool = false
    @State private var showLiDARFallbackAlert: Bool = false
    @State private var showEndWarning:        Bool = false
    @State private var sessionName:           String = ""
    @State private var showNameSheet:         Bool   = false

    @State private var elevMin: Double = 0
    @State private var elevMax: Double = 1

    @State private var captureToastElevation: Double? = nil
    @State private var captureToastTask: Task<Void, Never>? = nil

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // MARK: - Body

    // Height of the status bar / Dynamic Island safe area — used to
    // position floating controls below the notch without a GeometryReader.
    private var statusBarHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 59
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Full-bleed satellite map
            mapLayer

            // Floating map controls — End / Undo / Fit (top-right, below status bar)
            mapOverlayControls

            // Bottom survey panel (sits above tab bar)
            surveyPanel
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        // Extend only the TOP edge behind the status bar so the map fills
        // the full width. The bottom edge stays constrained by the TabView
        // so the panel doesn't slide behind the tab bar.
        .ignoresSafeArea(.all, edges: .top)
        // Toast notification floats above the top bar
        .overlay(alignment: .top) {
            Group {
                if let elev = captureToastElevation {
                    captureToastView(elevation: elev)
                        .padding(.top, 80)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.35), value: captureToastElevation != nil)
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
            Text("LiDAR couldn't measure this surface — it may be too reflective or in direct sunlight. Tap 'Use Stick Height' to record the point using your \(String(format: "%.1f", settings.stickHeight)) m stick measurement instead.")
        }
        .alert("Too Few Points", isPresented: $showEndWarning) {
            Button("End Anyway", role: .destructive) { endSession() }
            Button("Keep Surveying", role: .cancel) {}
        } message: {
            Text("Only \(capturedPoints.count) point\(capturedPoints.count == 1 ? "" : "s") captured so far. At least 6 are recommended — fewer points make the terrain model less reliable. You can keep surveying to improve accuracy.")
        }
        .sheet(isPresented: $showNameSheet) {
            sessionNameSheet
        }
    }

    // MARK: - Map layer

    private var mapLayer: some View {
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
            if capturedPoints.count >= 2 {
                MapPolyline(coordinates: capturedPoints.map(\.clCoordinate))
                    .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
            }
            if pathTrackCoordinates.count >= 2 {
                MapPolyline(coordinates: pathTrackCoordinates)
                    .stroke(Theme.primary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5))
            }
        }
        .mapStyle(.imagery(elevation: .realistic))
        // Hide MapKit's built-in controls — they sit behind the Dynamic
        // Island when the map extends behind the status bar. We provide
        // our own buttons in mapOverlayControls instead.
        .mapControls { }
    }

    private func mapControlButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.onSurface)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Floating controls that sit in the top-right corner of the map,
    /// manually offset below the status bar / Dynamic Island.
    private var mapOverlayControls: some View {
        VStack {
            HStack(spacing: 8) {
                // Custom location button (replaces MapKit's built-in one
                // which overlapped the Dynamic Island).
                mapControlButton(systemImage: "location.fill") {
                    cameraPosition = .userLocation(fallback: .automatic)
                }

                Spacer()
                if sessionStarted && !capturedPoints.isEmpty {
                    mapControlButton(systemImage: "arrow.uturn.backward") {
                        if let removed = engine.undoLastPoint() {
                            capturedPoints.removeAll { $0.id == removed.id }
                            let all = capturedPoints.map(\.groundElevation)
                            elevMin = all.min() ?? 0
                            elevMax = max(elevMin + 0.01, all.max() ?? 1)
                        }
                    }
                }
                if capturedPoints.count >= 2 {
                    mapControlButton(systemImage: "arrow.up.left.and.arrow.down.right") {
                        fitMapToPoints()
                    }
                }
                if sessionStarted {
                    Button { checkEndSession() } label: {
                        Text("End")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(.top, statusBarHeight + 12)
            .padding(.horizontal, 16)
            Spacer()
        }
    }

    // MARK: - Survey panel (glassmorphism)

    private var surveyPanel: some View {
        VStack(spacing: 14) {
            sensorGrid
            captureButton
            telemetryFooter
        }
        .padding(20)
        .background(Theme.background.opacity(0.45))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: Color(hex: "3adfab").opacity(0.06), radius: 24)
    }

    // MARK: - Sensor grid (4 columns)

    private var sensorGrid: some View {
        HStack(spacing: 0) {

            // Tilt bubble
            VStack(spacing: 4) {
                compactTiltBubble
                Text("TILT")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.6))
            }
            .frame(maxWidth: .infinity)

            panelDivider

            // GPS accuracy
            VStack(spacing: 3) {
                Text("±\(Int(engine.gpsAccuracy)) m")
                    .font(.system(.subheadline, design: .monospaced, weight: .bold))
                    .foregroundStyle(gpsColor)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("GPS ACC")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.6))
            }
            .frame(maxWidth: .infinity)

            panelDivider

            // Motion status
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    Image(systemName: engine.imuIsStationary ? "checkmark.circle.fill" : "waveform.path")
                        .font(.system(size: 12))
                        .foregroundStyle(engine.imuIsStationary ? Theme.primary : .orange)
                    Text(engine.imuIsStationary ? "STILL" : "MOVING")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(engine.imuIsStationary ? Theme.primary : .orange)
                }
                Text("MOTION")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.6))
            }
            .frame(maxWidth: .infinity)

            panelDivider

            // Fused altitude
            VStack(spacing: 2) {
                Text(String(format: "%.1f m", engine.currentAltitude))
                    .font(.system(.subheadline, design: .monospaced, weight: .bold))
                    .foregroundStyle(Theme.primary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(String(format: "±%.1f", engine.altitudeUncertainty))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.primary.opacity(0.6))
                Text("ALT")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 4)
    }

    private var panelDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.1))
            .frame(width: 0.5, height: 52)
    }

    /// Compact spirit-level bubble — inline replacement for TiltMeterView
    /// in the dense sensor panel.
    private var compactTiltBubble: some View {
        ZStack {
            // Stationary progress arc
            Circle()
                .trim(from: 0, to: CGFloat(engine.stationaryProgress))
                .stroke(
                    Theme.primary.opacity(engine.stationaryProgress > 0.95 ? 0.9 : 0.4),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: engine.stationaryProgress)

            // Outer ring
            Circle()
                .strokeBorder(tiltRingColor, lineWidth: 1.5)

            // Crosshair
            Path { p in
                p.move(to: CGPoint(x: 18, y: 12)); p.addLine(to: CGPoint(x: 18, y: 24))
                p.move(to: CGPoint(x: 12, y: 18)); p.addLine(to: CGPoint(x: 24, y: 18))
            }
            .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)

            // Bubble
            let off = tiltBubbleOffset
            Circle()
                .fill(tiltBubbleColor)
                .frame(width: 8, height: 8)
                .offset(x: off.width, y: off.height)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: off)
        }
        .frame(width: 36, height: 36)
    }

    private var tiltRingColor: Color {
        let t = engine.tiltAngleDegrees
        if t < 3 { return Theme.primary.opacity(0.7) }
        if t < 8 { return .yellow.opacity(0.7) }
        return .red.opacity(0.7)
    }

    private var tiltBubbleColor: Color {
        let t = engine.tiltAngleDegrees
        if t < 3 { return Theme.primary }
        if t < 8 { return .yellow }
        return .red
    }

    private var tiltBubbleOffset: CGSize {
        let max: CGFloat = 12
        let rawX = CGFloat(engine.gravityX) * 12
        let rawY = CGFloat(-engine.gravityY) * 12
        let dist = sqrt(rawX * rawX + rawY * rawY)
        let s = dist > max ? max / dist : 1.0
        return CGSize(width: rawX * s, height: rawY * s)
    }

    // MARK: - Capture button

    private var gpsTooInaccurate: Bool { engine.gpsAccuracy > 30 }

    private var captureButton: some View {
        Button(action: {
            if !sessionStarted {
                showNameSheet = true
            } else {
                Task { await capturePoint() }
            }
        }) {
            // ⚠️ Do NOT use ZStack here — RoundedRectangle is a greedy view that
            // expands to fill all available space, making the button enormous.
            // Use .background() so height is driven by content + padding only.
            HStack(spacing: 10) {
                if !sessionStarted {
                    Image(systemName: "play.circle.fill").font(.title3)
                    Text("Start Survey").font(.system(size: 17, weight: .bold))
                } else if isCapturing {
                    VStack(spacing: 6) {
                        Text("Sampling LiDAR…").font(.system(size: 17, weight: .bold))
                        ProgressView(value: engine.lidarCaptureProgress)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .frame(maxWidth: 200)
                    }
                } else if gpsTooInaccurate {
                    Image(systemName: "location.slash.fill")
                    Text("Weak GPS — Move to open sky").font(.system(size: 17, weight: .bold))
                } else if !engine.imuIsStationary {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Hold Steady").font(.system(size: 17, weight: .bold))
                } else {
                    Image(systemName: "plus.circle.fill").font(.title3)
                    Text("Capture Point").font(.system(size: 17, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(captureButtonBackground)
        }
        .disabled(sessionStarted && (isCapturing || !engine.isSessionActive || gpsTooInaccurate))
        .animation(.easeInOut(duration: 0.2), value: isCapturing)
        .animation(.easeInOut(duration: 0.2), value: engine.imuIsStationary)
        .animation(.easeInOut(duration: 0.3), value: gpsTooInaccurate)
    }

    @ViewBuilder
    private var captureButtonBackground: some View {
        if !sessionStarted {
            // Green gradient — the start button should look as actionable as
            // the capture button, not muted/disabled.
            RoundedRectangle(cornerRadius: 14).fill(Theme.primaryGradient)
        } else if isCapturing {
            RoundedRectangle(cornerRadius: 14).fill(Theme.primary.opacity(0.75))
        } else if gpsTooInaccurate {
            RoundedRectangle(cornerRadius: 14).fill(Color.red.opacity(0.8))
        } else if !engine.imuIsStationary {
            RoundedRectangle(cornerRadius: 14).fill(Color.orange)
        } else {
            RoundedRectangle(cornerRadius: 14).fill(Theme.primaryGradient)
        }
    }

    // MARK: - Telemetry footer

    private var telemetryFooter: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("TELEMETRY")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.5))
                HStack(spacing: 12) {
                    HStack(spacing: 3) {
                        Text("\(capturedPoints.count)")
                            .font(.system(.body, design: .monospaced, weight: .bold))
                            .foregroundStyle(Theme.onSurface)
                        Text("pts")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.onSurfaceVariant)
                    }
                    HStack(spacing: 3) {
                        Text(formattedElapsed)
                            .font(.system(.body, design: .monospaced, weight: .bold))
                            .foregroundStyle(Theme.onSurface)
                        Text("min")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.onSurfaceVariant)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Theme.viridisGradient
                    .frame(width: 88, height: 5)
                    .clipShape(Capsule())

                if capturedPoints.count >= 2 {
                    Text(String(format: "%.1f–%.1f m", elevMin, elevMax))
                        .font(.system(.footnote, design: .monospaced, weight: .semibold))
                        .foregroundStyle(Theme.onSurface)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text("no points yet")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.onSurfaceVariant.opacity(0.5))
                }
            }
        }
    }

    // MARK: - Toast

    private func captureToastView(elevation: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.primary)
            Text(String(format: "Captured  %.2f m", elevation))
                .font(.subheadline.bold())
                .foregroundStyle(Theme.onSurface)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
    }

    // MARK: - Session name sheet

    private var sessionNameSheet: some View {
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
                    .tint(Theme.primary)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Toast helper

    private func showCaptureToast(elevation: Double) {
        captureToastTask?.cancel()
        captureToastElevation = elevation
        captureToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            captureToastElevation = nil
        }
    }

    // MARK: - Helpers

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
                span:   MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
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
            showCaptureToast(elevation: point.groundElevation)

            if let snapshot = engine.currentSessionSnapshot {
                sessionStore.save(session: snapshot)
            }

            let all = capturedPoints.map(\.groundElevation)
            elevMin = all.min() ?? 0
            elevMax = max(elevMin + 0.01, all.max() ?? 1)

            let coord = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
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

        guard let location = engine.gpsManager.currentLocation else {
            captureError = "No GPS location available."
            showError = true
            return
        }
        let fusedAlt  = engine.currentAltitude
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
        showCaptureToast(elevation: point.groundElevation)

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

// MARK: - Survey point marker

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
