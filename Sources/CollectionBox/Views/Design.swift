import SwiftUI
import AppKit

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
    static let radiusL: CGFloat = 14   // floating panels, large containers

    // Interaction-state alphas
    static let hoverAlpha: Double = 0.09
    static let flashAlpha: Double = 0.14
    static let selectedAlpha: Double = 0.18
    static let wellAlpha: Double = 0.12
    static let slotAlpha: Double = 0.10
}

/// Style option mapping to macOS 26 `NSGlassEffectView.Style`.
enum LiquidGlassStyle: Sendable {
    case regular
    case clear

    @available(macOS 26.0, *)
    var systemStyle: NSGlassEffectView.Style {
        switch self {
        case .regular: return .regular
        case .clear: return .clear
        }
    }
}

/// Native macOS 26 Liquid Glass backdrop powered by AppKit's `NSGlassEffectView`.
/// Falls back gracefully to `NSVisualEffectView` on older macOS versions.
struct GlassEffectBackground: NSViewRepresentable {
    var style: LiquidGlassStyle
    var cornerRadius: CGFloat
    var tintColor: NSColor?
    var enableScrim: Bool

    init(
        style: LiquidGlassStyle = .regular,
        cornerRadius: CGFloat = Design.radiusL,
        tintColor: NSColor? = nil,
        enableScrim: Bool = true
    ) {
        self.style = style
        self.cornerRadius = cornerRadius
        self.tintColor = tintColor
        self.enableScrim = enableScrim
    }

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = style.systemStyle
            glass.cornerRadius = cornerRadius
            glass.tintColor = tintColor
            if enableScrim {
                glass.setValue(1, forKey: "_scrimState")
            }
            return glass
        } else {
            let view = NSVisualEffectView()
            view.material = (style == .clear) ? .contentBackground : .popover
            view.blendingMode = .behindWindow
            view.state = .active
            view.wantsLayer = true
            if cornerRadius > 0 {
                view.layer?.cornerRadius = cornerRadius
                view.layer?.masksToBounds = true
            }
            return view
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = nsView as? NSGlassEffectView {
            glass.style = style.systemStyle
            glass.cornerRadius = cornerRadius
            glass.tintColor = tintColor
            if enableScrim {
                glass.setValue(1, forKey: "_scrimState")
            }
        } else if let view = nsView as? NSVisualEffectView {
            if cornerRadius > 0 {
                view.layer?.cornerRadius = cornerRadius
                view.layer?.masksToBounds = true
            } else {
                view.layer?.cornerRadius = 0
                view.layer?.masksToBounds = false
            }
        }
    }
}

/// Native macOS 26 Liquid Glass container powered by `NSGlassEffectContainerView`.
/// Dynamically merges descendant glass views for fluid optical blending and high rendering performance.
struct GlassEffectContainer<Content: View>: NSViewRepresentable {
    var spacing: CGFloat
    var content: () -> Content

    init(spacing: CGFloat = 0, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            container.spacing = spacing
            let hosting = NSHostingView(rootView: content())
            container.contentView = hosting
            return container
        } else {
            return NSHostingView(rootView: content())
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 26.0, *), let container = nsView as? NSGlassEffectContainerView {
            container.spacing = spacing
            if let hosting = container.contentView as? NSHostingView<Content> {
                hosting.rootView = content()
            }
        } else if let hosting = nsView as? NSHostingView<Content> {
            hosting.rootView = content()
        }
    }
}

/// Native macOS system visual effect backdrop (calls NSVisualEffectView directly for legacy or specialized usages).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.wantsLayer = true
        if cornerRadius > 0 {
            view.layer?.cornerRadius = cornerRadius
            view.layer?.masksToBounds = true
        }
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        if cornerRadius > 0 {
            nsView.layer?.cornerRadius = cornerRadius
            nsView.layer?.masksToBounds = true
        } else {
            nsView.layer?.cornerRadius = 0
            nsView.layer?.masksToBounds = false
        }
    }
}

/// Native macOS 26 Liquid Glass panel backdrop powered directly by `NSGlassEffectView`.
struct LiquidGlassBackground: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    var cornerRadius: CGFloat = Design.radiusL
    var style: LiquidGlassStyle = .regular
    var tintColor: NSColor? = nil

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    // 1. 底层：垫在玻璃背后的系统材质衬底（90%~94% 高实心度，彻底阻断背景桌面杂光与文字干扰）
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(
                            colorScheme == .dark
                                ? Color(NSColor.windowBackgroundColor).opacity(0.90)
                                : Color(NSColor.windowBackgroundColor).opacity(0.94)
                        )
                    // 2. 表层：原生 macOS 26 NSGlassEffectView 质感玻璃（置于最顶层，直接面向用户计算折射、边缘暗角与镜面高光）
                    GlassEffectBackground(
                        style: style,
                        cornerRadius: cornerRadius,
                        tintColor: tintColor,
                        enableScrim: true
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// Native macOS 26 Liquid Glass card backing using `NSGlassEffectView` with clear style.
struct LiquidGlassCard: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    var cornerRadius: CGFloat = Design.radiusM
    var style: LiquidGlassStyle = .clear
    var tintColor: NSColor? = nil

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    // 1. 卡片底层衬垫：88%~94% 扎实底色，使卡片内容具有最佳对比度
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(
                            colorScheme == .dark
                                ? Color(NSColor.controlBackgroundColor).opacity(0.88)
                                : Color(NSColor.controlBackgroundColor).opacity(0.94)
                        )
                    // 2. 卡片表层：清澈质感玻璃，提供流体景深与微高光
                    GlassEffectBackground(
                        style: style,
                        cornerRadius: cornerRadius,
                        tintColor: tintColor,
                        enableScrim: false
                    )
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        Color(NSColor.separatorColor).opacity(colorScheme == .dark ? 0.45 : 0.30),
                        lineWidth: 0.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

extension View {
    func liquidGlassBackground(
        cornerRadius: CGFloat = Design.radiusL,
        style: LiquidGlassStyle = .regular,
        tintColor: NSColor? = nil
    ) -> some View {
        modifier(LiquidGlassBackground(cornerRadius: cornerRadius, style: style, tintColor: tintColor))
    }

    /// Backward-compatible overload for legacy calls specifying NSVisualEffectView.Material
    func liquidGlassBackground(
        cornerRadius: CGFloat = Design.radiusL,
        material: NSVisualEffectView.Material
    ) -> some View {
        modifier(LiquidGlassBackground(cornerRadius: cornerRadius, style: .regular))
    }

    func liquidGlassCard(
        cornerRadius: CGFloat = Design.radiusM,
        style: LiquidGlassStyle = .clear,
        tintColor: NSColor? = nil
    ) -> some View {
        modifier(LiquidGlassCard(cornerRadius: cornerRadius, style: style, tintColor: tintColor))
    }
}
