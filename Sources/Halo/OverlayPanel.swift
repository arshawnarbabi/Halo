import AppKit

/// A transparent, non-activating overlay panel that floats above everything
/// (menu bar, Dock, full-screen apps) without stealing focus from the app the
/// user is switching away from.
final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   // .nonactivatingPanel MUST be set at init (toggling later
                   // doesn't reliably change activation behavior).
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false

        // Above the menu bar, Dock, and full-screen content. We use .screenSaver
        // (very high, but below the editor window so it can float on top and stay
        // clickable while tuning).
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                              .transient, .ignoresCycle, .canJoinAllApplications]
    }

    // We never need keyboard focus (Escape is handled in the event tap), so the
    // panel stays non-key and the previously-frontmost app remains frontmost.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
