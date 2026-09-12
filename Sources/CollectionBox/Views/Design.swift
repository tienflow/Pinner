import SwiftUI

/// Shared visual metrics — one scale for type sizes, corner radii, and
/// interaction-state opacities across all panels.
enum Design {
    // Type scale (5 steps; OTP code keeps its 18pt monospaced exception)
    static let micro: CGFloat = 9      // chart axis, badges
    static let caption: CGFloat = 10   // counters, secondary info
    static let ui: CGFloat = 11        // tabs, labels, section headers
    static let body: CGFloat = 13      // primary text, inputs
    // hero numbers stay bespoke: 22pt rounded (stats), 18pt mono (OTP)

    // Corner radii
    static let radiusS: CGFloat = 4    // rows, small controls
    static let radiusM: CGFloat = 8    // cards, icon wells

    // Interaction-state alphas
    static let hoverAlpha: Double = 0.06
    static let flashAlpha: Double = 0.10
    static let selectedAlpha: Double = 0.14
    static let wellAlpha: Double = 0.08
    static let slotAlpha: Double = 0.06
}
