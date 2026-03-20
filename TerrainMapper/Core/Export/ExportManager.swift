import Foundation

enum ExportError: LocalizedError {
    case formatNotSupported(ExportFormat)
    case writeFailure(URL, Error)
    case invalidTerrain
    case fileSystemError(String)

    var errorDescription: String? {
        switch self {
        case .formatNotSupported(let format):
            return "Export format \(format.rawValue) is not supported"
        case .writeFailure(let url, let error):
            return "Failed to write file at \(url.lastPathComponent): \(error.localizedDescription)"
        case .invalidTerrain:
            return "The terrain data is invalid or empty"
        case .fileSystemError(let message):
            return "File system error: \(message)"
        }
    }
}

@MainActor
final class ExportManager: ObservableObject {
    @Published private(set) var isExporting: Bool = false
    @Published private(set) var exportProgress: Double = 0.0
    @Published private(set) var lastExportURLs: [URL] = []

    private let fileManager = FileManager.default

    func export(terrain: ProcessedTerrain, formats: Set<ExportFormat>) async throws -> [URL] {
        guard !formats.isEmpty else {
            throw ExportError.fileSystemError("No export formats specified")
        }

        isExporting = true
        exportProgress = 0.0
        defer { isExporting = false }

        let exportFolder = try createExportFolder()
        var exportedURLs: [URL] = []

        let sortedFormats = formats.sorted { $0.rawValue < $1.rawValue }

        for (index, format) in sortedFormats.enumerated() {
            do {
                let url = try exportFormat(format, terrain: terrain, to: exportFolder)
                exportedURLs.append(url)
            } catch {
                throw ExportError.writeFailure(exportFolder, error)
            }

            exportProgress = Double(index + 1) / Double(sortedFormats.count)
        }

        lastExportURLs = exportedURLs
        return exportedURLs
    }

    func shareURL(for urls: [URL]) -> URL? {
        guard !urls.isEmpty else {
            return nil
        }

        if urls.count == 1 {
            return urls[0]
        }

        if let folderURL = urls.first?.deletingLastPathComponent() {
            return folderURL
        }

        return nil
    }

    private func createExportFolder() throws -> URL {
        let documentURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let terrainMapperURL = documentURL.appendingPathComponent("TerrainMapper")
        let exportURL = terrainMapperURL.appendingPathComponent("Export_\(timestamp())")

        try fileManager.createDirectory(at: exportURL, withIntermediateDirectories: true)
        return exportURL
    }

    private func exportFormat(_ format: ExportFormat, terrain: ProcessedTerrain, to folder: URL) throws {
        let fileName: String
        let data: Data

        switch format {
        case .ply:
            fileName = "terrain.ply"
            let exporter = PLYExporter()
            data = try exporter.export(terrain: terrain)

        case .las:
            fileName = "terrain.las"
            let exporter = LASExporter()
            data = try exporter.export(terrain: terrain)

        case .geoJSON:
            fileName = "terrain.geojson"
            let exporter = GeoJSONExporter()
            data = try exporter.export(terrain: terrain)

        case .geoTIFF:
            fileName = "elevation.tif"
            let exporter = GeoTIFFExporter()
            data = try exporter.export(terrain: terrain)

        case .obj:
            fileName = "terrain.obj"
            let exporter = OBJExporter()
            let (objData, mtlData) = try exporter.export(terrain: terrain)

            let objURL = folder.appendingPathComponent(fileName)
            try objData.write(to: objURL)

            let mtlURL = folder.appendingPathComponent("terrain.mtl")
            try mtlData.write(to: mtlURL)

            return

        case .csv:
            fileName = "survey_points.csv"
            let exporter = CSVExporter()
            data = try exporter.export(terrain: terrain)
        }

        let fileURL = folder.appendingPathComponent(fileName)
        try data.write(to: fileURL)
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}
