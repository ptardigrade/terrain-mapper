// TiltMeterView.swift
// TerrainMapper
//
// Reusable spirit-level component that visualises device tilt using a
// bubble-in-tube metaphor: a small circle moves inside a larger ring based
// on the live IMU gravity vector.
//
// ─── Physics model ────────────────────────────────────────────────────────
// CMDeviceMotion.gravity gives the normalised gravity vector (gx, gy, gz).
// When the device is held vertically (screen facing the operator), the
// gravity vector projects onto the screen plane as:
//   bubble_x = +gx   (right when tilted right)
//   bubble_y = −gy   (up when tilted forward)
//
// The bubble is clamped to stay within the outer ring radius.
// When the device is perfectly level (tilt ≈ 0), the bubble rests at centre.
//
// ─── Colour coding ────────────────────────────────────────────────────────
//   green   tiltAngle < 3°   — safe to capture
//   yellow  3° – 8°          — marginal
//   red     > 8°             — too tilted; LiDAR reading will be inaccurate

import SwiftUI
import CoreMotion

struct TiltMeterView: View {

    // MARK: - Inputs

    /// Tilt angle in radians from vertical (from IMUManager.tiltAngle).
    var tiltAngle: Double

    /// Raw gravity vector from CMDeviceMotion.gravity (gx, gy components).
    var gravityX: Double = 0
    var gravityY: Double = 0

    /// True when IMU stationary gate is satisfied.
    var isStationary: Bool

    /// Stationary progress from 0.0 to 1.0.
    var stationaryProgress: Double = 0.0

    // MARK: - Constants

    private let outerRadius: CGFloat = 50
    private let bubbleRadius: CGFloat = 10
    private let levelThreshold: Double = 3 * .pi / 180   // 3° in radians
    private let warnThreshold:  Double = 8 * .pi / 180   // 8°

    // MARK: - Body

    var body: some View {
        ZStack {
            // ── Stationary progress arc ───────────────────────────────────
            Circle()
                .trim(from: 0, to: CGFloat(stationaryProgress))
                .stroke(
                    Color.green.opacity(stationaryProgress > 0.95 ? 0.9 : 0.5),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .frame(width: outerRadius * 2, height: outerRadius * 2)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: stationaryProgress)

            // ── Outer ring ────────────────────────────────────────────────
            Circle()
                .strokeBorder(ringColor, lineWidth: 2)
                .frame(width: outerRadius * 2, height: outerRadius * 2)

            // ── Crosshair ─────────────────────────────────────────────────
            Path { path in
                path.move(to:    CGPoint(x: outerRadius, y: outerRadius - 6))
                path.addLine(to: CGPoint(x: outerRadius, y: outerRadius + 6))
                path.move(to:    CGPoint(x: outerRadius - 6, y: outerRadius))
                path.addLine(to: CGPoint(x: outerRadius + 6, y: outerRadius))
            }
            .stroke(Color.secondary.opacity(0.4), lineWidth: 1)

            // ── Bubble ────────────────────────────────────────────────────
            Circle()
                .fill(bubbleColor)
                .frame(width: bubbleRadius * 2, height: bubbleRadius * 2)
                .shadow(color: .black.opacity(0.2), radius: 2)
                .offset(bubbleOffset)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: bubbleOffset)

            // ── LEVEL badge ───────────────────────────────────────────────
            if isStationary && tiltAngle < levelThreshold {
                Text("LEVEL")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.85), in: Capsule())
                    .offset(y: outerRadius + 10)
                    .transition(.scale.combined(with: .opacity))
            }

            // ── Degree label ──────────────────────────────────────────────
            Text(String(format: "%.1f°", tiltAngle * 180 / .pi))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .offset(y: -(outerRadius + 10))
        }
        .frame(width: outerRadius * 2, height: outerRadius * 2 + 24)
    }

    // MARK: - Computed

    private var bubbleOffset: CGSize {
        // Map gravity (range -1…1) to pixel offset within the outer ring.
        // Clamp so the bubble stays inside.
        let maxOffset = outerRadius - bubbleRadius
        let rawX = CGFloat(gravityX) * outerRadius
        let rawY = CGFloat(-gravityY) * outerRadius
        let dist = sqrt(rawX * rawX + rawY * rawY)
        let scale = dist > maxOffset ? maxOffset / dist : 1.0
        return CGSize(width: rawX * scale, height: rawY * scale)
    }

    private var bubbleColor: Color {
        if tiltAngle < levelThreshold { return .green }
        if tiltAngle < warnThreshold  { return .yellow }
        return .red
    }

    private var ringColor: Color {
        if tiltAngle < levelThreshold { return .green.opacity(0.7) }
        if tiltAngle < warnThreshold  { return .yellow.opacity(0.7) }
        return .red.opacity(0.7)
    }
}

// MARK: - Preview

#Preview {
    HStack(spacing: 40) {
        TiltMeterView(tiltAngle: 0.01, gravityX: 0.01, gravityY: 0.01, isStationary: true, stationaryProgress: 1.0)
        TiltMeterView(tiltAngle: 0.08, gravityX: 0.05, gravityY: 0.06, isStationary: false, stationaryProgress: 0.5)
        TiltMeterView(tiltAngle: 0.20, gravityX: 0.15, gravityY: 0.14, isStationary: false, stationaryProgress: 0.1)
    }
    .padding()
}
