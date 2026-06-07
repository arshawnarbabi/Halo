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
        let raw = AX.copyAttribute(appElement, kAXWindowsAttribute as String) as? [AXUIElement] ?? []

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

        // kAXWindows only reports windows on the ACTIVE Space (plus minimized
        // ones) — an app fullscreen on its own Space enumerates ZERO AX windows.
        // Discover those through CGWindowList instead.
        result.append(contentsOf: otherSpaceWindows(pid: pid,
                                                    excluding: Set(result.map(\.id))))
        return result
    }

    /// Other-Space windows (fullscreen apps on their own Space, windows on
    /// other desktops) that AX can't see. CGWindowList lists those — along
    /// with plenty of junk, filtered two ways (both verified on macOS 26):
    /// only windows actually placed on a Space survive (phantom never-shown
    /// windows and minimized ones belong to none — minimized windows come from
    /// AX above), and a size floor drops fullscreen accessory strips (tab-bar /
    /// toolbar reveal windows share the fullscreen Space but are ≤ ~123 pt
    /// tall). These carry no AXUIElement; the SLPS raise path and the SkyLight
    /// capture fallback both work from the bare CGWindowID.
    private static let minOtherSpaceDimension: CGFloat = 150

    private static func otherSpaceWindows(pid: pid_t,
                                          excluding axWIDs: Set<CGWindowID>) -> [WindowInfo] {
        guard let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var result: [WindowInfo] = []
        for entry in info {
            guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowAlpha as String] as? CGFloat ?? 0) > 0,
                  let wid = entry[kCGWindowNumber as String] as? CGWindowID,
                  !axWIDs.contains(wid),
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"],
                  w >= minOtherSpaceDimension, h >= minOtherSpaceDimension
            else { continue }
            let spaces = CGSCopySpacesForWindows(CGSMainConnectionID(),
                                                 kCGSAllSpacesMask,
                                                 [wid] as CFArray)?
                .takeRetainedValue() as? [UInt64] ?? []
            guard !spaces.isEmpty else { continue }
            result.append(WindowInfo(id: wid,
                                     axElement: nil,
                                     pid: pid,
                                     title: (entry[kCGWindowName as String] as? String) ?? "",
                                     isMinimized: false,
                                     frame: CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                                                   width: w, height: h)))
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
