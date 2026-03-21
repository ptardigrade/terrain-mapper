import Foundation

final class OBJExporter {

    func export(terrain: ProcessedTerrain, baseName: String = "terrain") throws -> (obj: Data, mtl: Data) {
        let mesh = terrain.mesh

        guard !mesh.vertices.isEmpty else {
            throw ExportError.invalidTerrain
        }

        let elevationMin = mesh.elevationMin
        let elevationMax = mesh.elevationMax
        let elevationRange = elevationMax - elevationMin

        var objString = ""

        objString += "# TerrainMapper export\n"
        objString += "mtllib \(baseName).mtl\n"
        objString += "g terrain\n"

        for vertex in mesh.vertices {
            objString += String(format: "v %.6f %.6f %.6f\n", vertex.x, vertex.y, vertex.z)
        }

        for vertex in mesh.vertices {
            objString += String(format: "vn %.6f %.6f %.6f\n", vertex.nx, vertex.ny, vertex.nz)
        }

        for vertex in mesh.vertices {
            let normalizedElevation = elevationRange > 0
                ? (vertex.elevation - elevationMin) / elevationRange
                : 0.5
            objString += String(format: "vt %.6f 0.0\n", normalizedElevation)
        }

        objString += "usemtl elevation\n"
        for triangle in mesh.triangles {
            let v1 = triangle.i0 + 1
            let v2 = triangle.i1 + 1
            let v3 = triangle.i2 + 1

            objString += "f \(v1)/\(v1)/\(v1) \(v2)/\(v2)/\(v2) \(v3)/\(v3)/\(v3)\n"
        }

        let mtlString = "newmtl elevation\nKa 0.2 0.2 0.2\nKd 0.8 0.8 0.8\nKs 0.1 0.1 0.1\nNs 10.0\n"

        guard let objData = objString.data(using: .utf8),
              let mtlData = mtlString.data(using: .utf8) else {
            throw ExportError.invalidTerrain
        }

        return (obj: objData, mtl: mtlData)
    }
}
