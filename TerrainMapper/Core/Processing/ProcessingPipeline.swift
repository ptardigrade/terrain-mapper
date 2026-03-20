// ProcessingPipeline.swift
// TerrainMapper
//
// Top-level coordinator that runs the full post-processing sequence on a
// completed SurveySession and produces a ProcessedTerrain.
//
// Pipeline stages (in order):
//  1. Outlier detection          (OutlierDetector)
//  2. Loop-closure correction    (LoopClosureProcessor)
//  3. PDR position refinement    (GPSManager)
//  4. Geoid correction           (GeoidCorrector)
//  5. IDW / kriging interpolation → TerrainGrid   (TerrainInterpolator)
//  6. Delaunay triangulation     → TerrainMesh    (MeshGenerator)
//  7. Marching squares contours  → [ContourLine]  (ContourGenerator)
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

    // MARK: - Progress reporting

    @Published private(set) var isProcessing: Bool = false
    @Published private(set) var progressMessage: String = ""

    // MARK: - Sub-processors

    private var outlierDetector  = OutlierDetector()
    private var loopClosure      = LoopClosureProcessor()
    private var geoidCorrector   = GeoidCorrector()
    private var interpolator     = TerrainInterpolator()
    private var meshGenerator    = MeshGenerator()
    private var contourGen       = ContourGenerator()

    // Weak reference to GPSManager for PDR refinement (set by SensorFusionEngine)
    weak var gpsManager: GPSManager?

    // MARK: - Public API

    /// Run the full processing pipeline on `session` asynchronously.
    ///
    /// - Parameter session: The completed survey session to process.
    /// - Returns: A `ProcessedTerrain` with all derived products.
    func process(session: SurveySession) async -> ProcessedTerrain {
        isProcessing = true
        let startTime = Date()

        // Run heavy work off the main thread
        let result = await Task.detached(priority: .userInitiated) { [self] in
            return self.runPipeline(session: session, startTime: startTime)
        }.value

        isProcessing = false
        return result
    }

    // MARK: - Pipeline (non-isolated, runs on background thread)

    private func runPipeline(session: SurveySession, startTime: Date) -> ProcessedTerrain {
        var points = session.points

        // ── 1. Outlier detection ──────────────────────────────────────────
        updateProgress("Detecting outliers…")
        var detector = OutlierDetector()
        detector.madThreshold = madThreshold
        detector.detectOutliers(in: &points)

        let outlierCount = points.filter(\.isOutlier).count

        // ── 2. Loop-closure correction ────────────────────────────────────
        updateProgress("Checking for loop closure…")
        var lcProc = LoopClosureProcessor()
        let loopClosed = lcProc.applyLoopClosure(to: &points)

        // ── 3. PDR position refinement ────────────────────────────────────
        // Note: GPSManager.refineWithPDR is @MainActor so we call a copy
        // of the logic here on the background thread instead.
        updateProgress("Refining positions with PDR…")
        pdrRefine(points: &points)

        // ── 4. Geoid correction ───────────────────────────────────────────
        updateProgress("Applying geoid correction…")
        var geo = GeoidCorrector()
        geo.isEnabled = enableGeoidCorrection
        geo.correct(points: &points)

        // ── 5. Interpolation → grid ───────────────────────────────────────
        updateProgress("Interpolating terrain grid…")
        let validPoints = points.filter { !$0.isOutlier }
        var interp = TerrainInterpolator()
        interp.gridResolutionMeters = gridResolution
        let grid = interp.interpolate(points: validPoints, method: interpolationMethod)

        // ── 6. Mesh generation ─────────────────────────────────────────────
        updateProgress("Triangulating mesh…")
        let meshGen = MeshGenerator()
        let mesh = validPoints.count >= 3
            ? meshGen.generateMesh(from: validPoints)
            : meshGen.generateMesh(from: grid)

        // ── 7. Contour extraction ──────────────────────────────────────────
        updateProgress("Extracting contours…")
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
            elapsed:    elapsed
        )

        updateProgress("Done")
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

    // MARK: - PDR refinement (background-thread version)

    /// Lightweight copy of GPSManager.refineWithPDR that runs without @MainActor.
    /// Interpolates positions for low-accuracy GPS points between high-accuracy fixes.
    private func pdrRefine(points: inout [SurveyPoint]) {
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
                    id: p.id, timestamp: p.timestamp,
                    latitude: lat, longitude: lon,
                    fusedAltitude:      p.fusedAltitude,
                    groundElevation:    p.groundElevation,
                    lidarDistance:      p.lidarDistance,
                    gpsAltitude:        p.gpsAltitude,
                    baroAltitudeDelta:  p.baroAltitudeDelta,
                    tiltAngle:          p.tiltAngle,
                    horizontalAccuracy: p.horizontalAccuracy,
                    verticalAccuracy:   p.verticalAccuracy,
                    isOutlier:          p.isOutlier
                )
            }
        }
    }

    // MARK: - Statistics

    private func buildStats(
        input: [SurveyPoint],
        valid: [SurveyPoint],
        outliers: Int,
        loopClosed: Bool,
        geoid: Bool,
        elapsed: Double
    ) -> ProcessingStats {
        let elevs = valid.map(\.groundElevation)
        let elevMin = elevs.min() ?? 0
        let elevMax = elevs.max() ?? 0

        // Surveyed area: convex hull area via shoelace formula
        let area = convexHullArea(valid)

        // RMS vertical accuracy
        let va = valid.map { $0.verticalAccuracy * $0.verticalAccuracy }
        let rms = va.isEmpty ? 0 : sqrt(va.reduce(0, +) / Double(va.count))

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

    /// Approximate surveyed area using the convex hull shoelace formula (m²).
    private func convexHullArea(_ pts: [SurveyPoint]) -> Double {
        guard pts.count >= 3 else { return 0 }
        let refLat = pts.map(\.latitude).reduce(0, +) / Double(pts.count)
        let refLon = pts.map(\.longitude).reduce(0, +) / Double(pts.count)
        let local = pts.map { p -> (Double, Double) in
            let (e, n) = latLonToEN(lat: p.latitude, lon: p.longitude,
                                    originLat: refLat, originLon: refLon)
            return (e, n)
        }
        // Shoelace (signed area of polygon — not true convex hull but good estimate)
        var area = 0.0
        for i in 0..<local.count {
            let j = (i + 1) % local.count
            area += local[i].0 * local[j].1 - local[j].0 * local[i].1
        }
        return abs(area) / 2
    }

    // MARK: - Progress helper (safe to call from background thread)

    private func updateProgress(_ msg: String) {
        Task { @MainActor in self.progressMessage = msg }
    }
}
