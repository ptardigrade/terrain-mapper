// ContentView.swift
// TerrainMapper
//
// Root view — three-tab navigation: Survey, Results, Settings.
// The active SurveySession flows from the Survey tab into the Results tab
// via a shared binding on TerrainMapperApp's @StateObject.

import SwiftUI
import UIKit
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
                        processingPlaceholder
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

    private var processingPlaceholder: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
                .tint(Theme.primary)
            Text(pipeline.progressMessage.isEmpty ? "Processing…" : pipeline.progressMessage)
                .font(.system(.headline, design: .monospaced))
                .foregroundStyle(Theme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

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

#Preview {
    ContentView()
        .environmentObject(SensorFusionEngine())
        .environmentObject(AppSettings())
        .environmentObject(ExportManager())
        .environmentObject(SessionStore())
}
