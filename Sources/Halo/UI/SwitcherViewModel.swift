import AppKit
import SwiftUI
import CoreGraphics

/// One window-preview card's computed placement (shared by rendering + hit-test).
struct PreviewCardLayout: Identifiable {
    let id: Int            // index within the app's window list
    let window: WindowInfo
    let center: CGPoint
    let rotation: Angle
    let scale: CGFloat
    let z: Double
}

/// Drives the donut: holds the app slots, derives what the cursor is pointing at
/// from absolute geometry (not per-icon hover, which drops at speed), and loads
/// windows + thumbnails lazily for the hovered app.
@MainActor
@Observable
final class SwitcherViewModel {
    private(set) var slots: [AppSlot] = []
    private(set) var center: CGPoint = .zero
    private(set) var target: HoverTarget = .neutral

    /// Open/close animation driver: 0 = compressed into a sphere at center,
    /// 1 = fully sprung out into the ring. Driven by the controller via
    /// `withAnimation` so the ring + icons interpolate.
    var openProgress: CGFloat = 1

    /// Whole-donut opacity. Held at 1 while open; faded to 0 by the controller on
    /// close so EVERYTHING (ring, bulge, previews, edge, icons) disappears
    /// together — no element (e.g. the central sphere or a hover bulge/preview)
    /// is left behind after the ring collapses.
    var contentOpacity: CGFloat = 1

    /// While false, hover/taps are ignored. Set false during the close so a moving
    /// cursor can't re-select an icon (spawning a fresh bulge/previews) on the
    /// still-visible-but-closing panel.
    var interactive: Bool = true

    /// True while the donut is gliding to a new center (lone ⌘ tap). Hover is
    /// suppressed so a moving cursor can't float/push icons on a different spring
    /// than the ring's glide — which made the icons and ring separate mid-move.
    var repositioning: Bool = false

    private(set) var windowsByPID: [pid_t: [WindowInfo]] = [:]
    private(set) var thumbs: [CGWindowID: NSImage] = [:]

    let appearance: Appearance
    var geometry: DonutGeometry { appearance.geometry }
    var backingScale: CGFloat = 2

    /// Called when the user commits a choice (raise + dismiss).
    var onCommit: ((HoverTarget) -> Void)?
    /// Called to dismiss with no switch (click in empty space).
    var onDismiss: (() -> Void)?
    /// Called when the screen-blur radius changes (live) so the panel re-applies.
    var onBlurChanged: ((Double) -> Void)?
    /// Called when the test mock-icon count changes so the ring rebuilds.
    var onMockCountChanged: (() -> Void)?

    private let thumbnails: ThumbnailService
    private var loadingPIDs: Set<pid_t> = []
    private var lastPoint: CGPoint?

    // Monotonic session id. Bumped each time the donut opens; async loads
    // capture it and drop their results if a new session has begun, so stale
    // windows/thumbnails from a previous open can't pollute the current one.
    private var session = 0
    private var loadTasks: [Task<Void, Never>] = []

    init(thumbnails: ThumbnailService, appearance: Appearance) {
        self.thumbnails = thumbnails
        self.appearance = appearance
    }

    func configure(slots: [AppSlot], center: CGPoint, backingScale: CGFloat) {
        session &+= 1
        loadTasks.forEach { $0.cancel() }
        loadTasks.removeAll()
        // NOTE: openProgress is owned by the controller (set to 0 in show() then
        // sprung to 1), NOT reset here — configure() is also called by
        // refreshSlots() while the donut is open, and resetting it there would
        // collapse the live donut to the compressed sphere.
        self.contentOpacity = 1 // fully visible for this session
        self.interactive = true
        self.repositioning = false
        self.slots = slots
        self.center = center
        self.backingScale = backingScale
        self.target = .neutral
        self.windowsByPID.removeAll()
        self.thumbs.removeAll()
        self.loadingPIDs.removeAll()
        self.lastPoint = nil
    }

    var count: Int { slots.count }

    func windows(for appIndex: Int) -> [WindowInfo] {
        guard slots.indices.contains(appIndex) else { return [] }
        return windowsByPID[slots[appIndex].id] ?? []
    }

    var selectedIndex: Int? {
        switch target {
        case .icon(let i): return i
        case .fanned(let app, _): return app
        case .neutral: return nil
        }
    }

    func isSelected(appIndex: Int) -> Bool {
        switch target {
        case .icon(let i): return i == appIndex
        case .fanned(let app, _): return app == appIndex
        case .neutral: return false
        }
    }

    var fannedAppIndex: Int? {
        if case .fanned(let app, _) = target { return app }
        return nil
    }

    // MARK: - Hover derivation

    /// Move the donut center (the cursor is now there → reset to neutral).
    /// Callers wrap this in withAnimation to make the donut glide over.
    func reposition(to newCenter: CGPoint) {
        center = newCenter
        target = .neutral
        lastPoint = nil
    }

    func updateHover(point: CGPoint?) {
        guard interactive, !repositioning else { return } // frozen during close / reposition
        lastPoint = point
        guard let p = point else { target = .neutral; return }

        let v = CGVector(dx: p.x - center.x, dy: p.y - center.y)
        let d = (v.dx * v.dx + v.dy * v.dy).squareRoot()

        if d <= geometry.holeRadius {
            target = .neutral
            return
        }

        let nearest = nearestIcon(dx: v.dx, dy: v.dy)
        ensureLoaded(appIndex: nearest)

        if d > geometry.outerRadius {
            // Preview territory. Stick to the app we're already fanning if the
            // cursor is over its cards (the fan can spread wide).
            let sticky = currentAppIndex()
            if let s = sticky, hasWindows(s), let w = hitTestFan(point: p, appIndex: s) {
                target = .fanned(app: s, window: w)
                return
            }
            if hasWindows(nearest), let w = hitTestFan(point: p, appIndex: nearest) {
                target = .fanned(app: nearest, window: w)
                ensureThumbnails(appIndex: nearest)
                return
            }
            // Not over a card: stay engaged only while within the preview's
            // reach. Past that, go neutral so moving away (and clicking) dismisses
            // instead of forever selecting the angularly-aligned app.
            if hasWindows(nearest), d <= fanReach(appIndex: nearest) {
                target = .fanned(app: nearest, window: nil)
                ensureThumbnails(appIndex: nearest)
                return
            }
            if !hasWindows(nearest), d <= geometry.outerRadius + approachMargin {
                target = .icon(nearest)
                return
            }
            target = .neutral
            return
        }

        // Within the ring band → hovering the icon (show its stack).
        target = .icon(nearest)
        ensureThumbnails(appIndex: nearest)
    }

    /// A small margin past the ring within which an app with no previews still
    /// counts as hovered.
    private var approachMargin: CGFloat { 36 }

    /// Farthest radial distance (from center) at which the cursor still counts as
    /// engaging this app's previews — the outer corner of its fanned cards plus a
    /// margin. Beyond this, hover goes neutral.
    private func fanReach(appIndex: Int) -> CGFloat {
        // Outward extent of the cards (not the full diagonal) so the fan
        // collapses to neutral promptly once the cursor moves past the previews.
        let outwardExtent = geometry.previewSize.height / 2
        var maxR = geometry.outerRadius
        for card in previewLayout(appIndex: appIndex, fanned: true) {
            let dx = card.center.x - center.x
            let dy = card.center.y - center.y
            maxR = max(maxR, (dx * dx + dy * dy).squareRoot() + outwardExtent)
        }
        return maxR + 16
    }

    func commit() {
        guard interactive else { return } // ignore taps once closing
        onCommit?(target)
    }

    private func currentAppIndex() -> Int? {
        switch target {
        case .icon(let i): return i
        case .fanned(let app, _): return app
        case .neutral: return nil
        }
    }

    private func nearestIcon(dx: CGFloat, dy: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        let a = atan2(dy, dx)
        var best = 0
        var bestDelta = CGFloat.greatestFiniteMagnitude
        for i in 0..<count {
            let ia = geometry.angle(index: i, count: count)
            var delta = abs(a - ia).truncatingRemainder(dividingBy: 2 * .pi)
            if delta > .pi { delta = 2 * .pi - delta }
            if delta < bestDelta { bestDelta = delta; best = i }
        }
        return best
    }

    private func hasWindows(_ appIndex: Int) -> Bool {
        !windows(for: appIndex).isEmpty
    }

    // MARK: - Preview layout (shared by view + hit-testing)

    /// Anchor (front-card center), plus the outward/perp axes for an app's
    /// previews. Equal gap in every direction: offset by the icon's reach + gap +
    /// the card's reach ALONG the outward ray (a fixed radial offset overlaps the
    /// icon on the sides/diagonals because the card is a wide axis-aligned rect).
    func previewGeometry(appIndex: Int) -> (anchor: CGPoint, outward: CGVector, perp: CGVector)? {
        guard slots.indices.contains(appIndex), !windows(for: appIndex).isEmpty else { return nil }
        let outward = geometry.outwardDirection(index: appIndex, count: count)
        let perp = CGVector(dx: -outward.dy, dy: outward.dx)
        let iconC = geometry.iconCenter(index: appIndex, count: count,
                                        donutCenter: center, floated: true)
        let dx = max(abs(outward.dx), 0.0001), dy = max(abs(outward.dy), 0.0001)
        let iconReach = (geometry.iconSize / 2) / max(dx, dy)
        let cardReach = min((geometry.previewSize.width / 2) / dx,
                            (geometry.previewSize.height / 2) / dy)
        let anchorDist = iconReach + geometry.previewGap + cardReach
        let anchor = CGPoint(x: iconC.x + outward.dx * anchorDist,
                             y: iconC.y + outward.dy * anchorDist)
        return (anchor, outward, perp)
    }

    /// Center of the icon's floated bulge (where the glass connects to the pane).
    func bulgeCenter(appIndex: Int) -> CGPoint {
        geometry.iconCenter(index: appIndex, count: count, donutCenter: center, floated: true)
    }

    func previewLayout(appIndex: Int, fanned: Bool) -> [PreviewCardLayout] {
        let wins = windows(for: appIndex)
        guard let geo = previewGeometry(appIndex: appIndex) else { return [] }
        let anchor = geo.anchor, outward = geo.outward, perp = geo.perp
        let k = wins.count
        if !fanned {
            // Deck: front card crisp at the anchor, the rest peeking behind.
            return wins.enumerated().map { idx, w in
                let back = CGFloat(idx)
                let c = CGPoint(x: anchor.x + perp.dx * back * geometry.stackPeek
                                          - outward.dx * back * geometry.stackPeek * 0.6,
                                y: anchor.y + perp.dy * back * geometry.stackPeek
                                          - outward.dy * back * geometry.stackPeek * 0.6)
                // Front (top) card stays full size; the cards behind use the
                // configurable back-card scale (with a slight per-step taper for
                // depth), so only the peeking cards shrink — not the top one.
                let scale = idx == 0
                    ? 1.0
                    : max(0.4, CGFloat(appearance.stackBackScale) - CGFloat(idx - 1) * 0.04)
                return PreviewCardLayout(id: idx, window: w, center: c,
                                         rotation: .degrees(Double(idx) * appearance.stackRotation),
                                         scale: scale,
                                         z: Double(-idx))
            }
        } else {
            // Fan: cards spread along the axis perpendicular to "outward".
            let step = geometry.previewSize.width + geometry.fanSpacing
            return wins.enumerated().map { idx, w in
                let offset = (CGFloat(idx) - CGFloat(k - 1) / 2) * step
                let c = CGPoint(x: anchor.x + perp.dx * offset,
                                y: anchor.y + perp.dy * offset)
                return PreviewCardLayout(id: idx, window: w, center: c,
                                         rotation: .zero, scale: 1, z: Double(idx))
            }
        }
    }

    private func hitTestFan(point p: CGPoint, appIndex: Int) -> Int? {
        let layout = previewLayout(appIndex: appIndex, fanned: true)
        let half = CGSize(width: geometry.previewSize.width / 2,
                          height: geometry.previewSize.height / 2)
        // Topmost (last drawn) wins.
        for card in layout.reversed() {
            let r = CGRect(x: card.center.x - half.width, y: card.center.y - half.height,
                           width: geometry.previewSize.width, height: geometry.previewSize.height)
            if r.contains(p) { return card.id }
        }
        return nil
    }

    // MARK: - Lazy loading

    private func ensureLoaded(appIndex: Int) {
        guard slots.indices.contains(appIndex) else { return }
        let pid = slots[appIndex].id
        guard windowsByPID[pid] == nil, !loadingPIDs.contains(pid) else { return }
        loadingPIDs.insert(pid)
        let mySession = session
        let task = Task { [weak self] in
            let wins = await WindowEnumerator.windows(forPID: pid)
            guard let self, mySession == self.session else { return } // session still current?
            // Animate so the pane(s) fluidly grow out of the bulge once the
            // window list is known.
            withAnimation(self.appearance.spring) {
                self.windowsByPID[pid] = wins
                if let p = self.lastPoint { self.updateHover(point: p) }
            }
            self.loadingPIDs.remove(pid)
        }
        loadTasks.append(task)
    }

    private func ensureThumbnails(appIndex: Int) {
        let mySession = session
        for w in windows(for: appIndex) where w.id != 0 && thumbs[w.id] == nil {
            let wid = w.id
            let size = geometry.previewSize
            let scale = backingScale
            let task = Task { [weak self] in
                guard let self else { return }
                let image = await self.thumbnails.thumbnail(for: w, targetSize: size, scale: scale)
                guard mySession == self.session, let cg = image else { return } // drop stale
                self.thumbs[wid] = NSImage(cgImage: cg, size: NSSize(width: size.width, height: size.height))
            }
            loadTasks.append(task)
        }
    }
}
