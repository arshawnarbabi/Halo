import SwiftUI

/// Root overlay view: the glass donut centered under the cursor, its app icons,
/// and the window previews for the hovered app. Fills the whole (screen-sized)
/// panel so hover tracking and click-outside-to-dismiss work everywhere.
struct DonutView: View {
    let model: SwitcherViewModel

    /// Diameter (fraction of the full ring) of the compressed "sphere" the donut
    /// springs out of when it opens.
    private let ringOpenScale: CGFloat = 0.18

    private var animatingWobble: Bool {
        model.appearance.wobbleEnabled && model.appearance.wobbleSpeed > 0
    }

    var body: some View {
        GeometryReader { geo in
            let full = geo.size
            ZStack(alignment: .topLeading) {
                // The screen-behind blur is a real WindowServer effect on the
                // panel (see SwitcherController.setBlurRadius); re-apply live
                // as the slider moves.
                Color.clear.contentShape(Rectangle()) // click-outside = dismiss
                    .onChange(of: model.appearance.screenBlur) { _, v in
                        model.onBlurChanged?(v)
                    }
                    .onChange(of: model.appearance.mockIconCount) { _, _ in
                        model.onMockCountChanged?()
                    }

                TimelineView(.animation(paused: !animatingWobble)) { tl in
                    let phase = wobblePhase(tl.date)
                    ZStack(alignment: .topLeading) {
                        glassFills(full: full, phase: phase)
                        if model.appearance.edgeEnabled {
                            edgeLayer(full: full, phase: phase)
                        }
                    }
                }
                .frame(width: full.width, height: full.height, alignment: .topLeading)

                // Dynamic, id-keyed ForEach (NOT a constant 0..<count range) so
                // the ring rebuilds safely when the icon count changes.
                ForEach(Array(model.slots.enumerated()), id: \.element.id) { pair in
                    RingIconView(model: model, index: pair.offset)
                }

                if let selected = selectedAppIndex, !model.windows(for: selected).isEmpty {
                    PreviewStackView(model: model, appIndex: selected)
                        .frame(width: full.width, height: full.height, alignment: .topLeading)
                }
            }
            .frame(width: full.width, height: full.height, alignment: .topLeading)
            // Whole-donut fade: held at 1 while open, driven to 0 by the close so
            // every element vanishes together (no leftover sphere/bulge/previews).
            .opacity(Double(model.contentOpacity))
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                withAnimation(model.appearance.spring) {
                    switch phase {
                    case .active(let p): model.updateHover(point: p)
                    case .ended: model.updateHover(point: nil)
                    }
                }
            }
            .gesture(
                SpatialTapGesture(coordinateSpace: .local).onEnded { event in
                    withAnimation(model.appearance.spring) { model.updateHover(point: event.location) }
                    model.commit()
                }
            )
        }
        .ignoresSafeArea()
    }

    private func wobblePhase(_ date: Date) -> CGFloat {
        guard animatingWobble else { return 0 }
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100_000)
        return CGFloat(t) * CGFloat(model.appearance.wobbleSpeed)
    }

    private var selectedAppIndex: Int? {
        switch model.target {
        case .icon(let i): return i
        case .fanned(let app, _): return app
        case .neutral: return nil
        }
    }

    // MARK: - Glass fills (panel coords; animate via .position)

    private func glassFills(full: CGSize, phase: CGFloat) -> some View {
        let g = model.geometry
        let a = model.appearance
        let innerRatio = g.holeRadius / g.outerRadius
        let p = max(0, model.openProgress)
        let ringScale = ringOpenScale + (1 - ringOpenScale) * p

        // ONE unified glass, clipped to the SAME filleted silhouette as the edge
        // stroke — so the GLASS corners at the bulge↔ring junction are rounded
        // exactly like the stroke (the bulge's edges actually round, no gap). The
        // open spring scales it (sphere↔ring) and morphs the hole (innerRatio·p);
        // the bulge grows/moves via the shape's animatable bulgeProgress/center.
        let bumpD = g.iconSize + a.bumpExtra
        let reach = g.ringRadius + g.floatOffset + bumpD / 2 + a.effectiveWobble + a.edgeWidth + 30
        let size = reach * 2
        let local = CGPoint(x: reach, y: reach)
        let selected = selectedAppIndex
        let bulgeLocal: CGPoint = {
            guard let i = selected else { return local }
            let off = g.ringRadius + g.floatOffset
            let ang = g.angle(index: i, count: model.count)
            return CGPoint(x: local.x + off * cos(ang), y: local.y + off * sin(ang))
        }()
        let edge = DonutEdge(center: local, outerR: g.outerRadius, innerRatio: innerRatio * p,
                             amp: a.effectiveWobble, lobes: CGFloat(a.wobbleLobes), phase: phase,
                             bulgeCenter: bulgeLocal, bulgeHalf: bumpD / 2 - a.effectiveWobble,
                             bulgeCornerFrac: a.effectiveBulgeCorner,
                             bulgeProgress: selected == nil ? 0 : 1,
                             ringHidden: a.ringHidden,
                             junctionRadius: CGFloat(a.junctionRoundness * a.containerSpacing))

        return ZStack(alignment: .topLeading) {
            if !a.ringHidden && a.ringShadowOpacity > 0.001 {
                edge.fill(Color.black.opacity(a.ringShadowOpacity))
                    .frame(width: size, height: size)
                    .scaleEffect(ringScale, anchor: .center)
                    .blur(radius: a.ringShadowRadius)
                    .offset(y: a.ringShadowY)
                    .position(model.center)
            }
            Color.clear
                .frame(width: size, height: size)
                .donutGlass(a.ringGlass(), in: edge)
                .glassDepth(AnyShape(edge), frost: a.frost, depth: a.depth)
                .scaleEffect(ringScale, anchor: .center)
                .position(model.center)
        }
    }

    // MARK: - Cohesive edge (local frame; whole layer animates via .position)

    private func edgeLayer(full: CGSize, phase: CGFloat) -> some View {
        let g = model.geometry
        let a = model.appearance
        let innerRatio = g.holeRadius / g.outerRadius
        let bumpD = g.iconSize + a.bumpExtra
        let reach = g.ringRadius + g.floatOffset + bumpD / 2 + a.effectiveWobble + a.edgeWidth + 30
        let size = reach * 2
        let local = CGPoint(x: reach, y: reach)
        let selected = selectedAppIndex

        let bulgeLocal: CGPoint = {
            guard let i = selected else { return local }
            let off = g.ringRadius + g.floatOffset
            let ang = g.angle(index: i, count: model.count)
            return CGPoint(x: local.x + off * cos(ang), y: local.y + off * sin(ang))
        }()

        // The glass bulge (BulgeShape) uses half = frame/2 − amp; match it exactly
        // here (was bumpD/2) so the stroke/sheen trace the glass outline rather
        // than sitting amp points outside it when organic edges are on.
        // Open the inner hole edge in sync with the glass hole (innerRatio * p),
        // so the inside of the ring morphs open with the spring instead of being
        // a constant-ratio loop that only scales (which looked static inside).
        let p = max(0, model.openProgress)
        let edge = DonutEdge(center: local, outerR: g.outerRadius, innerRatio: innerRatio * p,
                             amp: a.effectiveWobble, lobes: CGFloat(a.wobbleLobes), phase: phase,
                             bulgeCenter: bulgeLocal, bulgeHalf: bumpD / 2 - a.effectiveWobble,
                             bulgeCornerFrac: a.effectiveBulgeCorner,
                             bulgeProgress: selected == nil ? 0 : 1,
                             ringHidden: a.ringHidden,
                             // Match the fillet to the glass merge (containerSpacing)
                             // so the stroke hugs the glass at the junction; the
                             // junctionRoundness slider fine-tunes around that.
                             junctionRadius: CGFloat(a.junctionRoundness * a.containerSpacing))

        let sheenAngle = a.effectiveSheenAngle(center: model.center, screen: full)
        let unit = UnitPoint(x: 0.5, y: 0.5) // donut center == frame center

        // Scale + fade the outline with the open animation so it tracks the ring.
        let edgeScale = ringOpenScale + (1 - ringOpenScale) * p

        return ZStack {
            if a.aberrationEnabled {
                let d = CGFloat(a.aberrationAmount)
                edge.stroke(Color.red, lineWidth: a.edgeWidth).offset(x: d, y: d).blendMode(.plusLighter)
                edge.stroke(Color.blue, lineWidth: a.edgeWidth).offset(x: -d, y: -d).blendMode(.plusLighter)
            }
            if a.sheenEnabled {
                edge.stroke(sheenGradient(a: a, center: unit, angleDeg: sheenAngle),
                            lineWidth: max(a.edgeWidth, a.edgeWidth + 0.6))
                    .blendMode(.plusLighter)
            }
            edge.stroke(a.edgeColor, lineWidth: a.edgeWidth)
        }
        .frame(width: size, height: size)
        .scaleEffect(edgeScale, anchor: .center)
        .opacity(Double(p))
        .position(model.center)
    }

    private func sheenGradient(a: Appearance, center: UnitPoint, angleDeg: Double) -> AngularGradient {
        let span = max(0.05, a.sheenWidth) * 0.5
        let mid = angleDeg / 360.0
        let clear = Color.white.opacity(0)
        let bright = Color.white.opacity(a.sheenIntensity)
        return AngularGradient(
            stops: [
                .init(color: clear, location: 0),
                .init(color: clear, location: max(0.0001, mid - span)),
                .init(color: bright, location: min(0.9999, mid)),
                .init(color: clear, location: min(0.9999, mid + span)),
                .init(color: clear, location: 1),
            ],
            center: center
        )
    }
}

/// Frosted-overlay + inner-shadow "depth" faked on top of the glass (the Glass
/// material exposes no blur/refraction knobs).
private struct GlassDepth: ViewModifier {
    let shape: AnyShape
    let frost: Double
    let depth: Double
    func body(content: Content) -> some View {
        content
            .overlay { if frost > 0 { shape.fill(.white.opacity(frost * 0.22)) } }
            .overlay {
                if depth > 0 {
                    shape.stroke(Color.black.opacity(depth * 0.5), lineWidth: depth * 10)
                        .blur(radius: depth * 5)
                        .mask(shape.fill(.black))
                }
            }
    }
}

private extension View {
    func glassDepth(_ shape: AnyShape, frost: Double, depth: Double) -> some View {
        modifier(GlassDepth(shape: shape, frost: frost, depth: depth))
    }
}
