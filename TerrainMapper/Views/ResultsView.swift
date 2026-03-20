// ResultsView.swift
// TerrainMapper
//
// Post-processing results screen with four display modes selected by a
// segmented picker:
//
//   Map      – MapKit satellite + survey points + contour overlays
//   3D       – SceneKit free-rotate TerrainMesh with elevation gradient
//   Contours – SwiftUI Canvas 2D contour drawing with elevation labels
//   Stats    – Summary cards (point count, area, elevation range, accuracy)

import SwiftUI
import MapKit
import SceneKit
import UIKit

struct ResultsView: View {
    let terrain: ProcessedTerrain

    @State private var selectedTab: ResultsTab = .map
    @State private var showExportError: Bool = false
    @State private var exportErrorMessage: String = ""
    @State private var showShareSheet: Bool = false
    @State private var shareURLs:      [URL] = []
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var exportManager: ExportManager

    enum ResultsTab: String, CaseIterable, Identifiable {
        case map      = "Map"
        case scene3D  = "3D"
        case contours = "Contours"
        case stats    = "Stats"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .map:      return "map"
            case .scene3D:  return "cube"
            case .contours: return "lines.measurement.horizontal"
            case .stats:    return "chart.bar"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Tab picker ────────────────────────────────────────────
                Picker("View", selection: $selectedTab) {
                    ForEach(ResultsTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.systemGroupedBackground))

                Divider()

                // ── Content ───────────────────────────────────────────────
                switch selectedTab {
                case .map:      mapView
                case .scene3D:  sceneView
                case .contours: contourView
                case .stats:    statsView
                }
            }
            .navigationTitle("Survey Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await runExport() }
                    } label: {
                        if exportManager.isExporting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .disabled(exportManager.isExporting || settings.selectedExportFormats.isEmpty)
                }
            }
            .alert("Export Failed", isPresented: $showExportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportErrorMessage)
            }
            .sheet(isPresented: $showShareSheet) {
                ActivityShareSheet(urls: shareURLs)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: - Export

    private func runExport() async {
        do {
            let urls = try await exportManager.export(
                terrain: terrain,
                formats: settings.selectedExportFormats
            )
            shareURLs      = urls
            showShareSheet = true
        } catch {
            exportErrorMessage = error.localizedDescription
            showExportError = true
        }
    }

    // MARK: - Map tab

    private var mapView: some View {
        let pts = terrain.validPoints + (settings.showOutliers ? terrain.outlierPoints : [])
        let allLats = pts.map(\.latitude)
        let allLons = pts.map(\.longitude)
        let centLat = allLats.isEmpty ? 0 : allLats.reduce(0,+) / Double(allLats.count)
        let centLon = allLons.isEmpty ? 0 : allLons.reduce(0,+) / Double(allLons.count)
        let region  = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centLat, longitude: centLon),
            latitudinalMeters: 200, longitudinalMeters: 200
        )
        let elevMin = terrain.stats.elevationMin
        let elevMax = terrain.stats.elevationMax

        return Map(initialPosition: .region(region)) {
            // Survey points
            ForEach(pts) { p in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)) {
                    ElevationDot(elevation: p.groundElevation,
                                 elevMin:   elevMin,
                                 elevMax:   elevMax,
                                 isOutlier: p.isOutlier)
                }
            }
            // Contour lines as MapPolylines
            ForEach(Array(terrain.contours.enumerated()), id: \.offset) { _, contour in
                MapPolyline(coordinates: contour.coordinates.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .stroke(.white.opacity(0.8), lineWidth: 1)
            }
        }
        .mapStyle(.imagery(elevation: .realistic))
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - 3D tab

    private var sceneView: some View {
        TerrainSceneView(mesh: terrain.mesh)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottomTrailing) {
                Text("Drag to rotate  •  Pinch to zoom")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .padding(12)
            }
    }

    // MARK: - Contours tab

    private var contourView: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let contours = terrain.contours
                guard !contours.isEmpty else { return }

                // Compute geographic bounds
                let allCoords = contours.flatMap(\.coordinates)
                guard !allCoords.isEmpty else { return }
                let latMin = allCoords.map(\.latitude).min()!
                let latMax = allCoords.map(\.latitude).max()!
                let lonMin = allCoords.map(\.longitude).min()!
                let lonMax = allCoords.map(\.longitude).max()!
                let latSpan = max(1e-9, latMax - latMin)
                let lonSpan = max(1e-9, lonMax - lonMin)

                let pad: Double = 30

                func project(_ c: (latitude: Double, longitude: Double)) -> CGPoint {
                    let x = pad + (c.longitude - lonMin) / lonSpan * (size.width  - 2*pad)
                    let y = size.height - pad - (c.latitude - latMin) / latSpan * (size.height - 2*pad)
                    return CGPoint(x: x, y: y)
                }

                // Sort contours by elevation (alternating major/minor)
                let sortedContours = contours.sorted { $0.elevation < $1.elevation }
                let elevMin = sortedContours.first?.elevation ?? 0
                let elevMax = sortedContours.last?.elevation ?? 1
                let span    = max(1, elevMax - elevMin)
                // Use the sorted array to compute the actual contour interval.
                let interval: Double = sortedContours.count >= 2
                    ? abs(sortedContours[1].elevation - sortedContours[0].elevation)
                    : 0.5

                for contour in sortedContours {
                    guard contour.coordinates.count >= 2 else { continue }

                    let isMajor = interval > 0 && contour.elevation.truncatingRemainder(dividingBy: interval * 5) < interval / 2
                    let frac    = (contour.elevation - elevMin) / span
                    let hue     = 0.67 * (1 - frac)   // blue→green→red
                    let color   = Color(hue: hue, saturation: 0.7, brightness: 0.6)
                    let lineWidth: Double = isMajor ? 1.5 : 0.8

                    var path = Path()
                    let pts = contour.coordinates.map(project)
                    path.move(to: pts[0])
                    for pt in pts.dropFirst() { path.addLine(to: pt) }

                    ctx.stroke(path, with: .color(color), lineWidth: lineWidth)

                    // Elevation label on major contours (at midpoint of line)
                    if isMajor, let mid = pts.middle {
                        ctx.draw(
                            Text(String(format: "%.1fm", contour.elevation))
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(color),
                            at: mid, anchor: .center
                        )
                    }
                }
            }
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Stats tab

    private var statsView: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                StatCard(icon: "mappin.circle.fill", label: "Points",
                         value: "\(terrain.stats.validPointCount)",
                         sub: "\(terrain.stats.outlierCount) outliers")
                StatCard(icon: "rectangle.expand.diagonal", label: "Area",
                         value: formatArea(terrain.stats.surveyedAreaM2),
                         sub: "surveyed")
                StatCard(icon: "arrow.up.and.down", label: "Elevation Range",
                         value: String(format: "%.2f m", terrain.stats.elevationMax - terrain.stats.elevationMin),
                         sub: String(format: "%.1f – %.1f m", terrain.stats.elevationMin, terrain.stats.elevationMax))
                StatCard(icon: "scope", label: "RMS Accuracy",
                         value: String(format: "±%.2f m", terrain.stats.rmsAccuracyEstimate),
                         sub: accuracyTier(terrain.stats.rmsAccuracyEstimate))
                StatCard(icon: "triangle", label: "Mesh Triangles",
                         value: "\(terrain.mesh.triangleCount)",
                         sub: "\(terrain.mesh.vertexCount) vertices")
                StatCard(icon: "lines.measurement.horizontal", label: "Contours",
                         value: "\(terrain.contours.count)",
                         sub: "iso-lines")
                StatCard(icon: "clock", label: "Processing",
                         value: String(format: "%.1f s", terrain.stats.processingTimeSeconds),
                         sub: terrain.stats.loopClosureApplied ? "loop closed ✓" : "no closure")
                StatCard(icon: "globe", label: "Geoid",
                         value: terrain.stats.geoidCorrectionApplied ? "EGM96 ✓" : "Off",
                         sub: "correction")
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private func formatArea(_ m2: Double) -> String {
        if m2 >= 10_000 { return String(format: "%.3f ha", m2 / 10_000) }
        return String(format: "%.0f m²", m2)
    }

    private func accuracyTier(_ rms: Double) -> String {
        switch rms {
        case ..<0.05: return "Survey-grade ✓"
        case ..<0.15: return "RTK-grade ✓"
        case ..<0.50: return "GPS-grade"
        default:      return "Low accuracy — check tilt"
        }
    }
}

// MARK: - ElevationDot

private struct ElevationDot: View {
    let elevation, elevMin, elevMax: Double
    let isOutlier: Bool

    private var fraction: Double {
        guard elevMax > elevMin else { return 0.5 }
        return max(0, min(1, (elevation - elevMin) / (elevMax - elevMin)))
    }

    var body: some View {
        Circle()
            .fill(isOutlier ? Color.orange.opacity(0.5)
                  : Color(hue: 0.67 * (1 - fraction), saturation: 0.8, brightness: 0.9))
            .frame(width: 10, height: 10)
            .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
    }
}

// MARK: - StatCard

private struct StatCard: View {
    let icon:  String
    let label: String
    let value: String
    let sub:   String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.blue)
                Spacer()
            }
            Text(value)
                .font(.title3.bold())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption).foregroundStyle(.primary)
            Text(sub)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - TerrainSceneView

/// UIViewRepresentable wrapper for SCNView displaying the TerrainMesh.
struct TerrainSceneView: UIViewRepresentable {
    let mesh: TerrainMesh

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene            = makeScene()
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.backgroundColor  = .black
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    private func makeScene() -> SCNScene {
        let scene = SCNScene()

        guard mesh.vertexCount >= 3 else { return scene }

        // Horizontal extent: maximum coordinate distance from origin across all vertices.
        let horizontalExtent = mesh.vertices.map { max(abs($0.x), abs($0.y)) }.max() ?? 1.0
        // Camera distance should be large enough to see the whole mesh regardless of
        // elevation range (important for flat surveys where elevRange ≈ 0).
        let elevRange = max(1, mesh.elevationMax - mesh.elevationMin)
        let camDist   = max(elevRange * 3, horizontalExtent * 2)

        // Build SCNGeometry from TerrainMesh
        var positions: [SCNVector3] = []
        var normals:   [SCNVector3] = []
        var colors:    [SIMD4<Float>] = []
        var indices:   [Int32] = []

        for v in mesh.vertices {
            positions.append(SCNVector3(Float(v.x), Float(v.z), Float(-v.y)))  // Y-up in SceneKit
            normals.append(SCNVector3(Float(v.nx), Float(v.nz), Float(-v.ny)))
            let frac  = Float((v.elevation - mesh.elevationMin) / elevRange)
            let color = viridisColor(frac)
            colors.append(color)
        }
        for tri in mesh.triangles {
            indices.append(Int32(tri.i0))
            indices.append(Int32(tri.i1))
            indices.append(Int32(tri.i2))
        }

        let posSource    = SCNGeometrySource(vertices: positions)
        let normSource   = SCNGeometrySource(normals: normals)
        let colorData    = Data(bytes: &colors, count: colors.count * MemoryLayout<SIMD4<Float>>.size)
        let colorSource  = SCNGeometrySource(
            data: colorData, semantic: .color,
            vectorCount: colors.count, usesFloatComponents: true,
            componentsPerVector: 4, bytesPerComponent: 4,
            dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.size
        )

        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element   = SCNGeometryElement(
            data: indexData, primitiveType: .triangles,
            primitiveCount: mesh.triangleCount,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let geometry = SCNGeometry(sources: [posSource, normSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents  = UIColor.white
        material.isDoubleSided     = true
        material.lightingModel     = .lambert
        geometry.firstMaterial     = material

        let node = SCNNode(geometry: geometry)
        scene.rootNode.addChildNode(node)

        // Camera positioned above and slightly to the side
        let cam = SCNCamera()
        cam.fieldOfView = 60
        let camNode = SCNNode()
        camNode.camera = cam
        camNode.position = SCNVector3(0, Float(camDist), Float(camDist * 0.6))
        camNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camNode)

        return scene
    }

    /// Viridis colour map: blue → teal → green → yellow.
    private func viridisColor(_ t: Float) -> SIMD4<Float> {
        let stops: [(Float, SIMD3<Float>)] = [
            (0.00, SIMD3(0.267, 0.005, 0.329)),  // dark purple
            (0.25, SIMD3(0.229, 0.322, 0.545)),  // blue
            (0.50, SIMD3(0.128, 0.566, 0.551)),  // teal
            (0.75, SIMD3(0.370, 0.788, 0.384)),  // green
            (1.00, SIMD3(0.993, 0.906, 0.144))   // yellow
        ]
        for i in 1..<stops.count {
            let (t0, c0) = stops[i-1]
            let (t1, c1) = stops[i]
            if t <= t1 {
                let f = (t - t0) / (t1 - t0)
                let c = c0 + (c1 - c0) * f
                return SIMD4(c.x, c.y, c.z, 1.0)
            }
        }
        return SIMD4(1, 1, 1, 1)
    }
}

// MARK: - Array middle helper

private extension Array {
    var middle: Element? {
        isEmpty ? nil : self[count / 2]
    }
}

// MARK: - ActivityShareSheet

/// UIActivityViewController wrapper for sharing exported files.
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ uiView: UIActivityViewController, context: Context) {}
}
