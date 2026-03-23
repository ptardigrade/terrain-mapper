// ContentView.swift
// TerrainMapper
//
// Root view — three-tab navigation: Survey, Results, Settings.
// The active SurveySession flows from the Survey tab into the Results tab
// via a shared binding on TerrainMapperApp's @StateObject.

import SwiftUI
import UIKit
import MapKit
import simd

struct ContentView: View {
    @EnvironmentObject private var engine:   SensorFusionEngine
    @EnvironmentObject private var settings: AppSettings

    /// The processed terrain from the most recent session.
    @State private var processedTerrain: ProcessedTerrain?
    /// True while the pipeline is running after a session ends.
    @State private var isProcessing: Bool = false
    /// Pipeline instance (shared so progress can be observed).
    @StateObject private var pipeline = ProcessingPipeline()
    /// Selected tab index — used to programmatically switch to Results.
    @State private var selectedTab: Int = 0

    init() {
        // Force an opaque tab bar with a solid dark background so icons
        // are always visible — even over the full-bleed AR camera feed.
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        let bg = UIColor(red: 0.107, green: 0.107, blue: 0.114, alpha: 1.0) // Theme.surfaceContainerLow
        appearance.backgroundColor = bg
        // Active tab icon + text color
        let activeColor = UIColor(red: 0.663, green: 0.741, blue: 0.537, alpha: 1.0) // Theme.primary
        let inactiveColor = UIColor(red: 0.733, green: 0.792, blue: 0.757, alpha: 0.7) // Theme.onSurfaceVariant
        appearance.stackedLayoutAppearance.selected.iconColor = activeColor
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: activeColor]
        appearance.stackedLayoutAppearance.normal.iconColor = inactiveColor
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: inactiveColor]
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            TabView(selection: $selectedTab) {
                // ── Survey tab ────────────────────────────────────────────────
                SurveyView(onSessionEnded: { session in
                    processSession(session)
                })
                .tabItem {
                    Label("Survey", systemImage: "mappin.and.ellipse")
                }
                .tag(0)

                // ── Results tab ───────────────────────────────────────────────
                Group {
                    if let terrain = processedTerrain {
                        ResultsView(terrain: terrain)
                    } else if isProcessing {
                        ProgressiveResultsView(pipeline: pipeline)
                    } else {
                        noResultsPlaceholder
                    }
                }
                .tabItem {
                    Label("Results", systemImage: "chart.xyaxis.line")
                }
                .tag(1)

                // ── Settings tab ──────────────────────────────────────────────
                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .tag(2)

                // ── History tab ───────────────────────────────────────────────
                SessionHistoryView()
                    .tabItem {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    .tag(3)
            }
            .tint(Theme.primary)
            .environmentObject(pipeline)
        }
    }

    // MARK: - Session processing

    private func processSession(_ session: SurveySession) {
        isProcessing = true
        processedTerrain = nil
        settings.configure(pipeline)

        // Switch to the Results tab so the user sees processing progress.
        selectedTab = 1

        // Convert AR mesh vertices (simd_float3) to plain Float arrays
        // for Sendable-safe transfer to the background processing task.
        let meshVerts: [[Float]] = engine.lastSessionMeshVertices.map { v in
            [v.x, v.y, v.z]
        }

        Task {
            let terrain = await pipeline.process(session: session, arMeshVertices: meshVerts)
            processedTerrain = terrain
            isProcessing = false
        }
    }

    // MARK: - Placeholder views

    private var noResultsPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 56))
                .foregroundStyle(Theme.surfaceContainerHighest)
            Text("No Survey Results")
                .font(.headline)
                .foregroundStyle(Theme.onSurfaceVariant)
            Text("Complete a survey session to see\ntopographic results here.")
                .font(.subheadline)
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

// MARK: - ProgressiveResultsView

/// Shows result tabs immediately during processing with per-tab loading states.
/// Tabs whose data is ready (published progressively by the pipeline) display
/// real content; tabs still loading show a spinner with a stage-specific message.
struct ProgressiveResultsView: View {
    @ObservedObject var pipeline: ProcessingPipeline

    enum ProgressTab: String, CaseIterable, Identifiable {
        case map      = "Map"
        case scene3D  = "3D"
        case contours = "Contours"
        case stats    = "Stats"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .map:      return "map"
            case .scene3D:  return "cube"
            case .contours: return "lines.measurement.horizontal"
            case .stats:    return "chart.bar"
            }
        }
    }

    @State private var selectedTab: ProgressTab = .stats

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker (always visible)
                Picker("View", selection: $selectedTab) {
                    ForEach(ProgressTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Theme.surfaceContainerLow)

                Divider()

                // Content area
                Group {
                    switch selectedTab {
                    case .stats:
                        if let points = pipeline.partialPoints {
                            partialStatsView(points: points,
                                             outliers: pipeline.partialOutliers ?? [],
                                             stats: pipeline.partialStats)
                        } else {
                            tabLoadingView(message: "Preparing data…")
                        }
                    case .scene3D:
                        if let mesh = pipeline.partialMesh {
                            TerrainSceneView(mesh: mesh)
                                .ignoresSafeArea(edges: .bottom)
                        } else {
                            tabLoadingView(message: "Building 3D mesh…")
                        }
                    case .contours:
                        if let contours = pipeline.partialContours {
                            ContourScrollView(contours: contours)
                                .ignoresSafeArea(edges: .bottom)
                        } else {
                            tabLoadingView(message: "Drawing contour lines…")
                        }
                    case .map:
                        if let points = pipeline.partialPoints,
                           let contours = pipeline.partialContours {
                            PartialMapView(points: points, contours: contours)
                                .ignoresSafeArea(edges: .bottom)
                        } else if let points = pipeline.partialPoints {
                            PartialMapView(points: points, contours: [])
                                .ignoresSafeArea(edges: .bottom)
                        } else {
                            tabLoadingView(message: "Interpolating terrain…")
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Progress footer
                VStack(spacing: 8) {
                    ProgressView(value: pipeline.progress)
                        .progressViewStyle(.linear)
                        .tint(Theme.primary)

                    Text(pipeline.progressMessage.isEmpty ? "Processing…" : pipeline.progressMessage)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.onSurfaceVariant)

                    Text("Please keep the app open so your data isn't lost")
                        .font(.caption2)
                        .foregroundStyle(Theme.onSurfaceVariant.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.surfaceContainerLow)
            }
            .navigationTitle("Processing Results")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func tabLoadingView(message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
                .tint(Theme.primary)
            Text(message)
                .font(.system(.headline, design: .monospaced))
                .foregroundStyle(Theme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private func partialStatsView(points: [SurveyPoint], outliers: [SurveyPoint], stats: ProcessingStats?) -> some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                statCard(icon: "mappin.circle.fill", label: "Points",
                         value: "\(points.count)",
                         sub: outliers.isEmpty ? "no outliers" : "\(outliers.count) outlier\(outliers.count == 1 ? "" : "s")")

                if let stats = stats {
                    statCard(icon: "rectangle.expand.diagonal", label: "Area",
                             value: formatArea(stats.surveyedAreaM2),
                             sub: "surveyed")
                    statCard(icon: "arrow.up.and.down", label: "Elevation Range",
                             value: String(format: "%.2f m", stats.elevationMax - stats.elevationMin),
                             sub: String(format: "%.1f – %.1f m", stats.elevationMin, stats.elevationMax))
                    statCard(icon: "scope", label: "RMS Accuracy",
                             value: String(format: "±%.2f m", stats.rmsAccuracyEstimate),
                             sub: "estimated")
                    statCard(icon: "clock", label: "Processing",
                             value: String(format: "%.1f s", stats.processingTimeSeconds),
                             sub: stats.loopClosureApplied ? "drift corrected" : "no loop detected")
                } else {
                    statCard(icon: "arrow.up.and.down", label: "Elevation Range",
                             value: "…",
                             sub: "computing")
                }
            }
            .padding()
        }
        .background(Theme.background)
    }

    private func statCard(icon: String, label: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(Theme.primary)
                Spacer()
            }
            Text(value)
                .font(.title3.bold())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption).foregroundStyle(.primary)
            Text(sub)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .background(Theme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 12))
    }

    private func formatArea(_ m2: Double) -> String {
        if m2 >= 10_000 { return String(format: "%.3f ha", m2 / 10_000) }
        return String(format: "%.0f m²", m2)
    }
}

// MARK: - PartialMapView

/// Lightweight map view used during progressive loading — shows points and
/// optionally contour polylines without requiring the full ProcessedTerrain.
/// Downsamples to at most 200 annotations to avoid MapKit crash on large datasets.
private struct PartialMapView: View {
    let points: [SurveyPoint]
    let contours: [ContourLine]

    /// Downsample large point arrays to prevent MapKit from freezing.
    private var displayPoints: [SurveyPoint] {
        let maxAnnotations = 200
        guard points.count > maxAnnotations else { return points }
        let stride = max(1, points.count / maxAnnotations)
        return (0..<points.count).compactMap { i in
            i % stride == 0 ? points[i] : nil
        }
    }

    var body: some View {
        let pts = displayPoints
        let allLats = pts.map(\.latitude)
        let allLons = pts.map(\.longitude)
        let centLat = allLats.isEmpty ? 0 : allLats.reduce(0,+) / Double(allLats.count)
        let centLon = allLons.isEmpty ? 0 : allLons.reduce(0,+) / Double(allLons.count)
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centLat, longitude: centLon),
            latitudinalMeters: 200, longitudinalMeters: 200
        )

        Map(initialPosition: .region(region)) {
            ForEach(pts) { p in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)) {
                    Circle()
                        .fill(Color.green.opacity(0.8))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
                }
            }
            ForEach(Array(contours.enumerated()), id: \.offset) { _, contour in
                MapPolyline(coordinates: contour.coordinates.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .stroke(.white.opacity(0.8), lineWidth: 1)
            }
        }
        .mapStyle(.imagery(elevation: .realistic))
    }
}

#Preview {
    ContentView()
        .environmentObject(SensorFusionEngine())
        .environmentObject(AppSettings())
        .environmentObject(ExportManager())
        .environmentObject(SessionStore())
}
