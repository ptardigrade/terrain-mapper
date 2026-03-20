// SessionHistoryView.swift
// TerrainMapper
//
// Displays all archived survey sessions.
// - Tap a row to re-process the session and view results.
// - Swipe-left to delete.
// - Interrupted session recovery banner at top.

import SwiftUI

struct SessionHistoryView: View {

    @EnvironmentObject private var sessionStore:  SessionStore
    @EnvironmentObject private var settings:      AppSettings
    @EnvironmentObject private var exportManager: ExportManager

    /// When non-nil, the results screen is shown for this terrain.
    @State private var selectedTerrain: ProcessedTerrain?
    /// True while the pipeline is re-processing a historical session.
    @State private var isReprocessing: Bool = false
    @State private var reprocessingName: String = ""

    @StateObject private var pipeline = ProcessingPipeline()

    var body: some View {
        NavigationStack {
            Group {
                if sessionStore.completedSessions.isEmpty && !sessionStore.hasInterruptedSession {
                    emptyState
                } else {
                    sessionList
                }
            }
            .navigationTitle("Session History")
            .navigationBarTitleDisplayMode(.large)
            .sheet(item: $selectedTerrain) { terrain in
                ResultsView(terrain: terrain)
                    .environmentObject(settings)
                    .environmentObject(exportManager)
            }
            .overlay {
                if isReprocessing {
                    reprocessingOverlay
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("No Saved Sessions")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Completed survey sessions will appear here.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Session list

    private var sessionList: some View {
        List {
            // ── Interrupted session recovery banner ───────────────────────
            if sessionStore.hasInterruptedSession,
               let interrupted = sessionStore.interruptedSession {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Interrupted Session Found", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(.orange)
                        Text("\(interrupted.points.count) points captured before the session was interrupted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("Recover & View") {
                                reprocess(interrupted)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .font(.caption)

                            Button("Discard", role: .destructive) {
                                sessionStore.discardInterruptedSession()
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // ── Completed sessions ─────────────────────────────────────────
            Section("Completed Sessions") {
                ForEach(sessionStore.completedSessions) { session in
                    SessionRow(session: session)
                        .contentShape(Rectangle())
                        .onTapGesture { reprocess(session) }
                }
                .onDelete { offsets in
                    sessionStore.delete(at: offsets)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Reprocessing overlay

    private var reprocessingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.4)
                    .tint(.white)
                Text("Processing \(reprocessingName)…")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Actions

    private func reprocess(_ session: SurveySession) {
        reprocessingName = sessionName(session)
        isReprocessing = true
        settings.configure(pipeline)

        Task {
            let terrain = await pipeline.process(session: session)
            selectedTerrain = terrain
            isReprocessing = false
        }
    }

    private func sessionName(_ s: SurveySession) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: s.startTime)
    }
}

// MARK: - SessionRow

private struct SessionRow: View {
    let session: SurveySession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(sessionTitle)
                    .font(.subheadline.bold())
                Spacer()
                Text(pointCount)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(duration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let end = session.endTime {
                    Text(relativeDate(end))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var sessionTitle: String {
        if !session.name.isEmpty {
            return session.name
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: session.startTime)
    }

    private var pointCount: String {
        let n = session.points.count
        return "\(n) point\(n == 1 ? "" : "s")"
    }

    private var duration: String {
        guard let end = session.endTime else { return "In progress" }
        let secs = Int(end.timeIntervalSince(session.startTime))
        let m = secs / 60, s = secs % 60
        return String(format: "%d:%02d", m, s)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - ProcessedTerrain Identifiable

// ProcessedTerrain needs to be Identifiable for .sheet(item:).
// Extend it here if not already — using the session's id.
extension ProcessedTerrain: Identifiable {
    public var id: UUID { session.id }
}
