import SwiftUI

enum GlassStyleChoice: String, CaseIterable, Identifiable {
    case regular, clear
    var id: String { rawValue }
}

enum BulgeShapeKind: String, CaseIterable, Identifiable {
    case icon = "Icon"      // squircle, matches the app icon
    case sphere = "Sphere"  // circle
    var id: String { rawValue }
}

enum GlassPreset: String, CaseIterable, Identifiable {
    case defaultLook = "Default"
    case crystal = "Crystal"
    case frosted = "Frosted"
    case bubble = "Bubble"
    case vivid = "Vivid"
    case minimal = "Minimal"
    var id: String { rawValue }
}

/// Single, live source of truth for the donut's look + motion. The donut views
/// observe it and update in real time.
@MainActor
@Observable
final class Appearance {
    static let shared = Appearance()

    // MARK: Ring geometry (points) — hardcoded to the user's saved values
    var iconSize: Double = 60
    var ringRadius: Double = 104
    var holeRadius: Double = 58
    var outerRadius: Double = 150
    var floatOffset: Double = 25.38
    var bumpExtra: Double = 34
    var iconSelectedScale: Double = 1.14

    // MARK: No-ring mode
    var ringHidden: Bool = false

    // MARK: Hover push (neighbors ease away from the hovered icon)
    var pushIntensity: Double = 0.20   // multiplier on the count-aware push
    var mockIconCount: Double = 0      // test-only: add N fake icons to the ring

    // MARK: Ring drop shadow
    var ringShadowRadius: Double = 10
    var ringShadowOpacity: Double = 0.2
    var ringShadowY: Double = 5

    // MARK: Ring glass material
    var ringStyle: GlassStyleChoice = .regular
    var ringTintEnabled: Bool = true
    var ringTint: Color = Color(.sRGB, red: 0.35, green: 0.55, blue: 1.0, opacity: 0.30)

    // MARK: Bulge glass material
    var bulgeShape: BulgeShapeKind = .icon
    var bulgeCornerRadius: Double = 0.95   // fraction of half-size (1 = circle)
    var bulgeStyle: GlassStyleChoice = .regular
    var bulgeInteractive: Bool = true
    var bulgeTintEnabled: Bool = false
    var bulgeTint: Color = Color(.sRGB, red: 0.50, green: 0.70, blue: 1.0, opacity: 0.35)

    // MARK: Faked depth/material (no public refraction API — these approximate it)
    var frost: Double = 0          // 0…1 milky overlay on the glass
    var depth: Double = 0          // 0…1 inner-shadow thickness illusion

    // MARK: Backdrop — blur the whole screen behind the toolbar
    var screenBlur: Double = 10.37 // Gaussian radius; 0 = off

    // MARK: Fluid edges (organic "orb" wobble on the ring + bulge)
    var wobbleEnabled: Bool = false
    var wobbleAmplitude: Double = 5
    var wobbleLobes: Double = 4
    var wobbleSpeed: Double = 0.80

    // MARK: Edge outline
    var edgeEnabled: Bool = true
    var edgeWidth: Double = 0.75
    var edgeColor: Color = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.25)

    // MARK: Junction rounding (soften the corner where the bulge meets the ring)
    // Fillet at the bulge↔ring junction, as a fraction of the glass merge
    // (containerSpacing). 1.0 ≈ matches the glass; lower = tighter, higher = rounder.
    var junctionRoundness: Double = 0.30

    // MARK: Open/close spring (compress into a sphere → spring out into the ring)
    var openResponse: Double = 0.30
    var openDamping: Double = 0.70

    // MARK: Specular sheen (faked lighting highlight along the edge)
    var sheenEnabled: Bool = true
    var sheenIntensity: Double = 0.80
    var sheenAngle: Double = 315        // used when the light source is OFF
    var sheenWidth: Double = 0.35
    // Global light source: sheen faces a fixed point on screen (top-center by
    // default), so the highlight shifts as the donut moves across the display.
    var lightSourceEnabled: Bool = true
    var lightX: Double = 0.5            // unit position on screen (0…1)
    var lightY: Double = 0.0            // 0 = top

    // MARK: Chromatic aberration
    var aberrationEnabled: Bool = false
    var aberrationAmount: Double = 0.0

    // MARK: Shadow (glass blobs)
    var shadowRadius: Double = 7.68
    var shadowOpacity: Double = 0.30
    var shadowY: Double = 4

    // MARK: Icon shadow (heavier in no-ring mode)
    var iconShadowRadius: Double = 10.35
    var iconShadowOpacity: Double = 0.30
    var iconShadowY: Double = 4

    // MARK: Preview cards
    var previewWidth: Double = 240
    var previewHeight: Double = 150.31
    var previewCornerRadius: Double = 14
    var previewGap: Double = 34.16
    var stackPeek: Double = 14.44
    /// Scale of the cards BEHIND the front card in the (un-fanned) stack. 1.0 =
    /// same size as the front card; lower = the peeking cards shrink back. Only
    /// affects the deck, not the fanned-out cards or the top card.
    var stackBackScale: Double = 0.96
    /// Rotation (degrees) added per card behind the front in the stack. 0 = no
    /// rotation (flat deck). The top card is never rotated.
    var stackRotation: Double = -0.01
    var fanSpacing: Double = 0.00
    var borderWidth: Double = 1.0
    var borderColor: Color = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.22)

    // MARK: Motion
    var springResponse: Double = 0.35
    var springDamping: Double = 0.72
    var containerSpacing: Double = 24.27

    // MARK: Derived

    var geometry: DonutGeometry {
        DonutGeometry(
            iconSize: iconSize, ringRadius: ringRadius, holeRadius: holeRadius,
            outerRadius: outerRadius, floatOffset: floatOffset,
            bandThickness: max(0, outerRadius - holeRadius),
            previewSize: CGSize(width: previewWidth, height: previewHeight),
            previewGap: previewGap, stackPeek: stackPeek, fanSpacing: fanSpacing
        )
    }

    var spring: Animation { .spring(response: springResponse, dampingFraction: springDamping) }
    var repositionAnimation: Animation { .spring(response: 0.5, dampingFraction: 0.85) }

    /// Springy open: fast with a little overshoot so the ring "pops" outward.
    var openAnimation: Animation { .spring(response: openResponse, dampingFraction: openDamping) }
    /// Close: a touch quicker and better-damped so it sucks back in cleanly.
    var closeResponse: Double { max(0.18, openResponse * 0.8) }
    var closeDamping: Double { min(1.0, openDamping + 0.2) }
    var closeAnimation: Animation { .spring(response: closeResponse, dampingFraction: closeDamping) }
    /// How long to keep the panel on screen so the close animation can finish
    /// collapsing before the window is removed.
    var closeDuration: Double { max(0.34, openResponse * 1.5) }

    func ringGlass() -> Glass {
        var g: Glass = (ringStyle == .clear) ? .clear : .regular
        if ringTintEnabled { g = g.tint(ringTint) }
        return g
    }
    func bulgeGlass() -> Glass {
        var g: Glass = (bulgeStyle == .clear) ? .clear : .regular
        if bulgeTintEnabled { g = g.tint(bulgeTint) }
        if bulgeInteractive { g = g.interactive() }
        return g
    }
    /// Window-preview panes use the bulge's material (so the bulge reads as
    /// flowing into the pane), minus interactivity.
    func paneGlass() -> Glass {
        var g: Glass = (bulgeStyle == .clear) ? .clear : .regular
        if bulgeTintEnabled { g = g.tint(bulgeTint) }
        return g
    }

    var effectiveWobble: CGFloat { wobbleEnabled ? CGFloat(wobbleAmplitude) : 0 }
    /// Corner fraction actually used: a full circle for the sphere variant, else
    /// the slider value.
    var effectiveBulgeCorner: CGFloat { bulgeShape == .sphere ? 1 : CGFloat(bulgeCornerRadius) }

    func ringShape(innerRatio: CGFloat, phase: CGFloat) -> AnyShape {
        wobbleEnabled
            ? AnyShape(WobblyAnnulus(innerRatio: innerRatio, amp: CGFloat(wobbleAmplitude),
                                     lobes: CGFloat(wobbleLobes), phase: phase))
            : AnyShape(Annulus(innerRatio: innerRatio))
    }
    func bulgeFillShape(phase: CGFloat) -> AnyShape {
        AnyShape(BulgeShape(cornerFrac: effectiveBulgeCorner,
                            amp: effectiveWobble, lobes: CGFloat(wobbleLobes), phase: phase * 1.3))
    }

    /// Sheen angle (degrees) for a donut centered at `center` on a `screen`-sized
    /// panel: toward the global light source when enabled, else the fixed angle.
    func effectiveSheenAngle(center: CGPoint, screen: CGSize) -> Double {
        guard lightSourceEnabled, screen.width > 0, screen.height > 0 else { return sheenAngle }
        let light = CGPoint(x: lightX * screen.width, y: lightY * screen.height)
        let deg = atan2(light.y - center.y, light.x - center.x) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    // MARK: Presets

    func apply(_ preset: GlassPreset) {
        switch preset {
        case .defaultLook:
            ringHidden = false
            ringStyle = .regular; ringTintEnabled = true
            ringTint = Color(.sRGB, red: 0.35, green: 0.55, blue: 1.0, opacity: 0.30)
            bulgeShape = .icon; bulgeStyle = .regular; bulgeInteractive = true; bulgeTintEnabled = true
            bulgeTint = Color(.sRGB, red: 0.50, green: 0.70, blue: 1.0, opacity: 0.35)
            frost = 0; depth = 0
            wobbleEnabled = false
            edgeEnabled = true; edgeWidth = 0.75; edgeColor = white(0.25)
            sheenEnabled = true; sheenIntensity = 0.9; sheenWidth = 0.35; lightSourceEnabled = true
            aberrationEnabled = false
        case .crystal:
            ringHidden = false
            ringStyle = .clear; bulgeShape = .icon; bulgeStyle = .clear; bulgeInteractive = true
            frost = 0; depth = 0.4
            wobbleEnabled = false
            edgeEnabled = true; edgeWidth = 1.2; edgeColor = white(0.6)
            sheenEnabled = true; sheenIntensity = 0.85; sheenWidth = 0.4; lightSourceEnabled = true
            aberrationEnabled = true; aberrationAmount = 1.6
        case .frosted:
            ringHidden = false
            ringStyle = .regular; bulgeShape = .icon; bulgeStyle = .regular; bulgeInteractive = true
            frost = 0.5; depth = 0.2
            wobbleEnabled = false
            edgeEnabled = true; edgeWidth = 0.75; edgeColor = white(0.25)
            sheenEnabled = false; aberrationEnabled = false
        case .bubble:
            ringHidden = true
            bulgeShape = .sphere; bulgeStyle = .clear; bulgeInteractive = true
            frost = 0; depth = 0.3
            wobbleEnabled = true; wobbleAmplitude = 5; wobbleLobes = 4; wobbleSpeed = 0.8
            edgeEnabled = true; edgeWidth = 1.0; edgeColor = white(0.5)
            sheenEnabled = true; sheenIntensity = 0.9; sheenWidth = 0.35; lightSourceEnabled = true
            aberrationEnabled = true; aberrationAmount = 2.0
            iconShadowRadius = 10; iconShadowOpacity = 0.5; iconShadowY = 4
        case .vivid:
            ringHidden = false
            ringStyle = .regular; ringTintEnabled = true
            ringTint = Color(.sRGB, red: 0.35, green: 0.55, blue: 1.0, opacity: 0.3)
            bulgeShape = .icon; bulgeStyle = .regular; bulgeInteractive = true; bulgeTintEnabled = true
            bulgeTint = Color(.sRGB, red: 0.5, green: 0.7, blue: 1.0, opacity: 0.35)
            edgeEnabled = true; edgeWidth = 1.5; edgeColor = white(0.55)
            sheenEnabled = true; sheenIntensity = 0.8; lightSourceEnabled = true
        case .minimal:
            ringHidden = false
            ringStyle = .regular; bulgeShape = .icon; bulgeStyle = .regular; bulgeInteractive = true
            frost = 0; depth = 0
            wobbleEnabled = false
            edgeEnabled = true; edgeWidth = 0.5; edgeColor = white(0.18)
            sheenEnabled = false; aberrationEnabled = false
        }
    }

    private func white(_ o: Double) -> Color { Color(.sRGB, red: 1, green: 1, blue: 1, opacity: o) }
}
