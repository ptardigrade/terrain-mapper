// ARSurveyView.swift
// TerrainMapper
//
// UIViewRepresentable wrapping ARSCNView for the live AR survey interface.
//
// Rendered overlays:
//   • White sphere + flat billboard elevation label for each captured survey point
//   • Pulsing green beacon (torus + dot) at the live LiDAR target position
//   • Wireframe ground grid at beacon height (3D-scan-app style)
//   • Survey mesh wireframe connecting captured points
//   • Contour lines interpolated from captured elevations
//
// The ARSession is owned by LiDARManager and shared here.  ARSurveyView
// observes lidarManager.$arSession so updateUIView fires the moment the
// session becomes available (after startPreviewSession() is called).

import SwiftUI
import ARKit
import SceneKit

struct ARSurveyView: UIViewRepresentable {

    /// LiDARManager is ObservableObject — published arSession change drives updateUIView.
    @ObservedObject var lidarManager: LiDARManager

    /// Survey points to render as white dot anchors.
    var capturedPoints: [SurveyPoint]

    /// ARKit world-space positions keyed by point UUID string.
    /// Format: [x, z, y_ground] — y_ground is index 2 (optional, falls back to -1.2).
    var arkitPositions: [String: [Double]]

    var elevMin: Double
    var elevMax: Double

    // MARK: - UIViewRepresentable

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.delegate                    = context.coordinator
        view.scene                       = SCNScene()
        view.showsStatistics             = false
        view.automaticallyUpdatesLighting = true
        view.debugOptions                = []
        context.coordinator.sceneView    = view
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // Wire up LiDAR session when it becomes available (or changes).
        if let session = lidarManager.arSession, uiView.session !== session {
            uiView.session = session
            // New session means a new world origin — clear all old markers
            // from the previous survey to avoid stale nodes persisting.
            context.coordinator.clearAllPoints()
        }
        context.coordinator.updatePoints(
            capturedPoints,
            arkitPositions: arkitPositions,
            elevMin: elevMin,
            elevMax: elevMax
        )
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, ARSCNViewDelegate {

        weak var sceneView: ARSCNView?

        /// UUIDs of points already rendered as scene nodes — avoids duplicates.
        fileprivate(set) var renderedIDs = Set<String>()

        /// Stored ARKit 3D positions for mesh/contour computation.
        fileprivate(set) var arPoints: [(id: String, x: Float, y: Float, z: Float, elev: Double)] = []

        // MARK: - Overlay nodes

        fileprivate var groundGridNode: SCNNode?
        fileprivate var meshWireframeNode: SCNNode?
        fileprivate var contourLinesNode: SCNNode?

        // MARK: - Point management

        /// Removes all rendered survey point nodes and resets tracking state.
        func clearAllPoints() {
            guard let scene = sceneView?.scene else { return }
            for id in renderedIDs {
                scene.rootNode.childNode(withName: "pt_\(id)", recursively: false)?
                    .removeFromParentNode()
            }
            renderedIDs.removeAll()
            arPoints.removeAll()

            // Remove overlays
            beaconNode?.removeFromParentNode()
            beaconNode = nil
            groundGridNode?.removeFromParentNode()
            groundGridNode = nil
            meshWireframeNode?.removeFromParentNode()
            meshWireframeNode = nil
            contourLinesNode?.removeFromParentNode()
            contourLinesNode = nil
        }

        func updatePoints(
            _ points: [SurveyPoint],
            arkitPositions: [String: [Double]],
            elevMin: Double,
            elevMax: Double
        ) {
            guard let scene = sceneView?.scene else { return }

            // Remove nodes whose points were undone.
            let currentIDs = Set(points.map { $0.id.uuidString })
            for id in renderedIDs where !currentIDs.contains(id) {
                scene.rootNode.childNode(withName: "pt_\(id)", recursively: false)?
                    .removeFromParentNode()
                renderedIDs.remove(id)
                arPoints.removeAll { $0.id == id }
            }

            // Add nodes for new points.
            for point in points {
                let key = point.id.uuidString
                guard renderedIDs.insert(key).inserted else { continue }

                let pos  = arkitPositions[key] ?? []
                let x    = pos.count > 0 ? Float(pos[0]) : 0
                let z    = pos.count > 1 ? Float(pos[1]) : 0
                // y_ground is stored at index 2; fall back to ~1.2 m below camera origin.
                let y    = pos.count > 2 ? Float(pos[2]) : Float(-1.2)

                let node = makePointNode(
                    at: SCNVector3(x, y, z),
                    elevation: point.groundElevation,
                    elevMin: elevMin,
                    elevMax: elevMax
                )
                node.name = "pt_\(key)"
                scene.rootNode.addChildNode(node)

                arPoints.append((id: key, x: x, y: y, z: z, elev: point.groundElevation))
            }

            // Update mesh wireframe and contour lines when we have enough points.
            if arPoints.count >= 3 {
                updateSurveyMesh(scene: scene, elevMin: elevMin, elevMax: elevMax)
                updateContourLines(scene: scene, elevMin: elevMin, elevMax: elevMax)
            }
        }

        // MARK: - ARSCNViewDelegate

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            updateBeacon(renderer: renderer)
        }

        // MARK: - Point node builder (flat texture label)

        private func makePointNode(
            at position: SCNVector3,
            elevation: Double,
            elevMin: Double,
            elevMax: Double
        ) -> SCNNode {
            let root = SCNNode()
            root.position = position

            // White sphere marker
            let sphere = SCNSphere(radius: 0.035)
            sphere.firstMaterial?.diffuse.contents  = UIColor.white
            sphere.firstMaterial?.emission.contents = UIColor.white.withAlphaComponent(0.5)
            let sphereNode = SCNNode(geometry: sphere)
            root.addChildNode(sphereNode)

            // Flat billboard elevation label (replaces broken SCNText geometry)
            let label = String(format: "%.1fm", elevation)
            let color = viridisColor(fraction: elevFraction(elevation, min: elevMin, max: elevMax))
            let labelNode = makeTextPlaneNode(text: label, color: color)
            labelNode.position = SCNVector3(0, 0.15, 0) // 15 cm above dot

            let bb = SCNBillboardConstraint()
            bb.freeAxes = .all
            labelNode.constraints = [bb]
            root.addChildNode(labelNode)

            return root
        }

        /// Renders text into a UIImage, then maps it onto a small SCNPlane.
        /// This avoids SCNText's broken 3D geometry and produces crisp, readable labels.
        private func makeTextPlaneNode(text: String, color: UIColor) -> SCNNode {
            let fontSize: CGFloat = 48
            let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white
            ]
            let textSize = (text as NSString).size(withAttributes: attrs)

            let padding: CGFloat = 12
            let imgW = textSize.width + padding * 2
            let imgH = textSize.height + padding * 2

            UIGraphicsBeginImageContextWithOptions(CGSize(width: imgW, height: imgH), false, 2.0)
            defer { UIGraphicsEndImageContext() }

            // Semi-transparent dark background pill
            let ctx = UIGraphicsGetCurrentContext()!
            ctx.setFillColor(UIColor(white: 0.0, alpha: 0.65).cgColor)
            let rect = CGRect(x: 0, y: 0, width: imgW, height: imgH)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: imgH * 0.3)
            path.fill()

            // Colored left accent bar
            ctx.setFillColor(color.cgColor)
            let accentRect = CGRect(x: 4, y: imgH * 0.2, width: 4, height: imgH * 0.6)
            UIBezierPath(roundedRect: accentRect, cornerRadius: 2).fill()

            // Draw text
            let textRect = CGRect(x: padding, y: padding * 0.5, width: textSize.width, height: textSize.height)
            (text as NSString).draw(in: textRect, withAttributes: attrs)

            guard let image = UIGraphicsGetImageFromCurrentImageContext() else {
                return SCNNode()
            }

            // Map image to a plane sized for AR (roughly 12 cm wide)
            let aspect = imgW / imgH
            let planeH: CGFloat = 0.05
            let planeW = planeH * aspect
            let plane = SCNPlane(width: planeW, height: planeH)
            plane.firstMaterial?.diffuse.contents = image
            plane.firstMaterial?.isDoubleSided = true
            // Emissive so it's visible regardless of scene lighting
            plane.firstMaterial?.emission.contents = image
            plane.firstMaterial?.emission.intensity = 0.5
            plane.firstMaterial?.lightingModel = .constant

            return SCNNode(geometry: plane)
        }

        // MARK: - Ground Grid

        /// Creates or updates a wireframe grid at the beacon's ground level.
        fileprivate func updateGroundGrid(scene: SCNScene, groundY: Float, cameraX: Float, cameraZ: Float) {
            groundGridNode?.removeFromParentNode()

            let gridSize: Float = 4.0     // 4×4 metre grid
            let spacing: Float  = 0.25    // 25 cm cells

            var vertices: [SCNVector3] = []
            var indices: [UInt32] = []
            var idx: UInt32 = 0

            // Snap grid origin to spacing so it doesn't jitter as camera moves
            let snapX = (cameraX / spacing).rounded() * spacing
            let snapZ = (cameraZ / spacing).rounded() * spacing
            let halfGrid = gridSize / 2.0

            // Lines parallel to X axis
            var z = snapZ - halfGrid
            while z <= snapZ + halfGrid {
                vertices.append(SCNVector3(snapX - halfGrid, groundY, z))
                vertices.append(SCNVector3(snapX + halfGrid, groundY, z))
                indices.append(idx); indices.append(idx + 1)
                idx += 2
                z += spacing
            }

            // Lines parallel to Z axis
            var x = snapX - halfGrid
            while x <= snapX + halfGrid {
                vertices.append(SCNVector3(x, groundY, snapZ - halfGrid))
                vertices.append(SCNVector3(x, groundY, snapZ + halfGrid))
                indices.append(idx); indices.append(idx + 1)
                idx += 2
                x += spacing
            }

            guard !vertices.isEmpty else { return }

            let vertexData = Data(bytes: vertices, count: vertices.count * MemoryLayout<SCNVector3>.size)
            let vertexSource = SCNGeometrySource(
                data: vertexData,
                semantic: .vertex,
                vectorCount: vertices.count,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SCNVector3>.size
            )

            let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
            let element = SCNGeometryElement(
                data: indexData,
                primitiveType: .line,
                primitiveCount: indices.count / 2,
                bytesPerIndex: MemoryLayout<UInt32>.size
            )

            let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = UIColor(white: 1.0, alpha: 0.15)
            material.emission.contents = UIColor(white: 1.0, alpha: 0.15)
            material.lightingModel = .constant
            material.isDoubleSided = true
            geometry.materials = [material]

            let node = SCNNode(geometry: geometry)
            node.renderingOrder = -1
            scene.rootNode.addChildNode(node)
            groundGridNode = node
        }

        // MARK: - Survey Mesh Wireframe

        /// Builds a fan-triangulation wireframe connecting all captured points.
        private func updateSurveyMesh(scene: SCNScene, elevMin: Double, elevMax: Double) {
            meshWireframeNode?.removeFromParentNode()

            guard arPoints.count >= 3 else { return }

            // Sort points by angle from centroid for fan triangulation
            let cx = arPoints.map(\.x).reduce(0, +) / Float(arPoints.count)
            let cz = arPoints.map(\.z).reduce(0, +) / Float(arPoints.count)

            let sorted = arPoints.sorted { a, b in
                atan2(a.z - cz, a.x - cx) < atan2(b.z - cz, b.x - cx)
            }

            var vertices: [SCNVector3] = []
            var colors: [SCNVector3] = []
            var indices: [UInt32] = []
            var idx: UInt32 = 0

            // Create perimeter edges connecting sorted points
            for i in 0..<sorted.count {
                let j = (i + 1) % sorted.count
                let a = sorted[i]
                let b = sorted[j]

                vertices.append(SCNVector3(a.x, a.y, a.z))
                vertices.append(SCNVector3(b.x, b.y, b.z))

                let colA = viridisRGB(fraction: elevFraction(a.elev, min: elevMin, max: elevMax))
                let colB = viridisRGB(fraction: elevFraction(b.elev, min: elevMin, max: elevMax))
                colors.append(colA)
                colors.append(colB)

                indices.append(idx); indices.append(idx + 1)
                idx += 2
            }

            guard !vertices.isEmpty else { return }

            let vertexData = Data(bytes: vertices, count: vertices.count * MemoryLayout<SCNVector3>.size)
            let vertexSource = SCNGeometrySource(
                data: vertexData,
                semantic: .vertex,
                vectorCount: vertices.count,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SCNVector3>.size
            )

            let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<SCNVector3>.size)
            let colorSource = SCNGeometrySource(
                data: colorData,
                semantic: .color,
                vectorCount: colors.count,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SCNVector3>.size
            )

            let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
            let element = SCNGeometryElement(
                data: indexData,
                primitiveType: .line,
                primitiveCount: indices.count / 2,
                bytesPerIndex: MemoryLayout<UInt32>.size
            )

            let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.isDoubleSided = true
            geometry.materials = [material]

            let node = SCNNode(geometry: geometry)
            scene.rootNode.addChildNode(node)
            meshWireframeNode = node
        }

        // MARK: - Contour Lines

        /// Generates contour iso-lines by marching through triangle edges.
        private func updateContourLines(scene: SCNScene, elevMin: Double, elevMax: Double) {
            contourLinesNode?.removeFromParentNode()

            guard arPoints.count >= 3 else { return }

            let elevRange = elevMax - elevMin
            guard elevRange > 0.01 else { return }

            // Determine contour interval — aim for 3–8 lines
            let interval: Double
            if elevRange < 0.5 { interval = 0.1 }
            else if elevRange < 2.0 { interval = 0.25 }
            else if elevRange < 5.0 { interval = 0.5 }
            else { interval = 1.0 }

            // Build triangles (fan from centroid)
            let cx = arPoints.map(\.x).reduce(0, +) / Float(arPoints.count)
            let cz = arPoints.map(\.z).reduce(0, +) / Float(arPoints.count)

            let sorted = arPoints.sorted { a, b in
                atan2(a.z - cz, a.x - cx) < atan2(b.z - cz, b.x - cx)
            }

            let cy = arPoints.map(\.y).reduce(0, +) / Float(arPoints.count)
            let cElev = arPoints.map(\.elev).reduce(0, +) / Double(arPoints.count)

            // Build triangle list: each triangle = centroid + two adjacent perimeter points
            var triPts: [(x: Float, y: Float, z: Float, e: Double)] = []
            // Store as flat array of triples: [p0,p1,p2, p0,p1,p2, ...]
            for i in 0..<sorted.count {
                let j = (i + 1) % sorted.count
                let a = sorted[i]
                let b = sorted[j]
                triPts.append((cx, cy, cz, cElev))
                triPts.append((a.x, a.y, a.z, a.elev))
                triPts.append((b.x, b.y, b.z, b.elev))
            }

            var contourVerts: [SCNVector3] = []
            var contourColors: [SCNVector3] = []
            var contourIndices: [UInt32] = []
            var cIdx: UInt32 = 0

            // March through each contour level
            var level = (elevMin / interval).rounded(.up) * interval
            while level <= elevMax {
                let frac = elevFraction(level, min: elevMin, max: elevMax)
                let rgb = viridisRGB(fraction: frac)

                // Process each triangle
                var ti = 0
                while ti < triPts.count {
                    let pts = [triPts[ti], triPts[ti + 1], triPts[ti + 2]]
                    ti += 3

                    var crossings: [(Float, Float, Float)] = []

                    for ei in 0..<3 {
                        let ej = (ei + 1) % 3
                        let e0 = pts[ei].e
                        let e1 = pts[ej].e
                        guard (e0 - level) * (e1 - level) < 0 else { continue }

                        let t = Float((level - e0) / (e1 - e0))
                        let ix = pts[ei].x + t * (pts[ej].x - pts[ei].x)
                        let iy = pts[ei].y + t * (pts[ej].y - pts[ei].y)
                        let iz = pts[ei].z + t * (pts[ej].z - pts[ei].z)
                        crossings.append((ix, iy, iz))
                    }

                    if crossings.count == 2 {
                        contourVerts.append(SCNVector3(crossings[0].0, crossings[0].1, crossings[0].2))
                        contourVerts.append(SCNVector3(crossings[1].0, crossings[1].1, crossings[1].2))
                        contourColors.append(rgb)
                        contourColors.append(rgb)
                        contourIndices.append(cIdx); contourIndices.append(cIdx + 1)
                        cIdx += 2
                    }
                }
                level += interval
            }

            guard !contourVerts.isEmpty else { return }

            let vertexData = Data(bytes: contourVerts, count: contourVerts.count * MemoryLayout<SCNVector3>.size)
            let vertexSource = SCNGeometrySource(
                data: vertexData,
                semantic: .vertex,
                vectorCount: contourVerts.count,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SCNVector3>.size
            )

            let colorData = Data(bytes: contourColors, count: contourColors.count * MemoryLayout<SCNVector3>.size)
            let colorSource = SCNGeometrySource(
                data: colorData,
                semantic: .color,
                vectorCount: contourColors.count,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SCNVector3>.size
            )

            let indexData = Data(bytes: contourIndices, count: contourIndices.count * MemoryLayout<UInt32>.size)
            let element = SCNGeometryElement(
                data: indexData,
                primitiveType: .line,
                primitiveCount: contourIndices.count / 2,
                bytesPerIndex: MemoryLayout<UInt32>.size
            )

            let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.isDoubleSided = true
            geometry.materials = [material]

            let node = SCNNode(geometry: geometry)
            node.renderingOrder = 1
            scene.rootNode.addChildNode(node)
            contourLinesNode = node
        }

        // MARK: - Color helpers

        private func elevFraction(_ elev: Double, min eMin: Double, max eMax: Double) -> Double {
            guard eMax > eMin else { return 0.5 }
            return Swift.max(0, Swift.min(1, (elev - eMin) / (eMax - eMin)))
        }

        /// Viridis-inspired colour ramp for AR overlays (UIColor).
        private func viridisColor(fraction: Double) -> UIColor {
            let rgb = viridisRGB(fraction: fraction)
            return UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1.0)
        }

        /// Viridis-inspired colour ramp as SCNVector3 (r,g,b in 0…1).
        private func viridisRGB(fraction: Double) -> SCNVector3 {
            let f = Float(fraction)
            // Simplified viridis: purple → teal → yellow
            let r: Float = f < 0.5 ? 0.27 + f * 0.2 : 0.1 + f * 1.4
            let g: Float = 0.1 + f * 0.8
            let b: Float = f < 0.5 ? 0.5 + f * 0.3 : 0.9 - f * 0.8
            return SCNVector3(
                Swift.min(1, Swift.max(0, r)),
                Swift.min(1, Swift.max(0, g)),
                Swift.min(1, Swift.max(0, b))
            )
        }

        // MARK: - Beacon

        private var beaconNode: SCNNode?

        private func updateBeacon(renderer: SCNSceneRenderer) {
            guard let scnView   = renderer as? ARSCNView,
                  let frame     = scnView.session.currentFrame,
                  let depthMap  = frame.sceneDepth?.depthMap else {
                DispatchQueue.main.async { self.beaconNode?.isHidden = true }
                return
            }

            // Sample the centre pixel of the LiDAR depth map.
            let w = CVPixelBufferGetWidth(depthMap)
            let h = CVPixelBufferGetHeight(depthMap)
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            let base        = CVPixelBufferGetBaseAddress(depthMap)!
                .assumingMemoryBound(to: Float32.self)
            let bpr         = CVPixelBufferGetBytesPerRow(depthMap)
            let centerDepth = base[(h / 2) * (bpr / MemoryLayout<Float32>.size) + w / 2]
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)

            guard centerDepth > 0.1, centerDepth < 8.0 else {
                DispatchQueue.main.async { self.beaconNode?.isHidden = true }
                return
            }

            // Project centre ray to world space
            let cam     = frame.camera.transform
            let forward = simd_float3(-cam.columns.2.x, -cam.columns.2.y, -cam.columns.2.z)
            let origin  = simd_float3( cam.columns.3.x,  cam.columns.3.y,  cam.columns.3.z)
            let hit     = origin + forward * centerDepth

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let scene = scnView.scene
                if self.beaconNode == nil {
                    self.beaconNode = self.makeBeaconNode()
                    scene.rootNode.addChildNode(self.beaconNode!)
                }
                self.beaconNode?.position = SCNVector3(hit.x, hit.y, hit.z)
                self.beaconNode?.isHidden = false

                // Update ground grid around camera position at beacon ground level
                self.updateGroundGrid(
                    scene: scene,
                    groundY: hit.y,
                    cameraX: origin.x,
                    cameraZ: origin.z
                )
            }
        }

        private func makeBeaconNode() -> SCNNode {
            let root = SCNNode()

            // Outer torus ring
            let ring = SCNTorus(ringRadius: 0.10, pipeRadius: 0.007)
            ring.firstMaterial?.diffuse.contents  = UIColor(red: 0.23, green: 0.87, blue: 0.67, alpha: 0.9)
            ring.firstMaterial?.emission.contents = UIColor(red: 0.23, green: 0.87, blue: 0.67, alpha: 0.6)
            root.addChildNode(SCNNode(geometry: ring))

            // Centre dot
            let dot = SCNSphere(radius: 0.025)
            dot.firstMaterial?.diffuse.contents  = UIColor(red: 0.23, green: 0.87, blue: 0.67, alpha: 1.0)
            dot.firstMaterial?.emission.contents = UIColor(red: 0.23, green: 0.87, blue: 0.67, alpha: 0.8)
            root.addChildNode(SCNNode(geometry: dot))

            // Pulsing scale animation
            let pulse            = CABasicAnimation(keyPath: "scale")
            pulse.fromValue      = NSValue(scnVector3: SCNVector3(1, 1, 1))
            pulse.toValue        = NSValue(scnVector3: SCNVector3(1.4, 1.4, 1.4))
            pulse.duration       = 0.9
            pulse.autoreverses   = true
            pulse.repeatCount    = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            root.addAnimation(pulse, forKey: "pulse")

            // Billboard so the ring always faces the camera
            let bb       = SCNBillboardConstraint()
            bb.freeAxes  = .all
            root.constraints = [bb]

            return root
        }
    }
}
