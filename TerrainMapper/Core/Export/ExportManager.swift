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

        // Create the output folder on the main actor (needs FileManager, fine for metadata ops).
        let exportFolder = try createExportFolder()
        let sortedFormats = formats.sorted { $0.rawValue < $1.rawValue }

        // Dispatch all heavy encoding + disk I/O to a background thread so the UI
        // stays responsive during large GeoTIFF / LAS / PLY generation.
        let result: Result<[URL], Error> = await Task.detached(priority: .userInitiated) {
            var urls: [URL] = []
            for format in sortedFormats {
                do {
                    let url = try ExportManager.exportFormatStatic(format, terrain: terrain, to: exportFolder)
                    urls.append(url)
                } catch {
                    return .failure(ExportError.writeFailure(exportFolder, error))
                }
            }
            return .success(urls)
        }.value

        isExporting = false

        switch result {
        case .success(let urls):
            // Update progress to 1.0 on main actor after all formats complete.
            exportProgress = 1.0
            lastExportURLs = urls
            return urls
        case .failure(let error):
            throw error
        }
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

    /// Sanitise a session name for use in filenames (remove filesystem-unsafe characters).
    private nonisolated static func safeFileName(from sessionName: String) -> String {
        let trimmed = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "terrain" }
        // Replace characters that are unsafe in filenames
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-"))
        let safe = trimmed.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        // Collapse multiple underscores and trim
        let collapsed = safe.replacingOccurrences(of: "_{2,}", with: "_", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_ "))
    }

    /// Static variant — callable from a `Task.detached` without actor context.
    @discardableResult
    private nonisolated static func exportFormatStatic(_ format: ExportFormat, terrain: ProcessedTerrain, to folder: URL) throws -> URL {
        let baseName = safeFileName(from: terrain.session.name)
        let fileName: String
        let data: Data

        switch format {
        case .ply:
            fileName = "\(baseName).ply"
            let exporter = PLYExporter()
            data = try exporter.export(terrain: terrain)

        case .las:
            fileName = "\(baseName).las"
            let exporter = LASExporter()
            data = try exporter.export(terrain: terrain)

        case .geoJSON:
            fileName = "\(baseName).geojson"
            let exporter = GeoJSONExporter()
            data = try exporter.export(terrain: terrain)

        case .geoTIFF:
            fileName = "\(baseName).tif"
            let exporter = GeoTIFFExporter()
            data = try exporter.export(terrain: terrain)

        case .obj:
            fileName = "\(baseName).obj"
            let exporter = OBJExporter()
            data = try exporter.export(terrain: terrain)

        case .csv:
            fileName = "\(baseName).csv"
            let exporter = CSVExporter()
            data = try exporter.export(terrain: terrain)
        }

        let fileURL = folder.appendingPathComponent(fileName)
        try data.write(to: fileURL)
        return fileURL
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}
