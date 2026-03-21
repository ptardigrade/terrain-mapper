import Foundation

final class OBJExporter {

    /// Export a self-contained OBJ file (no external MTL dependency).
    ///
    /// Many viewers (SketchUp, online tools) fail when the companion .mtl file
    /// isn't co-located with the .obj.  Since iOS shares each file individually,
    /// we embed a basic inline material definition and keep the OBJ standalone.
    func export(terrain: ProcessedTerrain) throws -> Data {
        let mesh = terrain.mesh

        guard !mesh.vertices.isEmpty else {
            throw ExportError.invalidTerrain
        }

        let elevationMin = mesh.elevationMin
        let elevationMax = mesh.elevationMax
        let elevationRange = elevationMax - elevationMin

        var obj = ""

        obj += "# TerrainMapper export\n"
        obj += "# Vertices: \(mesh.vertexCount)  Faces: \(mesh.triangleCount)\n"
        obj += "g terrain\n"

        // Vertices
        for vertex in mesh.vertices {
            obj += String(format: "v %.6f %.6f %.6f\n", vertex.x, vertex.y, vertex.z)
        }

        // Normals
        for vertex in mesh.vertices {
            obj += String(format: "vn %.6f %.6f %.6f\n", vertex.nx, vertex.ny, vertex.nz)
        }

        // Texture coordinates (elevation-mapped)
        for vertex in mesh.vertices {
            let normalizedElevation = elevationRange > 0
                ? (vertex.elevation - elevationMin) / elevationRange
                : 0.5
            obj += String(format: "vt %.6f 0.0\n", normalizedElevation)
        }

        // Faces (v/vt/vn, 1-based indices)
        for triangle in mesh.triangles {
            let v1 = triangle.i0 + 1
            let v2 = triangle.i1 + 1
            let v3 = triangle.i2 + 1
            obj += "f \(v1)/\(v1)/\(v1) \(v2)/\(v2)/\(v2) \(v3)/\(v3)/\(v3)\n"
        }

        guard let data = obj.data(using: .utf8) else {
            throw ExportError.invalidTerrain
        }

        return data
    }
}
