import AppKit
import ApplicationServices
import CoreGraphics

/// A single switchable window of some app.
///
/// Carries the live `AXUIElement` so it can be raised later. AX element handles
/// are only ever *used* from `axQueue` (see AX.swift); this type is marked
/// `@unchecked Sendable` so it can be handed to the main actor for display while
/// the element itself is touched only on the AX queue.
struct WindowInfo: Identifiable, @unchecked Sendable {
    let id: CGWindowID          // 0 when the private bridge couldn't resolve one
    let axElement: AXUIElement
    let pid: pid_t
    let title: String
    let isMinimized: Bool
    let frame: CGRect           // screen coords (top-left origin, CG space)
}

/// One app slot in the ring, plus its windows.
@MainActor
struct AppSlot: Identifiable {
    let id: pid_t               // == processIdentifier (negative for mock icons)
    let app: NSRunningApplication?
    var icon: NSImage?
    var name: String
    var windows: [WindowInfo]   // filled in lazily on hover

    init(app: NSRunningApplication) {
        self.id = app.processIdentifier
        self.app = app
        let image = app.icon
        image?.size = NSSize(width: 128, height: 128) // pick the 256px retina rep
        self.icon = image
        self.name = app.localizedName ?? "App"
        self.windows = []
    }

    /// A fake icon for testing the ring layout / hover push with more icons.
    init(mockID: pid_t, icon: NSImage?, name: String) {
        self.id = mockID
        self.app = nil
        self.icon = icon
        self.name = name
        self.windows = []
    }
}
