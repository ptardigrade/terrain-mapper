import Foundation

final class PLYExporter {

    func export(terrain: ProcessedTerrain) throws -> Data {
        var plyData = Data()

        let vertices = terrain.mesh.vertices
        let triangles = terrain.mesh.triangles

        guard !vertices.isEmpty else {
            throw ExportError.invalidTerrain
        }

        let header = buildHeader(vertexCount: vertices.count, faceCount: triangles.count)
        plyData.append(contentsOf: header.utf8)

        let elevationMin = terrain.mesh.elevationMin
        let elevationMax = terrain.mesh.elevationMax
        let elevationRange = elevationMax - elevationMin

        for vertex in vertices {
            let normalizedElevation = elevationRange > 0
                ? (vertex.elevation - elevationMin) / elevationRange
                : 0.5

            let (r, g, b) = viridisColor(value: normalizedElevation)

            let line = String(format: "%.6f %.6f %.6f %d %d %d\n",
                              vertex.x, vertex.y, vertex.z,
                              Int(r), Int(g), Int(b))
            plyData.append(contentsOf: line.utf8)
        }

        for triangle in triangles {
            let line = "3 \(triangle.i0) \(triangle.i1) \(triangle.i2)\n"
            plyData.append(contentsOf: line.utf8)
        }

        return plyData
    }

    private func buildHeader(vertexCount: Int, faceCount: Int) -> String {
        // Notes:
        // - Trailing \n after end_header is critical (parsers reject without it).
        // - `vertex_indices` (plural) is more widely supported than `vertex_index`.
        // - comment line helps identify the source.
        var h = "ply\n"
        h += "format ascii 1.0\n"
        h += "comment TerrainMapper export\n"
        h += "element vertex \(vertexCount)\n"
        h += "property float x\n"
        h += "property float y\n"
        h += "property float z\n"
        h += "property uchar red\n"
        h += "property uchar green\n"
        h += "property uchar blue\n"
        h += "element face \(faceCount)\n"
        h += "property list uchar int vertex_indices\n"
        h += "end_header\n"
        return h
    }

    private func viridisColor(value: Double) -> (red: Double, green: Double, blue: Double) {
        let clamped = max(0.0, min(1.0, value))

        if clamped < 0.5 {
            let t = clamped * 2
            let colorLow = (red: 0.267, green: 0.004, blue: 0.329)
            let colorMid = (red: 0.129, green: 0.565, blue: 0.553)

            let r = colorLow.red + (colorMid.red - colorLow.red) * t
            let g = colorLow.green + (colorMid.green - colorLow.green) * t
            let b = colorLow.blue + (colorMid.blue - colorLow.blue) * t

            return (r * 255, g * 255, b * 255)
        } else {
            let t = (clamped - 0.5) * 2
            let colorMid = (red: 0.129, green: 0.565, blue: 0.553)
            let colorHigh = (red: 0.993, green: 0.906, blue: 0.144)

            let r = colorMid.red + (colorHigh.red - colorMid.red) * t
            let g = colorMid.green + (colorHigh.green - colorMid.green) * t
            let b = colorMid.blue + (colorHigh.blue - colorMid.blue) * t

            return (r * 255, g * 255, b * 255)
        }
    }
}
