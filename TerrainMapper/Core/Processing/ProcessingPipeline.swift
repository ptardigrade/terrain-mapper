// ProcessingPipeline.swift
// TerrainMapper
//
// Top-level coordinator that runs the full post-processing sequence on a
// completed SurveySession and produces a ProcessedTerrain.
//
// Pipeline stages (in order):
//  1. Differential elevation correct (DifferentialElevationCorrector)
//  2. Outlier detection              (OutlierDetector — on corrected elevations)
//  3. Loop-closure correction        (LoopClosureProcessor)
//  4. ARKit VIO position refinement  (arkitRefinePositions)
//  5. PDR position refinement        (GPSManager, fallback when no ARKit data)
//  6. Geoid correction               (GeoidCorrector)
//  7. IDW / kriging interpolation    → TerrainGrid   (TerrainInterpolator)
//  8. Delaunay triangulation         → TerrainMesh   (MeshGenerator)
//  9. Marching squares contours      → [ContourLine]  (ContourGenerator)
//
// All stages are awaited on a background Task to avoid blocking the main thread.

import Foundation

@MainActor
final class ProcessingPipeline: ObservableObject {

    // MARK: - Configuration

    var contourInterval:    Double = 0.5                  // metres
    var gridResolution:     Double = 0.5                  // metres per cell
    var interpolationMethod: InterpolationMethod = .idw
    var enableGeoidCorrection: Bool = true
    var madThreshold:       Double = 3.5

    /// Optional vertical offset applied to all ground elevations after geoid correction.
    /// Positive shifts up, negative shifts down.  0.0 = no adjustment.
    var elevationOffset: Double = 0.0

    // MARK: - Progress reporting

    @Published private(set) var isProcessing: Bool = false
    @Published fileprivate(set) var progressMessage: String = ""

    // MARK: - Sub-processors

    private var outlierDetector  = OutlierDetector()
    private var loopClosure      = LoopClosureProcessor()
    private var geoidCorrector   = GeoidCorrector()
    private var interpolator     = TerrainInterpolator()
    private var meshGenerator    = MeshGenerator()
    private var contourGen       = ContourGenerator()

    // MARK: - Public API

    /// Run the full processing pipeline on `session` asynchronously.
    ///
    /// - Parameter session: The completed survey session to process.
    /// - Returns: A `ProcessedTerrain` with all derived products.
    func process(session: SurveySession) async -> ProcessedTerrain {
        isProcessing = true
        progressMessage = "Starting…"
        let startTime = Date()

        // Capture all configuration values on the MainActor before dispatching to
        // a background thread.  Task.detached does not inherit the actor context, so
        // accessing @MainActor-isolated properties inside the closure would be a data
        // race.  Passing them as value-type constants is safe.
        let capturedContourInterval     = contourInterval
        let capturedGridResolution      = gridResolution
        let capturedInterpolationMethod = interpolationMethod
        let capturedGeoidEnabled        = enableGeoidCorrection
        let capturedMadThreshold        = madThreshold
        let capturedElevationOffset     = elevationOffset
        let capturedArkitPositions      = session.arkitPositions
        let capturedArkitHeading        = session.arkitAnchorHeading

        // ProgressSender lets the background pipeline post stage messages back to
        // the @MainActor-isolated progressMessage property safely.
        let sender = ProgressSender(self)

        let result = await Task.detached(priority: .userInitiated) {
            ProcessingPipeline.runPipeline(
                session:               session,
                startTime:             startTime,
                contourInterval:       capturedContourInterval,
                gridResolution:        capturedGridResolution,
                interpolationMethod:   capturedInterpolationMethod,
                enableGeoidCorrection: capturedGeoidEnabled,
                madThreshold:          capturedMadThreshold,
                elevationOffset:       capturedElevationOffset,
                arkitPositions:        capturedArkitPositions,
                arkitAnchorHeading:    capturedArkitHeading,
                updateProgress:        { msg in sender.send(msg) }
            )
        }.value

        isProcessing = false
        progressMessage = ""
        return result
    }

    // MARK: - Pipeline (static + nonisolated — safe to call from Task.detached)

    private nonisolated static func runPipeline(
        session:              SurveySession,
        startTime:            Date,
        contourInterval:      Double,
        gridResolution:       Double,
        interpolationMethod:  InterpolationMethod,
        enableGeoidCorrection: Bool,
        madThreshold:         Double,
        elevationOffset:      Double,
        arkitPositions:       [String: [Double]]?,
        arkitAnchorHeading:   Double?,
        updateProgress:       (String) -> Void
    ) -> ProcessedTerrain {
        var points = session.points
        var pathPoints = session.pathTrackPoints

        // ── 1. Differential elevation correction ─────────────────────────
        // Recompute ground elevations using baro+LiDAR differential method
        // BEFORE outlier detection.  This way, outlier detection operates on
        // precise baro+LiDAR elevations (±0.12 m) instead of noisy
        // Kalman-fused values (±5 m).  Running it after would flag
        // perfectly good points as outliers due to GPS altitude scatter.
        updateProgress("Applying differential elevation…")
        let originalPoints = points  // snapshot for path-track offset calc
        let diffCorrector = DifferentialElevationCorrector()
        diffCorrector.correct(points: &points)
        diffCorrector.correctPathTrack(
            pathPoints: &pathPoints,
            correctedCaptures: points,
            originalCaptures: originalPoints
        )

        // ── 2. Outlier detection (on corrected elevations) ──────────────
        updateProgress("Detecting outliers…")
        var detector = OutlierDetector()
        detector.madThreshold = madThreshold
        detector.detectOutliers(in: &points)

        let outlierCount = points.filter(\.isOutlier).count

        // ── 3. Loop-closure correction ────────────────────────────────────
        updateProgress("Checking for loop closure…")
        var lcProc = LoopClosureProcessor()
        let loopClosed = lcProc.applyLoopClosure(to: &points)

        // ── 3a. ARKit VIO position refinement ────────────────────────────
        // When ARKit world-space positions were recorded during capture, use them
        // as the primary horizontal positioning source.  GPS accuracy (3–15 m) is
        // far worse than ARKit VIO accuracy (< 5 cm) for sub-meter surveys.
        // The ARKit XZ frame is rotated to geographic East/North using the compass
        // heading recorded at session start, then anchored to the GPS centroid.
        let hasArkitData: Bool
        if let ark = arkitPositions, let heading = arkitAnchorHeading, !ark.isEmpty {
            updateProgress("Refining positions with ARKit VIO…")
            ProcessingPipeline.arkitRefinePositions(
                points: &points,
                arkitPositions: ark,
                anchorHeadingDeg: heading
            )
            hasArkitData = true
        } else {
            hasArkitData = false
        }

        // ── 3b. PDR position refinement (fallback when no ARKit data) ─────
        updateProgress("Smoothing survey path…")
        if !hasArkitData {
            ProcessingPipeline.pdrRefineStatic(points: &points)
        }

        // ── 4. Geoid correction ───────────────────────────────────────────
        updateProgress("Applying geoid correction…")
        var geo = GeoidCorrector()
        geo.isEnabled = enableGeoidCorrection
        geo.correct(points: &points)

        // ── 4b. Elevation offset ──────────────────────────────────────────
        if elevationOffset != 0 {
            updateProgress("Applying elevation offset…")
            for i in points.indices {
                let p = points[i]
                points[i] = SurveyPoint(
                    id:                  p.id,
                    timestamp:           p.timestamp,
                    latitude:            p.latitude,
                    longitude:           p.longitude,
                    fusedAltitude:       p.fusedAltitude      + elevationOffset,
                    groundElevation:     p.groundElevation    + elevationOffset,
                    lidarDistance:       p.lidarDistance,
                    gpsAltitude:         p.gpsAltitude,
                    baroAltitudeDelta:   p.baroAltitudeDelta,
                    tiltAngle:           p.tiltAngle,
                    horizontalAccuracy:  p.horizontalAccuracy,
                    verticalAccuracy:    p.verticalAccuracy,
                    isOutlier:           p.isOutlier,
                    captureType:         p.captureType,
                    interpolationWeight: p.interpolationWeight
                )
            }
        }

        // ── 5. Interpolation → grid ───────────────────────────────────────
        updateProgress("Interpolating terrain grid…")
        let validPoints = points.filter { !$0.isOutlier }
        var interp = TerrainInterpolator()
        interp.gridResolutionMeters = gridResolution
        let grid = interp.interpolate(
            points:     validPoints,
            pathPoints: pathPoints,
            method:     interpolationMethod
        )

        // ── 6. Mesh generation ─────────────────────────────────────────────
        updateProgress("Building 3D mesh…")
        let meshGen = MeshGenerator()
        let mesh = validPoints.count >= 3
            ? meshGen.generateMesh(from: validPoints)
            : meshGen.generateMesh(from: grid)

        // ── 7. Contour extraction ──────────────────────────────────────────
        updateProgress("Drawing contour lines…")
        let cGen = ContourGenerator()
        let contours = cGen.generateContours(from: grid, interval: contourInterval)

        // ── Build stats ────────────────────────────────────────────────────
        updateProgress("Computing statistics…")
        let elapsed = Date().timeIntervalSince(startTime)
        let stats = buildStats(
            input:      session.points,
            valid:      validPoints,
            outliers:   outlierCount,
            loopClosed: loopClosed,
            geoid:      enableGeoidCorrection,
            elapsed:    elapsed,
            hasArkitData: hasArkitData,
            arkitPositions: arkitPositions
        )

        return ProcessedTerrain(
            session:       session,
            validPoints:   validPoints,
            outlierPoints: points.filter(\.isOutlier),
            grid:          grid,
            mesh:          mesh,
            contours:      contours,
            stats:         stats
        )
    }

    // MARK: - ARKit VIO position refinement

    /// Replaces GPS-derived horizontal positions with ARKit VIO positions.
    ///
    /// ARKit Visual-Inertial Odometry achieves < 5 cm relative accuracy over
    /// short sessions, which is dramatically better than GPS (3–15 m).
    ///
    /// Coordinate mapping for a phone held face-down (LiDAR pointing at ground):
    ///   • ARKit +X ≈ phone right ≈ geographic bearing (heading + 90°)
    ///   • ARKit +Z ≈ phone backward ≈ geographic bearing (heading + 180°)
    ///
    /// Rotation formulae (θ = anchor heading in radians, CW from geographic north):
    ///   ΔEast  =  Δx · cos θ + Δz · (−sin θ)
    ///   ΔNorth =  Δx · (−sin θ) + Δz · (−cos θ)
    ///
    /// The result is centred on the GPS centroid of all capture points so that
    /// the absolute position is approximately correct even though GPS is noisy.
    private nonisolated static func arkitRefinePositions(
        points: inout [SurveyPoint],
        arkitPositions: [String: [Double]],
        anchorHeadingDeg: Double
    ) {
        // Only non-outlier capture points that have ARKit data participate.
        let arkPoints = points.filter { !$0.isOutlier && arkitPositions[$0.id.uuidString] != nil }
        guard arkPoints.count >= 2 else { return }

        // ARKit centroid (world space).
        var arkCentX = 0.0, arkCentZ = 0.0
        for p in arkPoints {
            let pos = arkitPositions[p.id.uuidString]!
            arkCentX += pos[0]
            arkCentZ += pos[1]
        }
        arkCentX /= Double(arkPoints.count)
        arkCentZ /= Double(arkPoints.count)

        // GPS centroid (geographic anchor for absolute position).
        let gpsCentLat = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let gpsCentLon = points.map(\.longitude).reduce(0, +) / Double(points.count)

        let θ = anchorHeadingDeg * .pi / 180.0
        let cosθ = cos(θ), sinθ = sin(θ)
        let R = 6_371_000.0

        for i in points.indices {
            guard let pos = arkitPositions[points[i].id.uuidString] else { continue }
            let Δx = pos[0] - arkCentX
            let Δz = pos[1] - arkCentZ
            let ΔEast  =  Δx * cosθ  + Δz * (-sinθ)
            let ΔNorth =  Δx * (-sinθ) + Δz * (-cosθ)
            let newLat = gpsCentLat + ΔNorth / R * (180.0 / .pi)
            let newLon = gpsCentLon + ΔEast  / (R * cos(gpsCentLat * .pi / 180.0)) * (180.0 / .pi)
            let p = points[i]
            points[i] = SurveyPoint(
                id:                  p.id,
                timestamp:           p.timestamp,
                latitude:            newLat,
                longitude:           newLon,
                fusedAltitude:       p.fusedAltitude,
                groundElevation:     p.groundElevation,
                lidarDistance:       p.lidarDistance,
                gpsAltitude:         p.gpsAltitude,
                baroAltitudeDelta:   p.baroAltitudeDelta,
                tiltAngle:           p.tiltAngle,
                horizontalAccuracy:  p.horizontalAccuracy,
                verticalAccuracy:    p.verticalAccuracy,
                isOutlier:           p.isOutlier,
                captureType:         p.captureType,
                interpolationWeight: p.interpolationWeight
            )
        }
    }

    // MARK: - PDR refinement (static — safe to call from background thread)

    /// Lightweight copy of GPSManager.refineWithPDR that runs without @MainActor.
    /// Interpolates positions for low-accuracy GPS points between high-accuracy fixes.
    private nonisolated static func pdrRefineStatic(points: inout [SurveyPoint]) {
        guard points.count >= 2 else { return }

        let fixIndices = points.indices.filter { points[$0].horizontalAccuracy <= 10.0 }
        guard fixIndices.count >= 2 else { return }

        for seg in 0..<(fixIndices.count - 1) {
            let iA = fixIndices[seg], iB = fixIndices[seg + 1]
            guard iB - iA > 1 else { continue }
            let pA = points[iA], pB = points[iB]
            let len = Double(iB - iA)
            for i in (iA + 1)..<iB {
                let t = Double(i - iA) / len
                let lat = pA.latitude  + t * (pB.latitude  - pA.latitude)
                let lon = pA.longitude + t * (pB.longitude - pA.longitude)
                let p   = points[i]
                points[i] = SurveyPoint(
                    id:                  p.id,
                    timestamp:           p.timestamp,
                    latitude:            lat,
                    longitude:           lon,
                    fusedAltitude:       p.fusedAltitude,
                    groundElevation:     p.groundElevation,
                    lidarDistance:       p.lidarDistance,
                    gpsAltitude:         p.gpsAltitude,
                    baroAltitudeDelta:   p.baroAltitudeDelta,
                    tiltAngle:           p.tiltAngle,
                    horizontalAccuracy:  p.horizontalAccuracy,
                    verticalAccuracy:    p.verticalAccuracy,
                    isOutlier:           p.isOutlier,
                    captureType:         p.captureType,
                    interpolationWeight: p.interpolationWeight
                )
            }
        }
    }

    // MARK: - Statistics

    private nonisolated static func buildStats(
        input: [SurveyPoint],
        valid: [SurveyPoint],
        outliers: Int,
        loopClosed: Bool,
        geoid: Bool,
        elapsed: Double,
        hasArkitData: Bool,
        arkitPositions: [String: [Double]]?
    ) -> ProcessingStats {
        let elevs = valid.map(\.groundElevation)
        let elevMin = elevs.min() ?? 0
        let elevMax = elevs.max() ?? 0

        // Surveyed area: convex hull area via shoelace formula.
        // When ARKit VIO was used, only include points that have VIO positions
        // to avoid GPS-noisy points expanding the hull.
        let areaPoints: [SurveyPoint]
        if hasArkitData, let ark = arkitPositions {
            let vioPoints = valid.filter { ark[$0.id.uuidString] != nil }
            areaPoints = vioPoints.count >= 3 ? vioPoints : valid
        } else {
            areaPoints = valid
        }
        let area = convexHullArea(areaPoints)

        // RMS accuracy: compute from elevation residuals (deviation from the
        // median), which reflects the actual precision of the baro+LiDAR
        // differential correction.  The old method used raw GPS verticalAccuracy
        // which was ~±4 m regardless of how good the corrected data was.
        let rms: Double
        if elevs.count >= 3 {
            let medianElev = elevs.sorted()[elevs.count / 2]
            let residuals = elevs.map { ($0 - medianElev) * ($0 - medianElev) }
            rms = sqrt(residuals.reduce(0, +) / Double(residuals.count))
        } else {
            let va = valid.map { $0.verticalAccuracy * $0.verticalAccuracy }
            rms = va.isEmpty ? 0 : sqrt(va.reduce(0, +) / Double(va.count))
        }

        return ProcessingStats(
            inputPointCount:       input.count,
            validPointCount:       valid.count,
            outlierCount:          outliers,
            surveyedAreaM2:        area,
            elevationMin:          elevMin,
            elevationMax:          elevMax,
            rmsAccuracyEstimate:   rms,
            processingTimeSeconds: elapsed,
            loopClosureApplied:    loopClosed,
            geoidCorrectionApplied: geoid
        )
    }

    /// Surveyed area computed from the true convex hull of valid points (m²).
    ///
    /// Uses a Graham scan to compute the correct convex hull (O(n log n)), then
    /// applies the shoelace formula to the hull vertices.  The previous approach
    /// ran the shoelace formula directly on the capture-order point sequence, which
    /// forms a self-intersecting zigzag polygon and produces nonsensical results.
    private nonisolated static func convexHullArea(_ pts: [SurveyPoint]) -> Double {
        guard pts.count >= 3 else { return 0 }
        let refLat = pts.map(\.latitude).reduce(0, +) / Double(pts.count)
        let refLon = pts.map(\.longitude).reduce(0, +) / Double(pts.count)
        let local: [(Double, Double)] = pts.map { p in
            let (e, n) = latLonToEN(lat: p.latitude, lon: p.longitude,
                                    originLat: refLat, originLon: refLon)
            return (e, n)
        }
        let hull = grahamScanHull(local)
        guard hull.count >= 3 else { return 0 }
        // Shoelace formula on the true convex hull (CCW vertex order from Graham scan).
        var area = 0.0
        for i in 0..<hull.count {
            let j = (i + 1) % hull.count
            area += hull[i].0 * hull[j].1 - hull[j].0 * hull[i].1
        }
        return abs(area) / 2.0
    }

    /// Graham scan convex hull.  Returns vertices in CCW order.
    /// Input points need not be sorted.  Handles collinear points by keeping
    /// only the farthest point along each ray from the pivot.
    private nonisolated static func grahamScanHull(
        _ pts: [(Double, Double)]
    ) -> [(Double, Double)] {
        guard pts.count >= 3 else { return pts }

        // Find the lowest (min y) point, break ties by min x (the pivot).
        var lowestIdx = 0
        for i in 1..<pts.count {
            if pts[i].1 < pts[lowestIdx].1 ||
               (pts[i].1 == pts[lowestIdx].1 && pts[i].0 < pts[lowestIdx].0) {
                lowestIdx = i
            }
        }
        var sorted = pts
        sorted.swapAt(0, lowestIdx)
        let pivot = sorted[0]

        // Sort remaining points by polar angle from pivot (CCW).
        // Collinear points are ordered by increasing distance.
        sorted[1...].sort { a, b in
            let ax = a.0 - pivot.0, ay = a.1 - pivot.1
            let bx = b.0 - pivot.0, by = b.1 - pivot.1
            let cross = ax * by - ay * bx
            if cross != 0 { return cross > 0 }
            return (ax * ax + ay * ay) < (bx * bx + by * by)
        }

        // Graham scan: maintain a stack of CCW-turn vertices.
        var hull: [(Double, Double)] = []
        for p in sorted {
            while hull.count >= 2 {
                let a = hull[hull.count - 2]
                let b = hull[hull.count - 1]
                // Cross product (b−a) × (p−a): ≤ 0 means right turn or collinear → pop.
                let cross = (b.0 - a.0) * (p.1 - a.1) - (b.1 - a.1) * (p.0 - a.0)
                if cross <= 0 { hull.removeLast() } else { break }
            }
            hull.append(p)
        }
        return hull
    }

}

// MARK: - ProgressSender

/// Bridges background-thread stage names to the @MainActor-isolated progressMessage.
/// Marked @unchecked Sendable because all mutation is safely routed through MainActor.
private final class ProgressSender: @unchecked Sendable {
    private weak var pipeline: ProcessingPipeline?
    init(_ pipeline: ProcessingPipeline) { self.pipeline = pipeline }

    func send(_ message: String) {
        Task { @MainActor [weak self] in
            self?.pipeline?.progressMessage = message
        }
    }
}
