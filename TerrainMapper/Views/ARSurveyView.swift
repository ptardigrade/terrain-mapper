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
        fileprivate var surveyedMeshNode: SCNNode?

        /// XZ positions (ARKit world space) of captured survey points.
        /// Updated every time updatePoints is called; used to compute the
        /// 2D convex hull that clips the white surveyed-area mesh & contours.
        fileprivate var capturedXZPositions: [simd_float2] = []

        // MARK: - Overlay throttle state

        private var lastOverlayTime: TimeInterval = 0
        private var isComputingOverlay: Bool = false

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
            surveyedMeshNode?.removeFromParentNode()
            surveyedMeshNode = nil
            capturedXZPositions.removeAll()
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

            // Rebuild XZ positions for convex hull clipping
            capturedXZPositions = points.compactMap { p in
                let key = p.id.uuidString
                guard let pos = arkitPositions[key], pos.count >= 2 else { return nil }
                return simd_float2(Float(pos[0]), Float(pos[1]))
            }
        }

        // MARK: - ARSCNViewDelegate

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            updateBeacon(renderer: renderer)
            updateSurveyedAreaOverlay(renderer: renderer, time: time)
        }

        /// Return empty nodes for mesh anchors — we render our own
        /// surveyed-area mesh clipped to the convex hull of captured points.
        func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            guard anchor is ARMeshAnchor else { return nil }
            return SCNNode()  // empty — keeps anchor tracked but invisible
        }

        /// No per-anchor wireframe — surveyed-area mesh is rebuilt periodically.
        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            // intentionally empty
        }

        // MARK: - Surveyed-area overlay (white mesh + white thick contours)

        /// Periodically extracts mesh triangles inside the convex hull of captured
        /// points, then renders a white wireframe mesh and thick white contour
        /// ribbons.  All heavy work runs on a background queue.
        private func updateSurveyedAreaOverlay(renderer: SCNSceneRenderer, time: TimeInterval) {
            guard !isComputingOverlay,
                  time - lastOverlayTime > 2.0,
                  capturedXZPositions.count >= 3 else { return }
            lastOverlayTime = time

            guard let scnView = renderer as? ARSCNView,
                  let frame = scnView.session.currentFrame else { return }

            let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            guard !meshAnchors.isEmpty else { return }

            let hullPts = capturedXZPositions
            isComputingOverlay = true

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let hull = Self.convexHull2D(hullPts)
                let expanded = Self.expandedHull(hull, by: 0.3)  // 30 cm buffer
                let (meshGeo, contourGeo) = Self.computeSurveyedAreaGeometry(
                    from: meshAnchors, hull: expanded
                )

                DispatchQueue.main.async { [weak self] in
                    guard let self, let scene = self.sceneView?.scene else {
                        self?.isComputingOverlay = false
                        return
                    }
                    self.isComputingOverlay = false

                    // Replace surveyed-area mesh
                    self.surveyedMeshNode?.removeFromParentNode()
                    if let geo = meshGeo {
                        let node = SCNNode(geometry: geo)
                        node.renderingOrder = 0
                        scene.rootNode.addChildNode(node)
                        self.surveyedMeshNode = node
                    }

                    // Replace contour lines
                    self.contourLinesNode?.removeFromParentNode()
                    if let geo = contourGeo {
                        let node = SCNNode(geometry: geo)
                        node.renderingOrder = 2
                        scene.rootNode.addChildNode(node)
                        self.contourLinesNode = node
                    }
                }
            }
        }

        // MARK: - Surveyed-area geometry computation (background queue)

        private static func computeSurveyedAreaGeometry(
            from anchors: [ARMeshAnchor],
            hull: [simd_float2]
        ) -> (mesh: SCNGeometry?, contours: SCNGeometry?) {

            struct WorldTri {
                let a: simd_float3, b: simd_float3, c: simd_float3
            }

            // ── Extract ground-facing triangles inside the hull ──────────
            var triangles: [WorldTri] = []
            var allVerts: [simd_float3] = []   // for wireframe
            var allIndices: [UInt32] = []
            var yMin: Float = .greatestFiniteMagnitude
            var yMax: Float = -.greatestFiniteMagnitude

            for anchor in anchors {
                let geo = anchor.geometry
                let transform = anchor.transform

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

                    // Ground-facing check
                    let edge1 = vb - va, edge2 = vc - va
                    let cross = simd_cross(edge1, edge2)
                    let len = simd_length(cross)
                    guard len > 1e-8 else { continue }
                    let normal = cross / len
                    guard normal.y > 0.5 else { continue }

                    // Centroid inside hull check (XZ plane)
                    let cx = (va.x + vb.x + vc.x) / 3.0
                    let cz = (va.z + vb.z + vc.z) / 3.0
                    guard pointInConvexHull(simd_float2(cx, cz), hull: hull) else { continue }

                    triangles.append(WorldTri(a: va, b: vb, c: vc))

                    let base = UInt32(allVerts.count)
                    allVerts.append(va)
                    allVerts.append(vb)
                    allVerts.append(vc)
                    allIndices.append(base)
                    allIndices.append(base + 1)
                    allIndices.append(base + 2)

                    yMin = Swift.min(yMin, va.y, vb.y, vc.y)
                    yMax = Swift.max(yMax, va.y, vb.y, vc.y)
                }
            }

            // ── Build white wireframe mesh geometry ──────────────────────
            var meshGeometry: SCNGeometry?
            if !allVerts.isEmpty {
                let vertexData = Data(bytes: allVerts, count: allVerts.count * MemoryLayout<simd_float3>.size)
                let vertexSource = SCNGeometrySource(
                    data: vertexData,
                    semantic: .vertex,
                    vectorCount: allVerts.count,
                    usesFloatComponents: true,
                    componentsPerVector: 3,
                    bytesPerComponent: MemoryLayout<Float>.size,
                    dataOffset: 0,
                    dataStride: MemoryLayout<simd_float3>.size
                )
                let indexData = Data(bytes: allIndices, count: allIndices.count * MemoryLayout<UInt32>.size)
                let element = SCNGeometryElement(
                    data: indexData,
                    primitiveType: .triangles,
                    primitiveCount: allIndices.count / 3,
                    bytesPerIndex: MemoryLayout<UInt32>.size
                )
                let geo = SCNGeometry(sources: [vertexSource], elements: [element])
                let mat = SCNMaterial()
                mat.fillMode = .lines
                mat.diffuse.contents = UIColor(white: 1.0, alpha: 0.45)
                mat.emission.contents = UIColor(white: 1.0, alpha: 0.6)
                mat.emission.intensity = 0.8
                mat.lightingModel = .constant
                mat.isDoubleSided = true
                mat.readsFromDepthBuffer = true
                mat.writesToDepthBuffer = false
                geo.materials = [mat]
                meshGeometry = geo
            }

            // ── Build white contour ribbon geometry ──────────────────────
            var contourGeometry: SCNGeometry?
            if !triangles.isEmpty {
                let range = yMax - yMin
                if range > 0.005 {
                    let interval: Float
                    if range < 0.1 { interval = 0.02 }
                    else if range < 0.3 { interval = 0.05 }
                    else if range < 1.0 { interval = 0.1 }
                    else if range < 3.0 { interval = 0.25 }
                    else if range < 8.0 { interval = 0.5 }
                    else { interval = 1.0 }

                    // Collect contour line segments
                    var segments: [(simd_float3, simd_float3)] = []
                    var level = (yMin / interval).rounded(.up) * interval
                    while level <= yMax {
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
                                segments.append((crossings[0], crossings[1]))
                            }
                        }
                        level += interval
                    }

                    if !segments.isEmpty {
                        contourGeometry = makeContourRibbonGeometry(segments: segments)
                    }
                }
            }

            return (meshGeometry, contourGeometry)
        }

        /// Builds thick contour lines as flat ribbon quads (two triangles per
        /// segment).  Each ribbon lies on the terrain surface with a configurable
        /// width, giving the appearance of thick lines — SceneKit .line primitives
        /// are always 1 pixel regardless of distance.
        private static func makeContourRibbonGeometry(segments: [(simd_float3, simd_float3)]) -> SCNGeometry {
            let halfWidth: Float = 0.012  // 12 mm half-width → 24 mm total (~3× mesh line)
            let up = simd_float3(0, 1, 0)

            var verts: [simd_float3] = []
            var indices: [UInt32] = []
            verts.reserveCapacity(segments.count * 4)
            indices.reserveCapacity(segments.count * 6)

            for (p0, p1) in segments {
                let dir = p1 - p0
                let len = simd_length(dir)
                guard len > 1e-6 else { continue }

                let fwd = dir / len
                var perp = simd_cross(fwd, up)
                let perpLen = simd_length(perp)
                if perpLen < 1e-6 {
                    // Segment is vertical — use arbitrary perpendicular
                    perp = simd_float3(1, 0, 0) * halfWidth
                } else {
                    perp = (perp / perpLen) * halfWidth
                }

                // Lift ribbon slightly above surface to prevent z-fighting
                let lift = simd_float3(0, 0.003, 0)

                let base = UInt32(verts.count)
                verts.append(p0 - perp + lift)
                verts.append(p0 + perp + lift)
                verts.append(p1 - perp + lift)
                verts.append(p1 + perp + lift)

                // Two triangles for the quad
                indices.append(base)
                indices.append(base + 1)
                indices.append(base + 2)
                indices.append(base + 1)
                indices.append(base + 3)
                indices.append(base + 2)
            }

            let vertexData = Data(bytes: verts, count: verts.count * MemoryLayout<simd_float3>.size)
            let vertexSource = SCNGeometrySource(
                data: vertexData,
                semantic: .vertex,
                vectorCount: verts.count,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<simd_float3>.size
            )
            let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
            let element = SCNGeometryElement(
                data: indexData,
                primitiveType: .triangles,
                primitiveCount: indices.count / 3,
                bytesPerIndex: MemoryLayout<UInt32>.size
            )

            let geo = SCNGeometry(sources: [vertexSource], elements: [element])
            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor(white: 1.0, alpha: 0.85)
            mat.emission.contents = UIColor(white: 1.0, alpha: 0.9)
            mat.emission.intensity = 1.0
            mat.lightingModel = .constant
            mat.isDoubleSided = true
            mat.readsFromDepthBuffer = true
            mat.writesToDepthBuffer = false
            geo.materials = [mat]
            return geo
        }

        // MARK: - 2D convex hull (Andrew's monotone chain)

        private static func convexHull2D(_ points: [simd_float2]) -> [simd_float2] {
            guard points.count >= 3 else { return points }
            let sorted = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }

            var lower: [simd_float2] = []
            for p in sorted {
                while lower.count >= 2 && cross2D(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                    lower.removeLast()
                }
                lower.append(p)
            }

            var upper: [simd_float2] = []
            for p in sorted.reversed() {
                while upper.count >= 2 && cross2D(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                    upper.removeLast()
                }
                upper.append(p)
            }

            lower.removeLast()
            upper.removeLast()
            return lower + upper
        }

        private static func cross2D(_ o: simd_float2, _ a: simd_float2, _ b: simd_float2) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        private static func pointInConvexHull(_ p: simd_float2, hull: [simd_float2]) -> Bool {
            guard hull.count >= 3 else { return false }
            for i in 0..<hull.count {
                let j = (i + 1) % hull.count
                if cross2D(hull[i], hull[j], p) < 0 { return false }
            }
            return true
        }

        /// Expands hull outward from its centroid by a fixed distance.
        private static func expandedHull(_ hull: [simd_float2], by amount: Float) -> [simd_float2] {
            guard hull.count >= 3 else { return hull }
            let cx = hull.reduce(Float(0)) { $0 + $1.x } / Float(hull.count)
            let cy = hull.reduce(Float(0)) { $0 + $1.y } / Float(hull.count)
            let center = simd_float2(cx, cy)
            return hull.map { p in
                let dir = p - center
                let len = simd_length(dir)
                guard len > 0.001 else { return p }
                return p + simd_normalize(dir) * amount
            }
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
