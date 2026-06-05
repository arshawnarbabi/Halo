import SwiftUI
import AppKit
import CoreImage

/// Liquid Glass strategy. Plan A uses the native macOS 26 `.glassEffect`. If a
/// runtime check shows glass won't sample content behind our transparent,
/// non-activating panel (or grays out), flip to Plan B, which uses an
/// `NSVisualEffectView` with behind-window blending — guaranteed to sample the
/// desktop and other apps' windows.
enum GlassPlan {
    case planA   // native Liquid Glass
    case planB   // NSVisualEffectView behind-window blur fallback

    /// Mutable so a launch-time spike can switch it before any view is built.
    nonisolated(unsafe) static var current: GlassPlan = .planA
}

/// A ring (annulus) with a true hole. The outer and inner circles are wound in
/// OPPOSITE directions so the default non-zero fill leaves the center empty —
/// this is what `.glassEffect(in:)` needs to render a real ring rather than a
/// filled disc (it uses the shape as a non-zero region).
struct Annulus: Shape {
    var innerRatio: CGFloat
    var animatableData: CGFloat {
        get { innerRatio }
        set { innerRatio = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: .degrees(0),
                 endAngle: .degrees(360), clockwise: false)
        p.closeSubpath()
        p.addArc(center: c, radius: inner, startAngle: .degrees(0),
                 endAngle: .degrees(360), clockwise: true) // opposite winding
        p.closeSubpath()
        return p
    }
}

/// NSVisualEffectView wrapper for the Plan B blur (behind-window sampling).
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.isEmphasized = true
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

extension View {
    /// Apply glass to this view, clipped to `shape`, using the active plan and a
    /// caller-built `Glass` (style/tint/interactive come from Appearance).
    @ViewBuilder
    func donutGlass(_ glass: Glass, in shape: some Shape) -> some View {
        switch GlassPlan.current {
        case .planA:
            self.glassEffect(glass, in: shape)
        case .planB:
            self.background(VisualEffectBlur().clipShape(shape))
        }
    }
}
