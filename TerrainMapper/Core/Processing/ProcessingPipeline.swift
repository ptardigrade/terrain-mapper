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
    @Published fileprivate(set) var progress: Double = 0.0

    // MARK: - Partial results (published progressively as pipeline stages complete)

    @Published fileprivate(set) var partialSession: SurveySession?
    @Published fileprivate(set) var partialPoints: [SurveyPoint]?
    @Published fileprivate(set) var partialOutliers: [SurveyPoint]?
    @Published fileprivate(set) var partialMesh: TerrainMesh?
    @Published fileprivate(set) var partialContours: [ContourLine]?
    @Published fileprivate(set) var partialStats: ProcessingStats?

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
    /// Run the full processing pipeline on `session` asynchronously.
    ///
    /// - Parameters:
    ///   - session: The completed survey session to process.
    ///   - arMeshVertices: AR mesh vertices as `[[x, y, z]]` in ARKit world space.
    ///     These are converted to geographic coordinates and added as low-weight
    ///     supplementary points for the interpolation grid.
    /// - Returns: A `ProcessedTerrain` with all derived products.
    func process(session: SurveySession, arMeshVertices: [[Float]] = []) async -> ProcessedTerrain {
        // Clear previous partial results
        partialSession = session
        partialPoints = nil
        partialOutliers = nil
        partialMesh = nil
        partialContours = nil
        partialStats = nil
        progress = 0.0

        isProcessing = true
        progressMessage = "Starting…"
        let startTime = Date()

        let capturedContourInterval     = contourInterval
        let capturedGridResolution      = gridResolution
        let capturedInterpolationMethod = interpolationMethod
        let capturedGeoidEnabled        = enableGeoidCorrection
        let capturedMadThreshold        = madThreshold
        let capturedElevationOffset     = elevationOffset
        let capturedArkitPositions      = session.arkitPositions
        let capturedArkitHeading        = session.arkitAnchorHeading
        let capturedMeshVertices        = arMeshVertices

        let sender = ProgressSender(self)
        let resultSender = ResultSender(self)

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
                arMeshVertices:        capturedMeshVertices,
                updateProgress:        { msg in sender.send(msg) },
                sendResult:            resultSender
            )
        }.value

        isProcessing = false
        progressMessage = ""
        progress = 1.0
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
        arMeshVertices:       [[Float]],
        updateProgress:       (String) -> Void,
        sendResult:           ResultSender
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

        // ── 4c. Integrate AR mesh vertices as supplementary points ────────
        let surveyOnlyPoints = points.filter { !$0.isOutlier }
        var validPoints = surveyOnlyPoints
        if !arMeshVertices.isEmpty,
           let ark = arkitPositions, let heading = arkitAnchorHeading {
            updateProgress("Integrating AR mesh data…")
            let meshPts = convertMeshVerticesToPoints(
                vertices: arMeshVertices,
                arkitPositions: ark,
                capturedPoints: points,
                anchorHeadingDeg: heading
            )
            validPoints.append(contentsOf: meshPts)
        }

        // Publish points (Stats tab can show basic info)
        sendResult.sendPoints(validPoints, outliers: points.filter(\.isOutlier))
        sendResult.sendProgress(0.4)

        // ── 5. Interpolation → grid ───────────────────────────────────────
        updateProgress("Interpolating terrain grid…")
        var interp = TerrainInterpolator()
        interp.gridResolutionMeters = gridResolution
        var grid = interp.interpolate(
            points:     validPoints,
            pathPoints: pathPoints,
            method:     interpolationMethod
        )
        // Laplacian smoothing removes noise spikes from AR mesh data while
        // preserving the overall terrain shape measured by survey points.
        grid.smooth(iterations: 3)
        sendResult.sendProgress(0.6)

        // ── 6. Mesh generation ─────────────────────────────────────────────
        // Generate from the smoothed interpolation grid.  This produces a
        // mid-detail mesh — more geometry than survey-point-only Delaunay,
        // but smooth (not spiky like raw AR mesh).
        updateProgress("Building 3D mesh…")
        let meshGen = MeshGenerator()
        let mesh = meshGen.generateMesh(from: grid)
        sendResult.sendMesh(mesh)
        sendResult.sendProgress(0.75)

        // ── 7. Contour extraction ──────────────────────────────────────────
        updateProgress("Drawing contour lines…")
        let cGen = ContourGenerator()
        let contours = cGen.generateContours(from: grid, interval: contourInterval)
        sendResult.sendContours(contours)
        sendResult.sendProgress(0.9)

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
        sendResult.sendStats(stats)
        sendResult.sendProgress(1.0)

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
        // Exclude points with no real GPS fix (horizontalAccuracy >= 9999).
        let gpsPoints = points.filter { $0.horizontalAccuracy < 9999 }
        let centroidSource = gpsPoints.isEmpty ? points : gpsPoints
        let gpsCentLat = centroidSource.map(\.latitude).reduce(0, +) / Double(centroidSource.count)
        let gpsCentLon = centroidSource.map(\.longitude).reduce(0, +) / Double(centroidSource.count)

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

    // MARK: - AR mesh → geographic point conversion

    /// Converts ARKit world-space mesh vertices to geographic SurveyPoints.
    ///
    /// Uses the same rotation + centroid anchoring as `arkitRefinePositions`
    /// to map XZ → lat/lon, and computes a Y→elevation offset from the
    /// captured points that have both ARKit positions and corrected elevations.
    /// Mesh-derived points receive a low interpolation weight (0.3) so they
    /// supplement — not dominate — the real captured survey points.
    private nonisolated static func convertMeshVerticesToPoints(
        vertices: [[Float]],
        arkitPositions: [String: [Double]],
        capturedPoints: [SurveyPoint],
        anchorHeadingDeg: Double
    ) -> [SurveyPoint] {
        let arkPoints = capturedPoints.filter {
            !$0.isOutlier && arkitPositions[$0.id.uuidString] != nil
        }
        guard arkPoints.count >= 2 else { return [] }

        // ARKit centroid + mean ARKit Y and mean corrected elevation
        var arkCentX = 0.0, arkCentZ = 0.0, arkCentY = 0.0, elevSum = 0.0
        for p in arkPoints {
            let pos = arkitPositions[p.id.uuidString]!
            arkCentX += pos[0]
            arkCentZ += pos[1]
            arkCentY += pos.count > 2 ? pos[2] : -1.2
            elevSum  += p.groundElevation
        }
        let n = Double(arkPoints.count)
        arkCentX /= n; arkCentZ /= n; arkCentY /= n; elevSum /= n

        // Y offset: correctedElevation ≈ arkitY + yOffset
        let yOffset = elevSum - arkCentY

        // GPS centroid (geographic anchor — exclude no-GPS placeholders)
        let realGPS = capturedPoints.filter { $0.horizontalAccuracy < 9999 }
        let centSrc = realGPS.isEmpty ? capturedPoints : realGPS
        let gpsCentLat = centSrc.map(\.latitude).reduce(0, +) / Double(centSrc.count)
        let gpsCentLon = centSrc.map(\.longitude).reduce(0, +) / Double(centSrc.count)

        let θ = anchorHeadingDeg * .pi / 180.0
        let cosθ = cos(θ), sinθ = sin(θ)
        let R = 6_371_000.0

        var result: [SurveyPoint] = []
        result.reserveCapacity(vertices.count)

        for v in vertices {
            guard v.count >= 3 else { continue }
            let x = Double(v[0]), y = Double(v[1]), z = Double(v[2])

            let Δx = x - arkCentX
            let Δz = z - arkCentZ
            let ΔEast  =  Δx * cosθ  + Δz * (-sinθ)
            let ΔNorth =  Δx * (-sinθ) + Δz * (-cosθ)
            let lat = gpsCentLat + ΔNorth / R * (180.0 / .pi)
            let lon = gpsCentLon + ΔEast / (R * cos(gpsCentLat * .pi / 180.0)) * (180.0 / .pi)
            let elev = y + yOffset

            result.append(SurveyPoint(
                id:                  UUID(),
                timestamp:           Date(),
                latitude:            lat,
                longitude:           lon,
                fusedAltitude:       elev,
                groundElevation:     elev,
                lidarDistance:       0,
                gpsAltitude:         0,
                baroAltitudeDelta:   0,
                tiltAngle:           0,
                horizontalAccuracy:  0.05,
                verticalAccuracy:    0.05,
                isOutlier:           false,
                captureType:         .lidar,
                interpolationWeight: 0.15
            ))
        }

        // ── Filter outlier mesh vertices (walls, roofs, fences) ─────────
        // Use capture-point elevations as ground truth.  Any mesh vertex
        // whose converted elevation falls far outside the capture range is
        // from a non-ground surface and must be discarded.
        let captureElevs = capturedPoints
            .filter { !$0.isOutlier }
            .map(\.groundElevation)
            .sorted()
        if !captureElevs.isEmpty {
            let median = captureElevs[captureElevs.count / 2]
            let captureRange = captureElevs.last! - captureElevs.first!
            let tolerance = max(captureRange * 2.0, 3.0)
            result = result.filter {
                $0.groundElevation >= median - tolerance &&
                $0.groundElevation <= median + tolerance
            }
        }

        return result
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
/// Uses DispatchQueue.main.async (not Task @MainActor) so updates are delivered
/// to the run loop immediately, keeping the progress bar and UI responsive.
private final class ProgressSender: @unchecked Sendable {
    private weak var pipeline: ProcessingPipeline?
    private var lastSendTime: CFAbsoluteTime = 0
    init(_ pipeline: ProcessingPipeline) { self.pipeline = pipeline }

    func send(_ message: String) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSendTime > 0.1 else { return }   // 100 ms throttle
        lastSendTime = now
        DispatchQueue.main.async { [weak self] in
            guard let pipeline = self?.pipeline else { return }
            MainActor.assumeIsolated {
                pipeline.progressMessage = message
            }
        }
    }
}

// MARK: - ResultSender

/// Bridges partial pipeline results to @MainActor-isolated published properties.
/// Uses DispatchQueue.main.async for reliable run-loop integration.
final class ResultSender: @unchecked Sendable {
    private weak var pipeline: ProcessingPipeline?
    init(_ pipeline: ProcessingPipeline) { self.pipeline = pipeline }

    func sendProgress(_ value: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let pipeline = self?.pipeline else { return }
            MainActor.assumeIsolated {
                pipeline.progress = value
            }
        }
    }

    func sendPoints(_ valid: [SurveyPoint], outliers: [SurveyPoint]) {
        DispatchQueue.main.async { [weak self] in
            guard let pipeline = self?.pipeline else { return }
            MainActor.assumeIsolated {
                pipeline.partialPoints = valid
                pipeline.partialOutliers = outliers
            }
        }
    }

    func sendMesh(_ mesh: TerrainMesh) {
        DispatchQueue.main.async { [weak self] in
            guard let pipeline = self?.pipeline else { return }
            MainActor.assumeIsolated {
                pipeline.partialMesh = mesh
            }
        }
    }

    func sendContours(_ contours: [ContourLine]) {
        DispatchQueue.main.async { [weak self] in
            guard let pipeline = self?.pipeline else { return }
            MainActor.assumeIsolated {
                pipeline.partialContours = contours
            }
        }
    }

    func sendStats(_ stats: ProcessingStats) {
        DispatchQueue.main.async { [weak self] in
            guard let pipeline = self?.pipeline else { return }
            MainActor.assumeIsolated {
                pipeline.partialStats = stats
            }
        }
    }
}
