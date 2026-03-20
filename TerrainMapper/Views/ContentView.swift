// ContentView.swift
// TerrainMapper
//
// Root view — three-tab navigation: Survey, Results, Settings.
// The active SurveySession flows from the Survey tab into the Results tab
// via a shared binding on TerrainMapperApp's @StateObject.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var engine:   SensorFusionEngine
    @EnvironmentObject private var settings: AppSettings

    /// The processed terrain from the most recent session.
    @State private var processedTerrain: ProcessedTerrain?
    /// True while the pipeline is running after a session ends.
    @State private var isProcessing: Bool = false
    /// Pipeline instance (shared so progress can be observed).
    @StateObject private var pipeline = ProcessingPipeline()

    var body: some View {
        TabView {
            // ── Survey tab ────────────────────────────────────────────────
            SurveyView(onSessionEnded: { session in
                processSession(session)
            })
            .tabItem {
                Label("Survey", systemImage: "mappin.and.ellipse")
            }

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

            // ── Settings tab ──────────────────────────────────────────────
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }

            // ── History tab ───────────────────────────────────────────────
            SessionHistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
        }
        .environmentObject(pipeline)
    }

    // MARK: - Session processing

    private func processSession(_ session: SurveySession) {
        isProcessing = true
        processedTerrain = nil
        settings.configure(pipeline)

        Task {
            let terrain = await pipeline.process(session: session)
            processedTerrain = terrain
            isProcessing = false
        }
    }

    // MARK: - Placeholder views

    private var processingPlaceholder: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
            Text(pipeline.progressMessage.isEmpty ? "Processing…" : pipeline.progressMessage)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var noResultsPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("No Survey Results")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Complete a survey session to see\ntopographic results here.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

#Preview {
    ContentView()
        .environmentObject(SensorFusionEngine())
        .environmentObject(AppSettings())
        .environmentObject(ExportManager())
        .environmentObject(SessionStore())
}
