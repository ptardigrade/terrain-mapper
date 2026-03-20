// SessionHistoryView.swift
// TerrainMapper
//
// Session history screen — "Digital Theodolite" layout.
// Custom sticky header + large title + card rows.
// Swipe-to-delete is preserved via ForEach.onDelete inside a styled List.

import SwiftUI

struct SessionHistoryView: View {

    @EnvironmentObject private var sessionStore:  SessionStore
    @EnvironmentObject private var settings:      AppSettings
    @EnvironmentObject private var exportManager: ExportManager

    @State private var selectedTerrain:   ProcessedTerrain?
    @State private var isReprocessing:    Bool = false
    @State private var reprocessingName:  String = ""

    @StateObject private var pipeline = ProcessingPipeline()

    var body: some View {
        VStack(spacing: 0) {
            historyTopBar

            if sessionStore.completedSessions.isEmpty && !sessionStore.hasInterruptedSession {
                emptyState
            } else {
                historyList
            }
        }
        .background(Theme.background)
        .sheet(item: $selectedTerrain) { terrain in
            ResultsView(terrain: terrain)
                .environmentObject(settings)
                .environmentObject(exportManager)
        }
        .overlay {
            if isReprocessing { reprocessingOverlay }
        }
    }

    // MARK: - Custom top bar

    private var historyTopBar: some View {
        HStack {
            HStack(spacing: 8) {
                VStack(spacing: 2) {
                    Rectangle().fill(Theme.primary.opacity(0.4)).frame(width: 18, height: 1.5)
                    Rectangle().fill(Theme.primary.opacity(0.7)).frame(width: 24, height: 1.5)
                    Rectangle().fill(Theme.primary).frame(width: 14, height: 1.5)
                }
                Text("TERRAIN MAPPER")
                    .font(.system(size: 14, weight: .black))
                    .tracking(-0.3)
                    .foregroundStyle(Theme.primary)
            }
            Spacer()
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(Theme.onSurfaceVariant)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.background.opacity(0.5))
        .background(.ultraThinMaterial)
    }

    // MARK: - History list

    private var historyList: some View {
        List {
            // Large page title
            HStack {
                Text("History")
                    .font(.system(size: 36, weight: .black))
                    .foregroundStyle(Theme.onSurface)
                Spacer()
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 24, leading: 20, bottom: 4, trailing: 20))

            // Interrupted session recovery banner
            if sessionStore.hasInterruptedSession,
               let interrupted = sessionStore.interruptedSession {
                interruptedBanner(interrupted)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }

            // Completed sessions
            ForEach(sessionStore.completedSessions) { session in
                SessionRowCard(session: session)
                    .contentShape(Rectangle())
                    .onTapGesture { reprocess(session) }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            .onDelete { offsets in
                sessionStore.delete(at: offsets)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    // MARK: - Interrupted session banner

    private func interruptedBanner(_ session: SurveySession) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Interrupted Session Recovered")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.onSurface)
                Text("\(session.points.count) pts captured before interruption")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.onSurfaceVariant)
            }

            Spacer()

            VStack(spacing: 6) {
                Button("Resume") { reprocess(session) }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: "003828"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.primaryGradient, in: RoundedRectangle(cornerRadius: 8))

                Button("Discard") { sessionStore.discardInterruptedSession() }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(Theme.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 52))
                .foregroundStyle(Theme.surfaceContainerHighest)
            Text("No Saved Sessions")
                .font(.headline)
                .foregroundStyle(Theme.onSurfaceVariant)
            Text("Completed survey sessions will appear here.")
                .font(.subheadline)
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - Reprocessing overlay

    private var reprocessingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.4)
                    .tint(Theme.primary)
                Text("Processing \(reprocessingName)…")
                    .font(.headline)
                    .foregroundStyle(Theme.onSurface)
            }
            .padding(32)
            .background(Theme.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    // MARK: - Actions

    private func reprocess(_ session: SurveySession) {
        reprocessingName = sessionLabel(session)
        isReprocessing = true
        settings.configure(pipeline)

        Task {
            let terrain = await pipeline.process(session: session)
            selectedTerrain = terrain
            isReprocessing = false
        }
    }

    private func sessionLabel(_ s: SurveySession) -> String {
        if !s.name.isEmpty { return s.name }
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: s.startTime)
    }
}

// MARK: - Session row card

private struct SessionRowCard: View {
    let session: SurveySession

    var body: some View {
        HStack(spacing: 14) {
            // Icon tile
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.surfaceContainerHighest)
                    .frame(width: 48, height: 48)
                Image(systemName: iconName)
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.primary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(sessionTitle)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.onSurface)
                        .lineLimit(1)
                    Spacer()
                    if let end = session.endTime {
                        Text(relativeDate(end))
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.5))
                    }
                }

                Text(formattedDate)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.onSurfaceVariant)

                HStack(spacing: 10) {
                    chip(icon: "mappin", value: "\(session.points.count) pt\(session.points.count == 1 ? "" : "s")")
                    chip(icon: "clock", value: duration)
                }
            }
        }
        .padding(14)
        .background(Theme.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 16))
    }

    private func chip(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Theme.onSurfaceVariant)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(Theme.onSurface)
        }
    }

    private var iconName: String {
        let n = session.points.count
        if n >= 100 { return "mountain.2.fill" }
        if n >= 20  { return "map.fill" }
        return "mappin.and.ellipse"
    }

    private var sessionTitle: String {
        if !session.name.isEmpty { return session.name }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: session.startTime)
    }

    private var formattedDate: String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: session.startTime)
    }

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private var duration: String {
        guard let end = session.endTime else { return "In progress" }
        let secs = Int(end.timeIntervalSince(session.startTime))
        let m = secs / 60, s = secs % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - ProcessedTerrain Identifiable

extension ProcessedTerrain: Identifiable {
    public var id: UUID { session.id }
}
