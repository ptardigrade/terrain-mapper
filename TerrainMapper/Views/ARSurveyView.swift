// ARSurveyView.swift
// TerrainMapper
//
// UIViewRepresentable wrapping ARSCNView for the live AR survey interface.
//
// Rendered overlays:
//   • White sphere + flat billboard elevation label for each captured survey point
//   • Pulsing green beacon (torus + dot) at the live LiDAR target position
//   • ARKit mesh wireframe overlay (like 3D scanner apps — grows as user scans)
//   • Elevation contour iso-lines computed from the ARKit mesh surface
//
// Labels are dynamically updated when differential elevations are recalculated —
// correctedElevations map is refreshed each time a new point is added or GPS locks.
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

    /// Differential-corrected elevations keyed by point UUID string.
    /// When provided, these override point.groundElevation for AR label display.
    var correctedElevations: [String: Double]

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
            correctedElevations: correctedElevations,
            elevMin: elevMin,
            elevMax: elevMax
        )
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, ARSCNViewDelegate {

        weak var sceneView: ARSCNView?

        /// UUIDs of points already rendered as scene nodes — avoids duplicates.
        fileprivate(set) var renderedIDs = Set<String>()

        /// Tracks the label node child inside each point node, keyed by UUID,
        /// so we can update labels dynamically when elevations are recalculated.
        fileprivate var labelNodes: [String: SCNNode] = [:]

        /// Last known elevations per point — used to detect when a label needs updating.
        fileprivate var lastKnownElevations: [String: Double] = [:]

        // MARK: - Overlay nodes

        fileprivate var contourLinesNode: SCNNode?

        // MARK: - Mesh contour throttle state

        private var lastMeshContourTime: TimeInterval = 0
        private var isComputingContours: Bool = false

        // MARK: - Mesh wireframe material (reused across all mesh anchor nodes)

        private let meshWireframeMaterial: SCNMaterial = {
            let mat = SCNMaterial()
            mat.fillMode = .lines
            mat.diffuse.contents = UIColor(red: 0.25, green: 0.95, blue: 0.65, alpha: 0.55)
            mat.emission.contents = UIColor(red: 0.25, green: 0.95, blue: 0.65, alpha: 0.7)
            mat.emission.intensity = 0.8
            mat.lightingModel = .constant
            mat.isDoubleSided = true
            mat.readsFromDepthBuffer = true
            mat.writesToDepthBuffer = false
            return mat
        }()

        // MARK: - Point management

        /// Removes all rendered survey point nodes and resets tracking state.
        func clearAllPoints() {
            guard let scene = sceneView?.scene else { return }
            for id in renderedIDs {
                scene.rootNode.childNode(withName: "pt_\(id)", recursively: false)?
                    .removeFromParentNode()
            }
            renderedIDs.removeAll()
            labelNodes.removeAll()
            lastKnownElevations.removeAll()

            // Remove overlays
            beaconNode?.removeFromParentNode()
            beaconNode = nil
            contourLinesNode?.removeFromParentNode()
            contourLinesNode = nil
        }

        func updatePoints(
            _ points: [SurveyPoint],
            arkitPositions: [String: [Double]],
            correctedElevations: [String: Double],
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
                labelNodes.removeValue(forKey: id)
                lastKnownElevations.removeValue(forKey: id)
            }

            // Add nodes for new points, and update labels on existing ones.
            for point in points {
                let key = point.id.uuidString
                let displayElev = correctedElevations[key] ?? point.groundElevation

                if renderedIDs.insert(key).inserted {
                    // Brand new point — create node
                    let pos  = arkitPositions[key] ?? []
                    let x    = pos.count > 0 ? Float(pos[0]) : 0
                    let z    = pos.count > 1 ? Float(pos[1]) : 0
                    let y    = pos.count > 2 ? Float(pos[2]) : Float(-1.2)

                    let node = makePointNode(
                        at: SCNVector3(x, y, z),
                        elevation: displayElev,
                        elevMin: elevMin,
                        elevMax: elevMax,
                        pointID: key
                    )
                    node.name = "pt_\(key)"
                    scene.rootNode.addChildNode(node)

                    lastKnownElevations[key] = displayElev
                } else {
                    // Existing point — check if elevation changed and update label
                    let previousElev = lastKnownElevations[key] ?? displayElev
                    if abs(previousElev - displayElev) > 0.01 {
                        if let existingLabel = labelNodes[key] {
                            let label = String(format: "%.1fm", displayElev)
                            let color = viridisColor(fraction: elevFraction(displayElev, min: elevMin, max: elevMax))
                            let newLabel = makeTextPlaneNode(text: label, color: color)
                            newLabel.position = existingLabel.position
                            newLabel.constraints = existingLabel.constraints
                            existingLabel.parent?.replaceChildNode(existingLabel, with: newLabel)
                            labelNodes[key] = newLabel
                        }
                        lastKnownElevations[key] = displayElev
                    }
                }
            }
        }

        // MARK: - ARSCNViewDelegate

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            updateBeacon(renderer: renderer)
            updateMeshContours(renderer: renderer, time: time)
        }

        /// Provide a wireframe node for each ARMeshAnchor added by ARKit's
        /// scene reconstruction.  This is the "3D scanner app" overlay that
        /// grows as the user scans more of the environment.
        func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
            let node = SCNNode()
            node.geometry = Self.makeMeshWireframeGeometry(from: meshAnchor)
            node.geometry?.materials = [meshWireframeMaterial]
            node.renderingOrder = 0   // Render as AR overlay on camera feed
            return node
        }

        /// Update the wireframe geometry when ARKit refines the mesh.
        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return }
            node.geometry = Self.makeMeshWireframeGeometry(from: meshAnchor)
            node.geometry?.materials = [meshWireframeMaterial]
            node.renderingOrder = 0
        }

        // MARK: - Mesh wireframe geometry

        /// Creates SCNGeometry from an ARMeshAnchor using Metal buffer pass-through.
        /// The triangles are rendered as wireframe via the material's fillMode = .lines.
        private static func makeMeshWireframeGeometry(from meshAnchor: ARMeshAnchor) -> SCNGeometry {
            let geo = meshAnchor.geometry

            let vertexSource = SCNGeometrySource(
                buffer: geo.vertices.buffer,
                vertexFormat: geo.vertices.format,
                semantic: .vertex,
                vertexCount: geo.vertices.count,
                dataOffset: geo.vertices.offset,
                dataStride: geo.vertices.stride
            )

            let faceElement = SCNGeometryElement(
                buffer: geo.faces.buffer,
                primitiveType: .triangles,
                primitiveCount: geo.faces.count,
                bytesPerIndex: geo.faces.bytesPerIndex
            )

            return SCNGeometry(sources: [vertexSource], elements: [faceElement])
        }

        // MARK: - Mesh-based contour lines

        /// Periodically computes elevation contour iso-lines from all ARKit mesh
        /// anchors.  Heavy work is dispatched to a background queue.
        private func updateMeshContours(renderer: SCNSceneRenderer, time: TimeInterval) {
            guard !isComputingContours,
                  time - lastMeshContourTime > 2.0 else { return }
            lastMeshContourTime = time

            guard let scnView = renderer as? ARSCNView,
                  let frame = scnView.session.currentFrame else { return }

            let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            guard !meshAnchors.isEmpty else { return }

            isComputingContours = true

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let geometry = Self.computeMeshContourGeometry(from: meshAnchors)

                DispatchQueue.main.async { [weak self] in
                    guard let self, let scene = self.sceneView?.scene else {
                        self?.isComputingContours = false
                        return
                    }
                    self.isComputingContours = false

                    self.contourLinesNode?.removeFromParentNode()
                    if let geo = geometry {
                        let node = SCNNode(geometry: geo)
                        node.renderingOrder = 2  // Above mesh wireframe (0) and point markers (1)
                        scene.rootNode.addChildNode(node)
                        self.contourLinesNode = node
                    }
                }
            }
        }

        /// Computes contour iso-lines by marching through all ground-facing mesh
        /// triangles in world space.  Called on a background queue.
        private static func computeMeshContourGeometry(from anchors: [ARMeshAnchor]) -> SCNGeometry? {
            struct WorldTri {
                let a: simd_float3, b: simd_float3, c: simd_float3
            }

            var triangles: [WorldTri] = []
            var yMin: Float = .greatestFiniteMagnitude
            var yMax: Float = -.greatestFiniteMagnitude

            for anchor in anchors {
                let geo = anchor.geometry
                let transform = anchor.transform

                // Read vertices into world space
                let vBuf = geo.vertices.buffer.contents().advanced(by: geo.vertices.offset)
                var verts: [simd_float3] = []
                verts.reserveCapacity(geo.vertices.count)
                for i in 0..<geo.vertices.count {
                    let ptr = vBuf.advanced(by: i * geo.vertices.stride)
                        .assumingMemoryBound(to: SIMD3<Float>.self)
                    let p = ptr.pointee
                    let local = simd_float4(p.x, p.y, p.z, 1)
                    let world = transform * local
                    verts.append(simd_float3(world.x, world.y, world.z))
                }

                // Read faces, keep only ground-facing triangles (normal Y > 0.5)
                let fBuf = geo.faces.buffer.contents()
                let bpi = geo.faces.bytesPerIndex
                let icpp = geo.faces.indexCountPerPrimitive
                for i in 0..<geo.faces.count {
                    let offset = i * icpp * bpi
                    let a, b, c: Int
                    if bpi == 4 {
                        let ptr = fBuf.advanced(by: offset).assumingMemoryBound(to: UInt32.self)
                        a = Int(ptr[0]); b = Int(ptr[1]); c = Int(ptr[2])
                    } else {
                        let ptr = fBuf.advanced(by: offset).assumingMemoryBound(to: UInt16.self)
                        a = Int(ptr[0]); b = Int(ptr[1]); c = Int(ptr[2])
                    }
                    guard a < verts.count, b < verts.count, c < verts.count else { continue }

                    let va = verts[a], vb = verts[b], vc = verts[c]

                    // Only ground-facing triangles
                    let edge1 = vb - va, edge2 = vc - va
                    let cross = simd_cross(edge1, edge2)
                    let len = simd_length(cross)
                    guard len > 1e-8 else { continue }
                    let normal = cross / len
                    guard normal.y > 0.5 else { continue }

                    triangles.append(WorldTri(a: va, b: vb, c: vc))
                    yMin = Swift.min(yMin, va.y, vb.y, vc.y)
                    yMax = Swift.max(yMax, va.y, vb.y, vc.y)
                }
            }

            guard !triangles.isEmpty else { return nil }

            let range = yMax - yMin
            guard range > 0.005 else { return nil }

            // Adaptive contour interval
            let interval: Float
            if range < 0.1 { interval = 0.02 }
            else if range < 0.3 { interval = 0.05 }
            else if range < 1.0 { interval = 0.1 }
            else if range < 3.0 { interval = 0.25 }
            else if range < 8.0 { interval = 0.5 }
            else { interval = 1.0 }

            // March through triangles for elevation crossings
            var contourVerts: [SCNVector3] = []
            var contourColors: [SCNVector3] = []
            var contourIndices: [UInt32] = []
            var idx: UInt32 = 0

            var level = (yMin / interval).rounded(.up) * interval
            while level <= yMax {
                let frac = Double((level - yMin) / (yMax - yMin))
                let rgb = viridisRGBStatic(fraction: frac)

                for tri in triangles {
                    let pts = [tri.a, tri.b, tri.c]
                    var crossings: [simd_float3] = []

                    for ei in 0..<3 {
                        let ej = (ei + 1) % 3
                        let e0 = pts[ei].y, e1 = pts[ej].y
                        guard (e0 - level) * (e1 - level) < 0 else { continue }
                        let t = (level - e0) / (e1 - e0)
                        crossings.append(pts[ei] + t * (pts[ej] - pts[ei]))
                    }

                    if crossings.count == 2 {
                        contourVerts.append(SCNVector3(crossings[0].x, crossings[0].y, crossings[0].z))
                        contourVerts.append(SCNVector3(crossings[1].x, crossings[1].y, crossings[1].z))
                        contourColors.append(rgb)
                        contourColors.append(rgb)
                        contourIndices.append(idx); contourIndices.append(idx + 1)
                        idx += 2
                    }
                }
                level += interval
            }

            guard !contourVerts.isEmpty else { return nil }

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
            material.emission.intensity = 1.0
            material.readsFromDepthBuffer = true
            material.writesToDepthBuffer = false
            geometry.materials = [material]

            return geometry
        }

        // MARK: - Point node builder (flat texture label)

        private func makePointNode(
            at position: SCNVector3,
            elevation: Double,
            elevMin: Double,
            elevMax: Double,
            pointID: String
        ) -> SCNNode {
            let root = SCNNode()
            root.position = position

            // White sphere marker
            let sphere = SCNSphere(radius: 0.035)
            sphere.firstMaterial?.diffuse.contents  = UIColor.white
            sphere.firstMaterial?.emission.contents = UIColor.white.withAlphaComponent(0.5)
            let sphereNode = SCNNode(geometry: sphere)
            root.addChildNode(sphereNode)

            // Flat billboard elevation label
            let label = String(format: "%.1fm", elevation)
            let color = viridisColor(fraction: elevFraction(elevation, min: elevMin, max: elevMax))
            let labelNode = makeTextPlaneNode(text: label, color: color)
            labelNode.position = SCNVector3(0, 0.15, 0) // 15 cm above dot

            let bb = SCNBillboardConstraint()
            bb.freeAxes = .all
            labelNode.constraints = [bb]
            root.addChildNode(labelNode)

            // Track label node for dynamic updates
            labelNodes[pointID] = labelNode

            return root
        }

        /// Renders text into a UIImage, then maps it onto a small SCNPlane.
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
            plane.firstMaterial?.emission.contents = image
            plane.firstMaterial?.emission.intensity = 0.5
            plane.firstMaterial?.lightingModel = .constant

            return SCNNode(geometry: plane)
        }

        // MARK: - Color helpers

        private func elevFraction(_ elev: Double, min eMin: Double, max eMax: Double) -> Double {
            guard eMax > eMin else { return 0.5 }
            return Swift.max(0, Swift.min(1, (elev - eMin) / (eMax - eMin)))
        }

        private func viridisColor(fraction: Double) -> UIColor {
            let rgb = Self.viridisRGBStatic(fraction: fraction)
            return UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1.0)
        }

        /// Static viridis approximation — safe to call from any thread.
        private static func viridisRGBStatic(fraction: Double) -> SCNVector3 {
            let f = Float(Swift.max(0, Swift.min(1, fraction)))
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
            }
        }

        private func makeBeaconNode() -> SCNNode {
            let root = SCNNode()

            let ring = SCNTorus(ringRadius: 0.10, pipeRadius: 0.007)
            ring.firstMaterial?.diffuse.contents  = UIColor(red: 0.23, green: 0.87, blue: 0.67, alpha: 0.9)
            ring.firstMaterial?.emission.contents = UIColor(red: 0.23, green: 0.87, blue: 0.67, alpha: 0.6)
            root.addChildNode(SCNNode(geometry: ring))

            let dot = SCNSphere(radius: 0.025)
            dot.firstMaterial?.diffuse.contents  = UIColor(red: 0.23, green: 0.87, blue: 0.67, alpha: 1.0)
            dot.firstMaterial?.emission.contents = UIColor(red: 0.23, green: 0.87, blue: 0.67, alpha: 0.8)
            root.addChildNode(SCNNode(geometry: dot))

            let pulse            = CABasicAnimation(keyPath: "scale")
            pulse.fromValue      = NSValue(scnVector3: SCNVector3(1, 1, 1))
            pulse.toValue        = NSValue(scnVector3: SCNVector3(1.4, 1.4, 1.4))
            pulse.duration       = 0.9
            pulse.autoreverses   = true
            pulse.repeatCount    = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            root.addAnimation(pulse, forKey: "pulse")

            let bb       = SCNBillboardConstraint()
            bb.freeAxes  = .all
            root.constraints = [bb]

            return root
        }
    }
}
