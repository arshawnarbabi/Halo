import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Captures live per-window thumbnails via ScreenCaptureKit, lazily and cached.
///
/// `SCShareableContent` is fetched ONCE per donut-open (it's a slow cross-process
/// call); individual window screenshots are taken on hover. Minimized / hidden /
/// other-Space windows can't produce fresh pixels — callers fall back to the
/// app icon for those.
actor ThumbnailService {
    private var shareable: SCShareableContent?
    private var cache: [CGWindowID: CGImage] = [:]

    /// Whether Screen Recording is granted; previews are skipped if not.
    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Call once when the donut opens. Refreshes the window snapshot and clears
    /// the per-session thumbnail cache so previews reflect current content.
    func refresh() async {
        cache.removeAll()
        shareable = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    }

    private func scWindow(for wid: CGWindowID) -> SCWindow? {
        shareable?.windows.first { $0.windowID == wid }
    }

    /// Returns a thumbnail for the window, or nil if it can't be captured
    /// (no permission, minimized, off-screen, or unmatched). Results cached by
    /// windowID for the session.
    func thumbnail(for window: WindowInfo,
                   targetSize: CGSize,
                   scale: CGFloat) async -> CGImage? {
        if let cached = cache[window.id] { return cached }
        guard hasPermission,
              window.id != 0,
              !window.isMinimized,
              let scWindow = scWindow(for: window.id) else { return nil }

        let config = SCStreamConfiguration()
        config.width = max(1, Int(targetSize.width * scale))
        config.height = max(1, Int(targetSize.height * scale))
        config.showsCursor = false
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.captureResolution = .nominal
        config.ignoreShadowsSingleWindow = true

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config) else {
            return nil
        }
        cache[window.id] = image
        return image
    }

    /// Captures the whole display behind the toolbar (excluding our own windows)
    /// so it can be blurred as the toolbar's backdrop with a controllable radius.
    func captureBackdrop(displayID: CGDirectDisplayID, pixelSize: CGSize) async -> CGImage? {
        guard hasPermission else { return nil }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let mine = content.windows.filter { $0.owningApplication?.processID == myPID }
        let filter = SCContentFilter(display: display, excludingWindows: mine)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(pixelSize.width))
        config.height = max(1, Int(pixelSize.height))
        config.showsCursor = false
        config.captureResolution = .nominal
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
