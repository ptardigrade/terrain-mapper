// SettingsView.swift
// TerrainMapper
//
// App settings and export interface.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings:       AppSettings
    @EnvironmentObject private var exportManager:  ExportManager

    @State private var showExportPicker: Bool  = false
    @State private var exportError:     String?
    @State private var showExportError: Bool   = false
    @State private var lastExportURLs:  [URL]  = []
    @State private var showShareSheet:  Bool   = false

    var body: some View {
        NavigationStack {
            Form {
                // ── Survey ────────────────────────────────────────────────
                Section {
                    HStack {
                        Label("Stick Height", systemImage: "ruler")
                        Spacer()
                        TextField("metres", value: $settings.stickHeight,
                                  format: .number.precision(.fractionLength(2)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("m").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Survey")
                } footer: {
                    Text("Fallback measurement-stick height used when LiDAR is unavailable. Must match the physical stick.")
                }

                // ── Processing ────────────────────────────────────────────
                Section("Processing") {
                    // Contour interval
                    VStack(alignment: .leading, spacing: 4) {
                        Label(String(format: "Contour Interval:  %.2f m", settings.contourInterval),
                              systemImage: "lines.measurement.horizontal")
                        Slider(value: $settings.contourInterval, in: 0.1...2.0, step: 0.1) {
                            Text("Contour Interval")
                        } minimumValueLabel: {
                            Text("0.1").font(.caption)
                        } maximumValueLabel: {
                            Text("2.0").font(.caption)
                        }
                    }

                    // Grid resolution
                    Picker(selection: $settings.gridResolution) {
                        Text("0.25 m").tag(0.25)
                        Text("0.50 m").tag(0.50)
                        Text("1.00 m").tag(1.00)
                    } label: {
                        Label("Grid Resolution", systemImage: "grid")
                    }

                    // Interpolation method
                    Picker(selection: $settings.interpolationMethod) {
                        ForEach(InterpolationMethod.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    } label: {
                        Label("Interpolation", systemImage: "waveform.path.ecg")
                    }

                    // Geoid correction
                    Toggle(isOn: $settings.enableGeoidCorrection) {
                        Label("EGM96 Geoid Correction", systemImage: "globe")
                    }

                    // MAD threshold
                    VStack(alignment: .leading, spacing: 4) {
                        Label(String(format: "Outlier Threshold:  %.1f σ", settings.madThreshold),
                              systemImage: "exclamationmark.triangle")
                        Slider(value: $settings.madThreshold, in: 2.0...6.0, step: 0.5)
                    }
                }

                // ── Display ────────────────────────────────────────────────
                Section("Display") {
                    Toggle(isOn: $settings.showOutliers) {
                        Label("Show Outlier Points", systemImage: "eye.slash")
                    }
                }

                // ── Export ────────────────────────────────────────────────
                Section {
                    ForEach(ExportFormat.allCases) { format in
                        Toggle(isOn: Binding(
                            get: { settings.selectedExportFormats.contains(format) },
                            set: { on in
                                if on { settings.selectedExportFormats.insert(format) }
                                else  { settings.selectedExportFormats.remove(format) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(format.rawValue).font(.body)
                                Text(format.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Export Formats")
                } footer: {
                    Text("Selected formats will be written to Documents/TerrainMapper/ when you tap Export in the Results view.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings())
        .environmentObject(ExportManager())
}
