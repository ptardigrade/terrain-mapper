// TerrainMapperApp.swift
// TerrainMapper
//
// SwiftUI @main entry point.  Creates all top-level StateObjects and injects
// them into the environment so every view can observe them.

import SwiftUI

@main
struct TerrainMapperApp: App {
    @StateObject private var engine        = SensorFusionEngine()
    @StateObject private var settings      = AppSettings()
    @StateObject private var exportManager = ExportManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environmentObject(settings)
                .environmentObject(exportManager)
        }
    }
}
