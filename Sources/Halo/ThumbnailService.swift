import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Captures live per-window thumbnails via ScreenCaptureKit, lazily and cached.
///
/// `SCShareableContent` is fetched ONCE per donut-open (it's a slow cross-process
/// call); individual window screenshots are taken on hover. Windows SCK can't
/// screenshot — fullscreen apps on their own Space, other-Space and minimized
/// windows (`SCScreenshotManager` fails with -3811 for those) — fall back to the
/// private SkyLight hardware capture (`CGSHWCaptureWindowList`), which renders a
/// window regardless of Space. Callers fall back to the app icon only when both
/// paths fail.
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
    /// (no permission, no window id, or both capture paths failed). Results
    /// cached by windowID for the session.
    func thumbnail(for window: WindowInfo,
                   targetSize: CGSize,
                   scale: CGFloat) async -> CGImage? {
        if let cached = cache[window.id] { return cached }
        guard hasPermission, window.id != 0 else { return nil }

        // Primary: ScreenCaptureKit. Only renders windows on the ACTIVE Space —
        // fullscreen / other-Space / minimized windows make captureImage throw
        // (SCStreamError -3811), so those skip straight to the fallback.
        if !window.isMinimized, let scWindow = scWindow(for: window.id) {
            let config = SCStreamConfiguration()
            config.width = max(1, Int(targetSize.width * scale))
            config.height = max(1, Int(targetSize.height * scale))
            config.showsCursor = false
            config.scalesToFit = true
            config.preservesAspectRatio = true
            config.captureResolution = .nominal
            config.ignoreShadowsSingleWindow = true

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            if let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config) {
                cache[window.id] = image
                return image
            }
        }

        // Fallback: private SkyLight hardware capture reaches everything SCK
        // can't — fullscreen apps on their own Space, other-Space windows,
        // minimized windows (last-rendered content). It returns native-size
        // pixels, so downscale to thumbnail size before caching: a 5K fullscreen
        // window must not pin megabytes per preview for the whole session.
        var wid = window.id
        let captured = CGSHWCaptureWindowList(
            CGSMainConnectionID(), &wid, 1,
            kCGSCaptureIgnoreGlobalClipShape | kCGSWindowCaptureNominalResolution
        )?.takeRetainedValue() as? [CGImage]
        guard let raw = captured?.first else { return nil }
        let image = downscale(raw, toFit: CGSize(width: max(1, targetSize.width * scale),
                                                 height: max(1, targetSize.height * scale)))
        cache[window.id] = image
        return image
    }

    /// Aspect-fit downscale via CoreGraphics; returns the original if it
    /// already fits (or if the context can't be built — best-effort).
    private func downscale(_ image: CGImage, toFit target: CGSize) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return image }
        let f = min(target.width / w, target.height / h)
        guard f < 1 else { return image }
        let space = image.colorSpace?.model == .rgb
            ? image.colorSpace! : CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: max(1, Int(w * f)), height: max(1, Int(h * f)),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(ctx.width), height: CGFloat(ctx.height)))
        return ctx.makeImage() ?? image
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
