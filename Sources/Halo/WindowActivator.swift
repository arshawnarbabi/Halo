import AppKit
import ApplicationServices
import CoreGraphics

/// Brings a target app/window to the front. Window-specific raising uses the
/// private SkyLight sequence (the only reliable cross-Space path), with a public
/// `NSRunningApplication.activate` + `AXRaise` fallback if the private symbols
/// ever stop working.
enum WindowActivator {

    /// Click an app icon → just bring that app's frontmost window forward.
    static func activateApp(pid: pid_t) {
        DispatchQueue.main.async {
            NSRunningApplication(processIdentifier: pid)?
                .activate(from: .current, options: [.activateAllWindows])
        }
    }

    /// Click a specific preview → raise THAT window.
    static func raise(_ window: WindowInfo) {
        axQueue.async {
            // Unminimize first; the raise is a no-op on a minimized window.
            if window.isMinimized {
                AXUIElementSetAttributeValue(window.axElement,
                                             kAXMinimizedAttribute as CFString,
                                             kCFBooleanFalse)
            }

            // Try the private SkyLight focus path; only mark it used if every
            // step actually succeeds, so a failure falls through to the public
            // fallback instead of being silently dropped.
            var usedPrivatePath = false
            if window.id != 0 {
                var psn = ProcessSerialNumber()
                if GetProcessForPID(window.pid, &psn) == noErr,
                   _SLPSSetFrontProcessWithOptions(&psn, window.id, kSLPSUserGenerated) == .success {
                    makeKeyWindow(psn: &psn, wid: window.id)
                    usedPrivatePath = true
                }
            }

            // Raise within the app's window stack regardless of path.
            let raiseErr = AXUIElementPerformAction(window.axElement, kAXRaiseAction as CFString)

            // Fall back to public activation if the private path wasn't used OR
            // the AX raise failed (e.g. a stale window element). When the
            // private path already fronted the app, just nudge it (no
            // .activateAllWindows, which would pull every window forward).
            if !usedPrivatePath || raiseErr != .success {
                let options: NSApplication.ActivationOptions = usedPrivatePath ? [] : [.activateAllWindows]
                DispatchQueue.main.async {
                    NSRunningApplication(processIdentifier: window.pid)?
                        .activate(from: .current, options: options)
                }
            }
        }
    }

    /// Poke SkyLight so the given window becomes key within its process. Byte
    /// layout ported from Hammerspoon / Halo; two records (types 0x01, 0x02).
    private static func makeKeyWindow(psn: inout ProcessSerialNumber, wid: CGWindowID) {
        func record(eventType: UInt8) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 0xf8)
            bytes[0x04] = 0xF8
            bytes[0x08] = eventType
            bytes[0x3a] = 0x10
            var w = wid
            withUnsafeBytes(of: &w) { src in
                for i in 0..<MemoryLayout<CGWindowID>.size { bytes[0x3c + i] = src[i] }
            }
            for i in 0..<0x10 { bytes[0x20 + i] = 0xFF }
            return bytes
        }
        var first = record(eventType: 0x01)
        var second = record(eventType: 0x02)
        let e1 = SLPSPostEventRecordTo(&psn, &first)
        let e2 = SLPSPostEventRecordTo(&psn, &second)
        if e1 != .success || e2 != .success {
            // Best-effort: AXRaise + the public fallback still bring the window
            // forward; log so a future symbol/behavior change is diagnosable.
            NSLog("[Halo] SkyLight makeKeyWindow returned \(e1.rawValue)/\(e2.rawValue)")
        }
    }
}
