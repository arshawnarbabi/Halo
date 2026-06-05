import AppKit
import ApplicationServices
import CoreGraphics

/// Tracks the TCC grants the switcher needs and drives the prompt/poll flow.
///
/// Only **Accessibility** is required: it lets us both receive AND swallow the
/// Cmd+Tab key events (a `.defaultTap` keyboard event tap works with
/// Accessibility alone — Input Monitoring is NOT needed and is intentionally not
/// requested) and drive AXRaise. **Screen Recording** is optional: without it the
/// previews fall back to app-icon cards.
///
/// There's no clean "granted" notification, so the pattern is: prompt once, then
/// poll on a timer until the state flips.
@MainActor
final class Permissions {
    struct Status: Equatable {
        var accessibility: Bool   // swallowing event tap + read windows + AXRaise
        var screenRecording: Bool // ScreenCaptureKit window previews (optional)

        /// Accessibility alone is enough to run the switcher.
        var coreReady: Bool { accessibility }
        var allReady: Bool { accessibility && screenRecording }
    }

    private(set) var status = Status(accessibility: false, screenRecording: false)

    /// Fired only when the Status value CHANGES.
    var onChange: ((Status) -> Void)?
    /// Fired on EVERY poll tick (even when nothing changed) so the owner can
    /// re-attempt work that may have failed once — notably installing the event
    /// tap, which can fail the first time accessibility is granted to a running
    /// process and would otherwise never be retried (onChange won't re-fire when
    /// the status is unchanged).
    var onPoll: ((Status) -> Void)?

    private var pollTimer: Timer?

    func refresh() {
        let new = Status(
            accessibility: AXIsProcessTrusted(),
            screenRecording: CGPreflightScreenCaptureAccess()
        )
        if new != status {
            status = new
            onChange?(new)
        }
    }

    /// Prompt for whatever is still missing. Each request shows the system
    /// dialog (or deep-links to Settings) at most once per identity.
    func requestMissing() {
        refresh()
        if !status.accessibility {
            // Value of kAXTrustedCheckOptionPrompt; referencing the global var
            // directly isn't concurrency-safe under Swift 6.
            let key = "AXTrustedCheckOptionPrompt"
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        if !status.screenRecording {
            // Registers the app in the Screen Recording list and prompts once.
            _ = CGRequestScreenCaptureAccess()
        }
    }

    /// Poll the permission state, calling `onChange` as things flip and `onPoll`
    /// every tick. The owner is responsible for calling `stopPolling()` once the
    /// event tap is actually installed (a granted-but-not-yet-installed state must
    /// keep polling so the install can be retried).
    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()          // fires onChange only on a real change
                self.onPoll?(self.status) // always — lets the owner retry install
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
