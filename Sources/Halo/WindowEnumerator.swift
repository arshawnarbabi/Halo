import AppKit
import ApplicationServices
import CoreGraphics

/// Enumerates the real, user-facing windows of an app via the Accessibility
/// API. Runs entirely on `axQueue`.
enum WindowEnumerator {

    /// Lists a single app's standard windows. Async so callers stay off the AX
    /// queue; the result is safe to hand to the main actor.
    static func windows(forPID pid: pid_t) async -> [WindowInfo] {
        await withCheckedContinuation { continuation in
            axQueue.async {
                continuation.resume(returning: enumerate(pid: pid))
            }
        }
    }

    private static func enumerate(pid: pid_t) -> [WindowInfo] {
        let appElement = AXUIElementCreateApplication(pid)
        guard let raw = AX.copyAttribute(appElement, kAXWindowsAttribute as String) as? [AXUIElement] else {
            return []
        }

        // kAXWindows can return duplicate entries (known macOS bug) — dedupe.
        var seen = Set<AXUIElement>()
        var result: [WindowInfo] = []
        for element in raw {
            guard seen.insert(element).inserted else { continue }
            guard isStandardWindow(element) else { continue }

            let title = AX.stringAttribute(element, kAXTitleAttribute as String) ?? ""
            let minimized = AX.boolAttribute(element, kAXMinimizedAttribute as String)
            let wid = AX.windowID(of: element)
            let frame = AX.frame(of: element)

            // Skip degenerate/zero-size windows that aren't minimized.
            if !minimized && (frame.width < 1 || frame.height < 1) { continue }

            result.append(WindowInfo(id: wid,
                                     axElement: element,
                                     pid: pid,
                                     title: title,
                                     isMinimized: minimized,
                                     frame: frame))
        }
        return result
    }

    /// Keep real document/app windows; drop sheets, popovers and system panels.
    private static func isStandardWindow(_ element: AXUIElement) -> Bool {
        guard let subrole = AX.stringAttribute(element, kAXSubroleAttribute as String) else {
            // No subrole — treat as a window only if it has a role of AXWindow.
            return AX.stringAttribute(element, kAXRoleAttribute as String) == (kAXWindowRole as String)
        }
        return subrole == (kAXStandardWindowSubrole as String)
            || subrole == (kAXDialogSubrole as String)
    }
}
