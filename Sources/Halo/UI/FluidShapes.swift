import SwiftUI

/// Organic radius modulation: two gentle, low harmonics so the edge looks
/// irregular but stays smooth. Seamless over a full turn; `phase` animates it.
@inline(__always)
func wobbleOffset(angle: CGFloat, amp: CGFloat, lobes: CGFloat, phase: CGFloat) -> CGFloat {
    guard amp > 0 else { return 0 }
    let l = max(1, lobes.rounded())
    return amp * (0.78 * sin(l * angle + phase) + 0.22 * sin((l + 2) * angle + phase * 0.6))
}

extension Path {
    /// Smooth closed curve through `pts` (Catmull-Rom → cubic Bézier).
    mutating func addSmoothClosedCurve(_ pts: [CGPoint]) {
        let n = pts.count
        guard n > 2 else {
            if let f = pts.first { move(to: f); pts.dropFirst().forEach { addLine(to: $0) }; closeSubpath() }
            return
        }
        move(to: pts[0])
        for i in 0..<n {
            let p0 = pts[(i - 1 + n) % n], p1 = pts[i]
            let p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            addCurve(to: p2, control1: c1, control2: c2)
        }
        closeSubpath()
    }
}

// MARK: - Sampling helpers

/// Polar radius of an upright rounded square (half-side `h`, corner radius =
/// `cornerFrac` of the half-side). cornerFrac 0 → sharp square, 1 → circle.
@inline(__always)
func roundedSquareRadius(_ theta: CGFloat, half h: CGFloat, cornerFrac: CGFloat) -> CGFloat {
    let cr = max(0, min(h, cornerFrac * h))
    let cx = abs(cos(theta)), cy = abs(sin(theta))
    let k = h - cr
    if cx > 1e-6 { let tv = h / cx; if tv * cy <= k { return tv } } // flat vertical edge
    if cy > 1e-6 { let th = h / cy; if th * cx <= k { return th } } // flat horizontal edge
    let b = k * (cx + cy)                                           // corner arc
    let disc = b * b - (2 * k * k - cr * cr)
    return disc > 0 ? b + disc.squareRoot() : h
}

/// Perimeter of the bulge — an upright rounded square with an adjustable corner
/// radius (cornerFrac), with optional organic wobble. Shared by the fill shape
/// and the cohesive edge so they line up exactly.
func bulgePerimeter(center: CGPoint, half: CGFloat, cornerFrac: CGFloat,
                    amp: CGFloat, lobes: CGFloat, phase: CGFloat, steps: Int = 96) -> [CGPoint] {
    var pts: [CGPoint] = []
    pts.reserveCapacity(steps)
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let base = roundedSquareRadius(t, half: half, cornerFrac: cornerFrac)
        let r = base + wobbleOffset(angle: t, amp: amp, lobes: lobes, phase: phase)
        pts.append(CGPoint(x: center.x + r * cos(t), y: center.y + r * sin(t)))
    }
    return pts
}

private func ringSamples(center c: CGPoint, radius r: CGFloat, amp: CGFloat,
                         lobes: CGFloat, phase: CGFloat, clockwise: Bool,
                         steps: Int = 84) -> [CGPoint] {
    var pts: [CGPoint] = []
    pts.reserveCapacity(steps)
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let a = clockwise ? -t : t
        let rr = r + wobbleOffset(angle: a, amp: amp, lobes: lobes, phase: phase)
        pts.append(CGPoint(x: c.x + rr * cos(a), y: c.y + rr * sin(a)))
    }
    return pts
}

// MARK: - Fill shapes

/// The bulge fill — rounded square with adjustable corner radius (cornerFrac;
/// 1 = circle), with optional wobble.
struct BulgeShape: Shape {
    var cornerFrac: CGFloat
    var amp: CGFloat
    var lobes: CGFloat
    var phase: CGFloat
    var animatableData: CGFloat { get { phase } set { phase = newValue } }

    func path(in rect: CGRect) -> Path {
        let half = min(rect.width, rect.height) / 2 - amp
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addSmoothClosedCurve(bulgePerimeter(center: c, half: half, cornerFrac: cornerFrac,
                                              amp: amp, lobes: lobes, phase: phase))
        return p
    }
}

/// An annulus whose edges wobble organically (smooth). Opposite winding carves
/// the hole — what `.glassEffect` needs to render a true ring.
struct WobblyAnnulus: Shape {
    var innerRatio: CGFloat
    var amp: CGFloat
    var lobes: CGFloat
    var phase: CGFloat
    var animatableData: CGFloat { get { phase } set { phase = newValue } }

    func path(in rect: CGRect) -> Path {
        let outer = min(rect.width, rect.height) / 2 - amp
        let inner = outer * innerRatio
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addSmoothClosedCurve(ringSamples(center: c, radius: outer, amp: amp, lobes: lobes,
                                           phase: phase, clockwise: false))
        p.addSmoothClosedCurve(ringSamples(center: c, radius: inner, amp: amp * 0.4, lobes: lobes,
                                           phase: -phase * 0.8, clockwise: true))
        return p
    }
}

/// A filled disc with a smooth organic edge (sphere bulge variant).
struct WobblyDisc: Shape {
    var amp: CGFloat
    var lobes: CGFloat
    var phase: CGFloat
    var animatableData: CGFloat { get { phase } set { phase = newValue } }

    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2 - amp
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addSmoothClosedCurve(ringSamples(center: c, radius: r, amp: amp, lobes: lobes,
                                           phase: phase, clockwise: false))
        return p
    }
}

// MARK: - Cohesive merged outline

private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = a.x - b.x, dy = a.y - b.y
    return (dx * dx + dy * dy).squareRoot()
}

private func unit(_ v: CGPoint) -> CGPoint {
    let m = (v.x * v.x + v.y * v.y).squareRoot()
    return m > 1e-9 ? CGPoint(x: v.x / m, y: v.y / m) : .zero
}

/// Trim `len` of arc length off BOTH ends of an open point run.
private func trimEnds(_ pts: [CGPoint], _ len: CGFloat) -> [CGPoint] {
    let n = pts.count
    guard n > 4, len > 0 else { return pts }
    var lo = 0, acc: CGFloat = 0
    while lo < n - 2 { acc += dist(pts[lo], pts[lo + 1]); lo += 1; if acc >= len { break } }
    var hi = n - 1; acc = 0
    while hi > 1 { acc += dist(pts[hi], pts[hi - 1]); hi -= 1; if acc >= len { break } }
    guard lo < hi else { return [pts[n / 2]] }
    return Array(pts[lo...hi])
}

/// Smooth bridge from `a` to `b` that leaves `a` along the direction the run was
/// already heading (aPrev→a) and arrives at `b` along the outgoing run direction
/// (b→bNext) — a cubic Bézier tangent to both curves. Because it continues the
/// ring/bulge tangents instead of cutting a chord toward the old corner, the
/// fillet HUGS the shapes (no clipping/gaps), and stays well-behaved even at
/// asymmetric junctions (the upright bulge meeting the ring at a diagonal).
private func tangentBridge(_ a: CGPoint, _ aPrev: CGPoint,
                           _ b: CGPoint, _ bNext: CGPoint, steps: Int = 12) -> [CGPoint] {
    let d = dist(a, b)
    guard d > 0.001, steps > 1 else { return [] }
    let tA = unit(CGPoint(x: a.x - aPrev.x, y: a.y - aPrev.y)) // heading into a
    let tB = unit(CGPoint(x: bNext.x - b.x, y: bNext.y - b.y)) // heading out of b
    let k = d * 0.5
    let c1 = CGPoint(x: a.x + tA.x * k, y: a.y + tA.y * k)
    let c2 = CGPoint(x: b.x - tB.x * k, y: b.y - tB.y * k)
    var out: [CGPoint] = []
    out.reserveCapacity(steps - 1)
    for i in 1..<steps {
        let t = CGFloat(i) / CGFloat(steps), u = 1 - t
        out.append(CGPoint(x: u*u*u*a.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*b.x,
                           y: u*u*u*a.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*b.y))
    }
    return out
}

/// Round the two concave seams of the ring∪bulge silhouette: trim each arm back
/// by `radius` of arc length, then bridge with a tangent fillet that continues
/// the ring/bulge curves — so the stroke/sheen hug the glass outline at every
/// bulge angle. Larger radius → rounder junction (the look is unchanged from the
/// previous fillet; only the bridge shape is corrected).
private func filletedUnion(ring: [CGPoint], bulge b: [CGPoint], radius: CGFloat) -> [CGPoint] {
    guard radius > 0.5, ring.count > 6, b.count > 6 else { return ring + b }
    let r2 = trimEnds(ring, radius)
    let b2 = trimEnds(b, radius)
    guard r2.count > 1, b2.count > 1 else { return ring + b }
    var out: [CGPoint] = []
    out += r2
    out += tangentBridge(r2[r2.count - 1], r2[r2.count - 2], b2[0], b2[1])
    out += b2
    out += tangentBridge(b2[b2.count - 1], b2[b2.count - 2], r2[0], r2[1])
    return out
}

private func pointInPolygon(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
    guard poly.count > 2 else { return false }
    var inside = false
    var j = poly.count - 1
    for i in 0..<poly.count {
        let a = poly[i], b = poly[j]
        if (a.y > p.y) != (b.y > p.y) {
            let t = (p.y - a.y) / (b.y - a.y)
            if p.x < a.x + t * (b.x - a.x) { inside.toggle() }
        }
        j = i
    }
    return inside
}

/// The single contiguous run of kept points around a closed loop (handles wrap).
private func contiguousRun(_ pts: [CGPoint], _ keep: [Bool]) -> [CGPoint] {
    let n = pts.count
    guard keep.contains(false) else { return pts }   // all kept
    guard keep.contains(true) else { return [] }      // none kept
    var start = 0
    for i in 0..<n where keep[i] && !keep[(i - 1 + n) % n] { start = i; break }
    var run: [CGPoint] = []
    var i = start
    repeat {
        guard keep[i] else { break }
        run.append(pts[i])
        i = (i + 1) % n
    } while i != start
    return run
}

/// A single smooth outline tracing the merged silhouette of the ring and the
/// bulge (any shape): the ring's outer edge with a gap where the bulge protrudes,
/// joined to the bulge's outer arc, plus the inner hole. One continuous stroke →
/// no seam. Works in LOCAL coordinates (center is constant; the layer is
/// positioned), and the bulge is driven by an interpolating point (no long-way
/// sweep when the selection moves).
struct DonutEdge: Shape {
    var center: CGPoint        // local donut center (constant)
    var outerR: CGFloat
    var innerRatio: CGFloat
    var amp: CGFloat
    var lobes: CGFloat
    var phase: CGFloat
    var bulgeCenter: CGPoint   // local, animatable point
    var bulgeHalf: CGFloat
    var bulgeCornerFrac: CGFloat
    var bulgeProgress: CGFloat
    var ringHidden: Bool = false
    /// Absolute radius (points) of the fillet where the bulge meets the ring.
    /// Set to match the glass merge so the stroke hugs the glass at the junction.
    var junctionRadius: CGFloat = 0

    // innerRatio is animatable too, so the inner hole edge morphs open in sync
    // with the glass ring's hole during the open/close spring (not just scaled).
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>>> {
        get { AnimatablePair(innerRatio, AnimatablePair(bulgeProgress, AnimatablePair(bulgeCenter.x, AnimatablePair(bulgeCenter.y, phase)))) }
        set {
            innerRatio = newValue.first
            bulgeProgress = newValue.second.first
            bulgeCenter.x = newValue.second.second.first
            bulgeCenter.y = newValue.second.second.second.first
            phase = newValue.second.second.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let baseOuter = outerR - amp
        let baseInner = baseOuter * innerRatio
        let half = bulgeHalf * bulgeProgress
        let bulge = (bulgeProgress > 0.01 && half > 1)
            ? bulgePerimeter(center: bulgeCenter, half: half, cornerFrac: bulgeCornerFrac,
                             amp: amp, lobes: lobes, phase: phase * 1.3)
            : []

        if ringHidden {
            if !bulge.isEmpty { p.addSmoothClosedCurve(bulge) }
            return p
        }

        // Inner hole (always a full smooth loop). Wound OPPOSITE the outer contour
        // so this path also renders a true hole when FILLED (nonzero rule) — it's
        // used both as the edge stroke and as the unified glass clip shape.
        p.addSmoothClosedCurve(ringSamples(center: center, radius: baseInner, amp: amp * 0.4,
                                           lobes: lobes, phase: -phase * 0.8, clockwise: true))

        let ringPts = ringSamples(center: center, radius: baseOuter, amp: amp,
                                  lobes: lobes, phase: phase, clockwise: false)

        let protrudes = bulge.contains { dist($0, center) > baseOuter }
        guard protrudes else { p.addSmoothClosedCurve(ringPts); return p }

        let ringRun = contiguousRun(ringPts, ringPts.map { !pointInPolygon($0, bulge) })
        let bulgeRun = contiguousRun(bulge, bulge.map { dist($0, center) > baseOuter })

        if ringRun.isEmpty { p.addSmoothClosedCurve(bulge); return p }
        if bulgeRun.isEmpty { p.addSmoothClosedCurve(ringPts); return p }

        var b = bulgeRun
        if let rl = ringRun.last, let bf = b.first, let bl = b.last, dist(rl, bl) < dist(rl, bf) {
            b.reverse()
        }
        let merged = filletedUnion(ring: ringRun, bulge: b,
                                   radius: min(junctionRadius, half * 0.9))
        p.addSmoothClosedCurve(merged)
        return p
    }
}
