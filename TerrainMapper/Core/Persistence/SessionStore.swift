// SessionStore.swift
// TerrainMapper
//
// Persists SurveySession data to disk so sessions survive app termination.
//
// ─── Storage strategy ─────────────────────────────────────────────────────
// Each session is stored as a separate JSON file in:
//   Documents/TerrainMapper/Sessions/<session-id>.json
//
// The active session is written incrementally — after every point capture —
// so a crash loses at most one point.
//
// On launch, if an incomplete session file exists (endTime == nil), we set
// hasInterruptedSession = true so the UI can offer recovery.
//
// Completed sessions are kept in the archive indefinitely (user can delete).

import Foundation
import Combine

@MainActor
final class SessionStore: ObservableObject {

    // MARK: - Published state

    /// All completed sessions, newest first.
    @Published private(set) var completedSessions: [SurveySession] = []

    /// True if an in-progress (crashed/interrupted) session was found on launch.
    @Published private(set) var hasInterruptedSession: Bool = false

    /// The recovered in-progress session (if hasInterruptedSession is true).
    @Published private(set) var interruptedSession: SurveySession?

    // MARK: - Private

    private let fileManager = FileManager.default
    private var sessionsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("TerrainMapper/Sessions")
    }

    // MARK: - Lifecycle

    init() {
        ensureDirectoryExists()
        loadAllSessions()
        detectInterruptedSession()
    }

    // MARK: - Active session incremental writes

    /// Append a point to the active session file.  Call after every capture.
    func save(session: SurveySession) {
        let url = sessionsDirectory.appendingPathComponent("\(session.id.uuidString).json")
        do {
            let data = try JSONEncoder().encode(session)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[SessionStore] Failed to save session: \(error)")
        }
    }

    // MARK: - Session completion

    /// Mark a session as complete and add it to the archive.
    func archive(session: SurveySession) {
        save(session: session)
        // Reload all sessions so the new one appears in the list
        loadAllSessions()
    }

    // MARK: - Deletion

    /// Delete a session from disk and from the in-memory list.
    func delete(session: SurveySession) {
        let url = sessionsDirectory.appendingPathComponent("\(session.id.uuidString).json")
        try? fileManager.removeItem(at: url)
        completedSessions.removeAll { $0.id == session.id }
    }

    /// Delete a session at an IndexSet offset (for List swipe-to-delete).
    func delete(at offsets: IndexSet) {
        for index in offsets {
            let session = completedSessions[index]
            delete(session: session)
        }
    }

    // MARK: - Interrupted session recovery

    /// Discard the interrupted session (user chose not to recover).
    func discardInterruptedSession() {
        if let s = interruptedSession {
            delete(session: s)
        }
        interruptedSession = nil
        hasInterruptedSession = false
    }

    // MARK: - Private helpers

    private func ensureDirectoryExists() {
        try? fileManager.createDirectory(at: sessionsDirectory,
                                         withIntermediateDirectories: true)
    }

    private func loadAllSessions() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let decoder = JSONDecoder()
        var sessions: [SurveySession] = []
        for url in urls where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let session = try? decoder.decode(SurveySession.self, from: data),
               session.endTime != nil {          // only completed sessions
                sessions.append(session)
            }
        }
        // Sort newest first
        completedSessions = sessions.sorted {
            ($0.endTime ?? $0.startTime) > ($1.endTime ?? $1.startTime)
        }
    }

    private func detectInterruptedSession() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        let decoder = JSONDecoder()
        for url in urls where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let session = try? decoder.decode(SurveySession.self, from: data),
               session.endTime == nil,             // incomplete = interrupted
               !session.points.isEmpty {
                interruptedSession   = session
                hasInterruptedSession = true
                return
            }
        }
    }
}
