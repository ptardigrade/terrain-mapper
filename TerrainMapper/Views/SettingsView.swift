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
                        InfoButton(
                            title: "Stick Height",
                            message: "The measured height of your pole or staff above the ground. Used to calculate ground elevation when the LiDAR scanner can't read the surface directly. Must match the physical stick you're using."
                        )
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
                        HStack {
                            Label(String(format: "Contour Interval:  %.2f m", settings.contourInterval),
                                  systemImage: "lines.measurement.horizontal")
                            Spacer()
                            InfoButton(
                                title: "Contour Interval",
                                message: "The vertical distance between adjacent contour lines. Smaller values (e.g. 0.1 m) produce denser, more detailed contours; larger values (e.g. 2.0 m) give a cleaner overview."
                            )
                        }
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
                        HStack {
                            Label("Grid Resolution", systemImage: "grid")
                            InfoButton(
                                title: "Grid Resolution",
                                message: "The cell size of the interpolation grid. Finer grids (0.25 m) capture more terrain detail but take longer to process. Use coarser grids (1.0 m) for quick previews over large areas."
                            )
                        }
                    }

                    // Interpolation method
                    Picker(selection: $settings.interpolationMethod) {
                        ForEach(InterpolationMethod.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    } label: {
                        HStack {
                            Label("Interpolation", systemImage: "waveform.path.ecg")
                            InfoButton(
                                title: "Interpolation Method",
                                message: "How elevation is estimated between your captured points. IDW (Inverse Distance Weighting) is fast and robust. Kriging uses statistical modelling and can be more accurate for uneven terrain, but is slower."
                            )
                        }
                    }

                    // Geoid correction
                    Toggle(isOn: $settings.enableGeoidCorrection) {
                        HStack {
                            Label("EGM96 Geoid Correction", systemImage: "globe")
                            InfoButton(
                                title: "Geoid Correction",
                                message: "GPS reports height above a mathematical ellipsoid, not mean sea level. EGM96 converts that to orthometric (sea-level) height. Keep enabled unless you need raw ellipsoidal values."
                            )
                        }
                    }

                    // MAD threshold
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(String(format: "Outlier Threshold:  %.1f σ", settings.madThreshold),
                                  systemImage: "exclamationmark.triangle")
                            Spacer()
                            InfoButton(
                                title: "Outlier Threshold",
                                message: "Controls how aggressively suspect points are removed. The value is in standard deviations (σ) — lower means stricter. At 3.5 σ, only points more than 3.5 standard deviations from the median are flagged. Raise this if good points are being removed."
                            )
                        }
                        Slider(value: $settings.madThreshold, in: 2.0...6.0, step: 0.5)
                    }
                }

                // ── Display ────────────────────────────────────────────────
                Section("Display") {
                    Toggle(isOn: $settings.showOutliers) {
                        HStack {
                            Label("Show Outlier Points", systemImage: "eye.slash")
                            InfoButton(
                                title: "Show Outlier Points",
                                message: "Displays filtered-out points on the map as orange markers. Useful for verifying that the outlier filter isn't discarding valid data."
                            )
                        }
                    }
                }

                // ── Elevation calibration ─────────────────────────────────────────
                Section {
                    Toggle(isOn: $settings.elevationOffsetEnabled) {
                        HStack {
                            Label("Apply Elevation Offset", systemImage: "arrow.up.and.down.circle")
                            InfoButton(
                                title: "Elevation Offset",
                                message: "Shifts all elevation values by a fixed amount. Use this when a known benchmark shows your GPS readings are consistently high or low — enter a negative value to lower elevations, positive to raise them."
                            )
                        }
                    }
                    if settings.elevationOffsetEnabled {
                        HStack {
                            Label("Offset", systemImage: "plusminus")
                            Spacer()
                            TextField("0.000", value: $settings.elevationOffset,
                                      format: .number.precision(.fractionLength(3)))
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                            Text("m").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Elevation Calibration")
                } footer: {
                    Text("Add a fixed vertical offset to all ground elevations during processing. Use when a known benchmark point reveals a GPS altitude bias (e.g., enter −1.5 if elevations read 1.5 m too high).")
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
                    HStack(spacing: 4) {
                        Text("Export Formats")
                        InfoButton(
                            title: "Export Formats",
                            message: "Choose which file formats are written when you tap Export in the Results view. You can enable multiple formats at once. Files are saved to Documents/TerrainMapper/ and can be shared via AirDrop, Files, or any app."
                        )
                    }
                } footer: {
                    Text("Selected formats will be written to Documents/TerrainMapper/ when you tap Export in the Results view.")
                }

            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Info Button

private struct InfoButton: View {
    let title: String
    let message: String
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(Theme.primary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(maxWidth: 280)
            .presentationCompactAdaptation(.popover)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings())
        .environmentObject(ExportManager())
}
