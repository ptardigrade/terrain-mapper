// ARSurveyView.swift
// TerrainMapper
//
// UIViewRepresentable wrapping ARSCNView for the live AR survey interface.
//
// Rendered overlays:
//   • White sphere + billboard elevation label for each captured survey point
//   • Pulsing green beacon (torus + dot) at the live LiDAR target position
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
        private var renderedIDs = Set<String>()

        // MARK: - Point management

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
                    elevation: point.groundElevation
                )
                node.name = "pt_\(key)"
                scene.rootNode.addChildNode(node)
            }
        }

        // MARK: - ARSCNViewDelegate

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            updateBeacon(renderer: renderer)
        }

        // MARK: - Point node builder

        private func makePointNode(at position: SCNVector3, elevation: Double) -> SCNNode {
            let root = SCNNode()
            root.position = position

            // White sphere
            let sphere = SCNSphere(radius: 0.04)
            sphere.firstMaterial?.diffuse.contents  = UIColor.white
            sphere.firstMaterial?.emission.contents = UIColor.white.withAlphaComponent(0.5)
            root.addChildNode(SCNNode(geometry: sphere))

            // Billboard elevation label
            let label    = String(format: "%.1fm", elevation)
            let text     = SCNText(string: label, extrusionDepth: 0.001)
            text.font    = UIFont.monospacedSystemFont(ofSize: 0.07, weight: .bold)
            text.firstMaterial?.diffuse.contents  = UIColor.white
            text.firstMaterial?.emission.contents = UIColor.white.withAlphaComponent(0.9)

            let textNode = SCNNode(geometry: text)
            let (minB, maxB) = textNode.boundingBox
            // Centre the text horizontally around the sphere.
            textNode.pivot    = SCNMatrix4MakeTranslation((maxB.x + minB.x) / 2, 0, 0)
            textNode.position = SCNVector3(0, 0.07, 0)

            let bb       = SCNBillboardConstraint()
            bb.freeAxes  = .all
            textNode.constraints = [bb]
            root.addChildNode(textNode)

            return root
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

            // Sample the centre pixel of the LiDAR depth map — same ROI centre
            // that captureGroundDistance() uses for its median computation.
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

            // Project centre ray to world space:
            //   world_hit = camera_position + (-camera_forward) * depth
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
