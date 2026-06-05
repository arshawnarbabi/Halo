import ApplicationServices
import CoreGraphics

/// Shared serial queue for ALL Accessibility IPC. AX calls are synchronous
/// cross-process messages that can block for the full messaging timeout if the
/// target app is unresponsive — never run them on the main thread that drives
/// the overlay.
let axQueue = DispatchQueue(label: "com.arshawn.halo.ax", qos: .userInitiated)

enum AX {
    /// Lower the global AX messaging timeout so a hung target app can't stall
    /// the switcher for the default 6 seconds.
    static func configureTimeout() {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 1.0)
    }

    static func copyAttribute(_ element: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        return err == .success ? value : nil
    }

    static func stringAttribute(_ element: AXUIElement, _ attr: String) -> String? {
        copyAttribute(element, attr) as? String
    }

    static func boolAttribute(_ element: AXUIElement, _ attr: String) -> Bool {
        (copyAttribute(element, attr) as? Bool) ?? false
    }

    static func windowID(of element: AXUIElement) -> CGWindowID {
        var wid: CGWindowID = 0
        let err = _AXUIElementGetWindow(element, &wid)
        return err == .success ? wid : 0
    }

    static func frame(of element: AXUIElement) -> CGRect {
        var rect = CGRect.zero
        if let posValue = copyAttribute(element, kAXPositionAttribute as String),
           CFGetTypeID(posValue) == AXValueGetTypeID() {
            AXValueGetValue(posValue as! AXValue, .cgPoint, &rect.origin)
        }
        if let sizeValue = copyAttribute(element, kAXSizeAttribute as String),
           CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &rect.size)
        }
        return rect
    }
}
