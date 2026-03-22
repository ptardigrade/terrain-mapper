// SettingsView.swift
// TerrainMapper
//
// App settings — "Digital Theodolite" layout.
// Custom ScrollView with accent-bar section headers and surface-container cards.
// No Form/NavigationStack chrome; sections use the Stitch vertical teal bar pattern.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings:      AppSettings
    @EnvironmentObject private var exportManager: ExportManager

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                // Large page title
                HStack {
                    Text("Settings")
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(Theme.onSurface)
                    Spacer()
                }
                .padding(.top, 16)

                sectionGroup("Processing")     { processingCard }
                sectionGroup("Elevation Calibration") { calibrationCard }
                sectionGroup("Export Formats") { exportCard }
                sectionGroup("Display")        { displayCard }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .background { Theme.background.ignoresSafeArea() }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Section / card helpers

    private func sectionGroup<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Theme.primary)
                    .frame(width: 4, height: 22)
                Text(title.uppercased())
                    .font(.system(size: 13, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.onSurface)
                Spacer()
            }
            content()
        }
    }

    private func card<C: View>(@ViewBuilder content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .padding(20)
            .background(Theme.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 16))
    }

    private func settingLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(1.5)
            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.6))
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(Theme.surfaceContainerHigh)
            .frame(height: 1)
    }

    // MARK: - Processing card

    private var processingCard: some View {
        card {
            VStack(spacing: 20) {

                // ── Contour interval ──────────────────────────────────────
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            settingLabel("Contour Interval")
                            Text("Vertical resolution of topographic lines")
                                .font(.subheadline)
                                .foregroundStyle(Theme.onSurfaceVariant)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Text(String(format: "%.1f m", settings.contourInterval))
                                .font(.system(.body, design: .monospaced, weight: .semibold))
                                .foregroundStyle(Theme.primary)
                            InfoButton(
                                title: "Contour Interval",
                                message: "The vertical distance between adjacent contour lines. Smaller values (e.g. 0.1 m) produce denser, more detailed contours; larger values (e.g. 2.0 m) give a cleaner overview."
                            )
                        }
                    }
                    Slider(value: $settings.contourInterval, in: 0.1...2.0, step: 0.1)
                        .tint(Theme.primary)
                }

                cardDivider

                // ── Grid resolution ───────────────────────────────────────
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        settingLabel("Grid Resolution")
                        InfoButton(
                            title: "Grid Resolution",
                            message: "The cell size of the interpolation grid. Finer grids (0.25 m) capture more terrain detail but take longer to process. Use coarser grids (1.0 m) for quick previews over large areas."
                        )
                    }
                    HStack(spacing: 8) {
                        ForEach([0.25, 0.50, 1.00], id: \.self) { res in
                            Button {
                                settings.gridResolution = res
                            } label: {
                                Text(res == 0.25 ? "0.25m" : res == 0.50 ? "0.50m" : "1.00m")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundStyle(
                                        abs(settings.gridResolution - res) < 0.001
                                            ? Color(hex: "1E2B14")
                                            : Theme.onSurfaceVariant
                                    )
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        Group {
                                            if abs(settings.gridResolution - res) < 0.001 {
                                                RoundedRectangle(cornerRadius: 8)
                                                    .fill(Theme.primaryGradient)
                                            } else {
                                                RoundedRectangle(cornerRadius: 8)
                                                    .fill(Theme.surfaceContainerHigh)
                                            }
                                        }
                                    )
                            }
                        }
                    }
                }

                cardDivider

                // ── Interpolation method ──────────────────────────────────
                HStack {
                    settingLabel("Interpolation")
                    Spacer()
                    HStack(spacing: 6) {
                        Picker("", selection: $settings.interpolationMethod) {
                            ForEach(InterpolationMethod.allCases) { m in
                                Text(m.displayName).tag(m)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Theme.primary)
                        InfoButton(
                            title: "Interpolation Method",
                            message: "How elevation is estimated between your captured points. IDW (Inverse Distance Weighting) is fast and robust. Kriging uses statistical modelling and can be more accurate for uneven terrain, but is slower."
                        )
                    }
                }

                cardDivider

                // ── Geoid correction ──────────────────────────────────────
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        settingLabel("Geoid Correction")
                        Text("EGM2008 Gravitational Model")
                            .font(.subheadline)
                            .foregroundStyle(Theme.onSurfaceVariant)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Toggle("", isOn: $settings.enableGeoidCorrection)
                            .tint(Theme.primary)
                            .labelsHidden()
                        InfoButton(
                            title: "Geoid Correction",
                            message: "GPS reports height above a mathematical ellipsoid, not mean sea level. EGM96 converts that to orthometric (sea-level) height. Keep enabled unless you need raw ellipsoidal values."
                        )
                    }
                }

                cardDivider

                // ── Outlier threshold ─────────────────────────────────────
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        settingLabel("Outlier Threshold")
                        Spacer()
                        HStack(spacing: 6) {
                            Text(String(format: "%.1f σ", settings.madThreshold))
                                .font(.system(.body, design: .monospaced, weight: .semibold))
                                .foregroundStyle(Theme.primary)
                            InfoButton(
                                title: "Outlier Threshold",
                                message: "Controls how aggressively suspect points are removed. The value is in standard deviations (σ) — lower means stricter. Raise this if good points are being removed."
                            )
                        }
                    }
                    Slider(value: $settings.madThreshold, in: 2.0...6.0, step: 0.5)
                        .tint(Theme.primary)
                }
            }
        }
    }

    // MARK: - Elevation calibration card

    private var calibrationCard: some View {
        card {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        settingLabel("Apply Elevation Offset")
                        Text("Fixed vertical shift applied during processing")
                            .font(.subheadline)
                            .foregroundStyle(Theme.onSurfaceVariant)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Toggle("", isOn: $settings.elevationOffsetEnabled)
                            .tint(Theme.primary)
                            .labelsHidden()
                        InfoButton(
                            title: "Elevation Offset",
                            message: "Shifts all elevation values by a fixed amount. Use this when a known benchmark shows your GPS readings are consistently high or low — enter a negative value to lower elevations, positive to raise them."
                        )
                    }
                }

                if settings.elevationOffsetEnabled {
                    cardDivider

                    HStack {
                        Text("Vertical Delta (Z)")
                            .font(.subheadline)
                            .foregroundStyle(Theme.onSurfaceVariant)
                        Spacer()
                        HStack(spacing: 4) {
                            TextField("0.000", value: $settings.elevationOffset,
                                      format: .number.precision(.fractionLength(3)))
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                                .font(.system(.body, design: .monospaced, weight: .semibold))
                                .foregroundStyle(Theme.primary)
                            Text("m")
                                .font(.caption)
                                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.6))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    // MARK: - Export formats card

    private var exportCard: some View {
        VStack(spacing: 2) {
            ForEach(ExportFormat.allCases) { format in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(format.rawValue)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.onSurface)
                        Text(format.description)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.onSurfaceVariant)
                    }
                    Spacer()
                    Button {
                        if settings.selectedExportFormats.contains(format) {
                            settings.selectedExportFormats.remove(format)
                        } else {
                            settings.selectedExportFormats.insert(format)
                        }
                    } label: {
                        Image(systemName: settings.selectedExportFormats.contains(format)
                              ? "checkmark.circle.fill"
                              : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(
                                settings.selectedExportFormats.contains(format)
                                    ? Theme.primary
                                    : Theme.onSurfaceVariant.opacity(0.35)
                            )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Theme.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Display card

    private var displayCard: some View {
        card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    settingLabel("Show Outlier Points")
                    Text("Highlight statistically aberrant data on the map")
                        .font(.subheadline)
                        .foregroundStyle(Theme.onSurfaceVariant)
                }
                Spacer()
                HStack(spacing: 6) {
                    Toggle("", isOn: $settings.showOutliers)
                        .tint(Theme.primary)
                        .labelsHidden()
                    InfoButton(
                        title: "Show Outlier Points",
                        message: "Displays filtered-out points on the map as orange markers. Useful for verifying that the outlier filter isn't discarding valid data."
                    )
                }
            }
        }
    }
}

// MARK: - Info Button

private struct InfoButton: View {
    let title:   String
    let message: String
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(Theme.primary)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $show) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Button { show = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.title3)
                    }
                }
                ScrollView {
                    Text(message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .background(Theme.surfaceContainerHigh)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings())
        .environmentObject(ExportManager())
}
