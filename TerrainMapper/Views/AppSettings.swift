// AppSettings.swift
// TerrainMapper
//
// Observable settings object shared across the app via @EnvironmentObject.
// Persisted to UserDefaults so choices survive app restarts.

import Foundation
import Combine
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {

    // MARK: - Processing

    /// Contour interval in metres.
    @AppStorage("contourInterval") var contourInterval: Double = 0.5

    /// Grid cell size in metres.
    @AppStorage("gridResolution") var gridResolution: Double = 0.5

    /// Interpolation method.
    @AppStorage("interpolationMethod") private var interpolationMethodRaw: String = "IDW"
    var interpolationMethod: InterpolationMethod {
        get { InterpolationMethod(rawValue: interpolationMethodRaw) ?? .idw }
        set { interpolationMethodRaw = newValue.rawValue }
    }

    /// Apply EGM96 geoid correction (GPS ellipsoidal → orthometric/MSL altitude).
    @AppStorage("enableGeoidCorrection") var enableGeoidCorrection: Bool = true

    /// MAD threshold for outlier detection.
    @AppStorage("madThreshold") var madThreshold: Double = 3.5

    // MARK: - Diagnostic

    /// When enabled, survey capture point elevations are flattened to the median
    /// of non-capture sources (path track / AR mesh) before interpolation.
    /// Useful for diagnosing whether elevation spikes in the 3D model originate
    /// from the captured survey points.
    @AppStorage("excludePointElevation") var excludePointElevation: Bool = false

    // MARK: - Export

    /// Persisted comma-separated raw values of the selected export formats.
    /// Stored as a plain string so @AppStorage can handle it directly.
    @AppStorage("selectedExportFormatsRaw") private var selectedExportFormatsRaw: String = "geoJSON,csv"

    /// Which formats are selected for the next export.
    /// Computed from the persisted string so the selection survives app restarts.
    var selectedExportFormats: Set<ExportFormat> {
        get {
            Set(selectedExportFormatsRaw
                .split(separator: ",")
                .compactMap { ExportFormat(rawValue: String($0)) })
        }
        set {
            selectedExportFormatsRaw = newValue
                .map(\.rawValue)
                .sorted()
                .joined(separator: ",")
        }
    }

    // MARK: - Display

    /// Show outlier points on the map (faded).
    @AppStorage("showOutliers") var showOutliers: Bool = true

    // MARK: - Apply to pipeline

    /// Configure a ProcessingPipeline with the current settings.
    func configure(_ pipeline: ProcessingPipeline) {
        pipeline.contourInterval     = contourInterval
        pipeline.gridResolution      = gridResolution
        pipeline.interpolationMethod = interpolationMethod
        pipeline.enableGeoidCorrection = enableGeoidCorrection
        pipeline.madThreshold        = madThreshold
        pipeline.excludePointElevation = excludePointElevation
    }
}
