import AppKit
import SwiftUI

/// Owns the overlay panel and the show/hide session lifecycle. Wires the event
/// tap's toggle/dismiss into building, positioning and tearing down the donut.
@MainActor
final class SwitcherController {
    private let panel = OverlayPanel()
    private let model: SwitcherViewModel
    private let appList: AppList
    private let thumbnails = ThumbnailService()
    private let eventTap: EventTap
    private let appearance: Appearance

    private(set) var isShown = false

    init(appList: AppList, eventTap: EventTap, appearance: Appearance) {
        self.appList = appList
        self.eventTap = eventTap
        self.appearance = appearance
        self.model = SwitcherViewModel(thumbnails: thumbnails, appearance: appearance)

        let hosting = NSHostingView(rootView: DonutView(model: model))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        model.onCommit = { [weak self] target in self?.commit(target) }
        model.onDismiss = { [weak self] in self?.hide() }
        model.onBlurChanged = { [weak self] _ in self?.refreshBlur() }
        model.onMockCountChanged = { [weak self] in self?.refreshSlots() }

        eventTap.onToggle = { [weak self] in self?.toggle() }
        eventTap.onDismiss = { [weak self] in self?.hide() }
        eventTap.onCommandTap = { [weak self] in self?.repositionToCursor() }
    }

    /// Lone ⌘ tap while the donut is open → fluidly glide it to recenter on the
    /// current cursor (subtle overshoot via the reposition spring).
    func repositionToCursor() {
        guard isShown else { return }
        diag("recenter (lone cmd tap)")
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }

        // If the cursor jumped to another display, move the panel there first
        // (no animation across screens), then animate the center within it.
        if screen.frame != panel.frame {
            panel.setFrame(screen.frame, display: true)
        }
        let newCenter = CGPoint(x: mouse.x - screen.frame.minX,
                                y: screen.frame.maxY - mouse.y)
        // Suppress hover while the donut glides so a moving cursor can't float/push
        // icons (on the hover spring) out of step with the ring's glide (reposition
        // spring) — that desync made the icons and ring separate mid-move. The
        // token makes rapid ⌘ taps keep it suppressed until the LAST glide settles.
        model.repositioning = true
        repositionToken &+= 1
        let token = repositionToken
        withAnimation(appearance.repositionAnimation) {
            model.reposition(to: newCenter)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.repositionToken == token else { return }
            self.model.repositioning = false
        }
    }
    private var repositionToken = 0

    func toggle() {
        diag("toggle (isShown=\(isShown))")
        isShown ? hide() : show()
    }

    func show() {
        let mouse = NSEvent.mouseLocation // global, Cocoa bottom-left origin
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }
        show(at: mouse, on: screen)
    }

    private func show(at mouse: CGPoint, on screen: NSScreen) {
        guard !isShown else { return }

        panel.setFrame(screen.frame, display: true)

        // Cursor → SwiftUI view space (top-left origin within the panel).
        let center = CGPoint(x: mouse.x - screen.frame.minX,
                             y: screen.frame.maxY - mouse.y)

        let slots = buildSlots()
        guard !slots.isEmpty else { return }

        model.configure(slots: slots, center: center,
                        backingScale: screen.backingScaleFactor,
                        screenSize: screen.frame.size)
        model.openProgress = 0   // start compressed; sprung to 1 below

        Task { await thumbnails.refresh() }

        panel.orderFrontRegardless()
        setBlurRadius(0) // start unblurred; fade in with the spring below
        eventTap.setOverlayShown(true)
        isShown = true

        // Spring out of the compressed sphere into the ring, fading the backdrop
        // blur in along the SAME spring curve. Next runloop so the compressed
        // state paints first.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShown else { return }
            withAnimation(self.appearance.openAnimation) { self.model.openProgress = 1 }
            self.animateBlur(to: self.appearance.screenBlur,
                             response: self.appearance.openResponse, damping: self.appearance.openDamping)
        }
    }

    /// Real running apps (MRU) plus any test-only mock icons (reusing real icons)
    /// appended so the layout/push can be tried with more icons than are open.
    private func buildSlots() -> [AppSlot] {
        var slots = appList.switchableApps().map { AppSlot(app: $0) }
        let mockCount = Int(appearance.mockIconCount)
        if mockCount > 0 {
            let icons = slots.compactMap { $0.icon }
            for k in 0..<mockCount {
                let icon = icons.isEmpty ? nil : icons[k % icons.count]
                slots.append(AppSlot(mockID: pid_t(-(k + 1)), icon: icon, name: "Mock \(k + 1)"))
            }
        }
        return slots
    }

    /// Rebuild the ring in place (e.g. when the mock-icon count changes while
    /// previewing) without moving or re-showing the panel.
    func refreshSlots() {
        guard isShown else { return }
        let slots = buildSlots()
        guard !slots.isEmpty else { return }
        model.configure(slots: slots, center: model.center, backingScale: model.backingScale,
                        screenSize: model.screenSize)
    }

    // MARK: - Backdrop blur (WindowServer; not SwiftUI-animatable → stepped here)

    private var blurTimer: Timer?
    private var currentBlurRadius: Double = 0

    /// Immediately set the WindowServer blur radius behind the panel
    /// (CGSSetWindowBackgroundBlurRadius needs a non-zero panel bg alpha to apply).
    func setBlurRadius(_ radius: Double) {
        blurTimer?.invalidate(); blurTimer = nil
        applyBlur(radius)
    }

    private func applyBlur(_ radius: Double) {
        let clamped = max(0, min(120, radius))
        currentBlurRadius = clamped
        let r = Int32(clamped.rounded())
        panel.backgroundColor = r > 0 ? NSColor.white.withAlphaComponent(0.02) : .clear
        CGSSetWindowBackgroundBlurRadius(CGSMainConnectionID(), Int32(panel.windowNumber), r)
    }

    /// Re-apply the blur if the slider changes while open (keeps the live tuning
    /// responsive without a fade).
    private func refreshBlur() {
        guard blurTimer == nil else { return } // mid-fade: let it finish
        applyBlur(appearance.screenBlur)
    }

    /// Animate the blur to `target` following the SAME damped-spring curve as the
    /// open/close donut animation (same response/damping), so the blur fades in
    /// and out locked to the spring's actual motion — not a separate, slower timer.
    private func animateBlur(to target: Double, response: Double, damping: Double) {
        blurTimer?.invalidate(); blurTimer = nil
        let from = currentBlurRadius
        guard abs(target - from) > 0.4, response > 0.001 else { applyBlur(target); return }
        let wn = 2 * Double.pi / response
        let start = Date()
        // The timer fires on the main runloop, so the body is effectively
        // main-actor isolated — assert it so the @MainActor blur calls are legal.
        // Keep the Timer (`t`) in the outer nonisolated closure (it isn't Sendable
        // and can't be captured into the isolated body); stop it via `blurTimer`.
        blurTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            MainActor.assumeIsolated {
                let time = Date().timeIntervalSince(start)
                let x = Self.springStep(time, wn: wn, zeta: damping) // unit step 0→1 (may overshoot)
                self.applyBlur(from + (target - from) * x)
                if time > response * 3 {
                    self.applyBlur(target)
                    self.blurTimer?.invalidate(); self.blurTimer = nil
                }
            }
        }
    }

    /// Unit step response of a damped harmonic oscillator (ωn, ζ) — matches
    /// SwiftUI's `.spring(response:dampingFraction:)` (stiffness = ωn², ζ = damping).
    private static func springStep(_ t: Double, wn: Double, zeta: Double) -> Double {
        if zeta < 1 {
            let wd = wn * (1 - zeta * zeta).squareRoot()
            return 1 - exp(-zeta * wn * t) * (cos(wd * t) + (zeta * wn / wd) * sin(wd * t))
        } else if zeta == 1 {
            return 1 - exp(-wn * t) * (1 + wn * t)
        } else {
            let s = wn * (zeta * zeta - 1).squareRoot()
            let a = -zeta * wn + s, b = -zeta * wn - s
            return 1 - (b * exp(a * t) - a * exp(b * t)) / (b - a)
        }
    }

    func hide() {
        guard isShown else { return }
        // Fade the blur out along the close spring, in lockstep with the collapse.
        animateBlur(to: 0, response: appearance.closeResponse, damping: appearance.closeDamping)
        eventTap.setOverlayShown(false)
        isShown = false

        // Freeze interaction so a moving cursor can't re-select an icon (and spawn
        // a fresh bulge / window previews) on the still-visible closing panel.
        model.interactive = false
        // Spring back into the compressed sphere AND fade the whole donut out
        // together, so nothing (central sphere, hover bulge, previews, edge) is
        // left behind — it all disappears at once. Then remove the panel.
        withAnimation(appearance.closeAnimation) {
            model.openProgress = 0
            model.contentOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + appearance.closeDuration) { [weak self] in
            guard let self, !self.isShown else { return }
            self.panel.orderOut(nil)
        }
    }

    private func commit(_ target: HoverTarget) {
        diag("commit \(target)")
        switch target {
        case .neutral:
            hide()
        case .icon(let i):
            if let slot = slotAt(i) { WindowActivator.activateApp(pid: slot.id) }
            hide()
        case .fanned(let app, let windowIndex):
            // Only act when the cursor is on a specific window card. Clicking in
            // the fan gaps (no card under the cursor) is a click-off → dismiss,
            // not an app activation.
            let windows = model.windows(for: app)
            if let wi = windowIndex, windows.indices.contains(wi) {
                WindowActivator.raise(windows[wi])
            }
            hide()
        }
    }

    private func slotAt(_ index: Int) -> AppSlot? {
        model.slots.indices.contains(index) ? model.slots[index] : nil
    }
}
