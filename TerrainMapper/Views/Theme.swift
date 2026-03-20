// Theme.swift
// TerrainMapper
//
// Brand color tokens and style helpers derived from the "Digital Theodolite"
// design system defined in the Stitch project (id: 1239248885632981797).
//
// Usage:
//   .foregroundStyle(Theme.primary)
//   .fill(Theme.primaryGradient)
//   .background(Theme.surfaceContainerHigh)

import SwiftUI

enum Theme {

    // ── Surface hierarchy ─────────────────────────────────────────────────
    /// App background — deepest layer (#131315)
    static let background               = Color(hex: "131315")
    /// Secondary panels / sheet backgrounds (#1b1b1d)
    static let surfaceContainerLow      = Color(hex: "1b1b1d")
    /// Card and row backgrounds (#1f1f21)
    static let surfaceContainer         = Color(hex: "1f1f21")
    /// Interactive / elevated card backgrounds (#2a2a2c)
    static let surfaceContainerHigh     = Color(hex: "2a2a2c")
    /// Focused / active state (#353437)
    static let surfaceContainerHighest  = Color(hex: "353437")

    // ── Brand palette ─────────────────────────────────────────────────────
    /// Primary teal — interactive elements, icons, highlights (#42e5b0)
    static let primary          = Color(hex: "42e5b0")
    /// Primary container — button gradient endpoint (#00c896)
    static let primaryContainer = Color(hex: "00c896")
    /// Secondary — supporting UI (#adcbda)
    static let secondary        = Color(hex: "adcbda")
    /// Tertiary / warning yellow (#f0c900)
    static let tertiary         = Color(hex: "f0c900")

    // ── On-surface text ───────────────────────────────────────────────────
    /// Primary text (#e4e2e4)
    static let onSurface        = Color(hex: "e4e2e4")
    /// Secondary / muted text (#bbcac1)
    static let onSurfaceVariant = Color(hex: "bbcac1")

    // ── Gradients ─────────────────────────────────────────────────────────
    /// CTA button gradient: primary teal → primary container green
    static var primaryGradient: LinearGradient {
        LinearGradient(
            colors: [primary, primaryContainer],
            startPoint: .topLeading,
            endPoint:   .bottomTrailing
        )
    }
}

// MARK: - Color hex initialiser

extension Color {
    /// Initialise a Color from a 6-character hex string (e.g. `"42e5b0"`).
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >>  8) & 0xFF) / 255.0
        let b = Double( int        & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
