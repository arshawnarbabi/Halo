import AppKit
import CoreGraphics
import os

/// Intercepts ⌘⇥ (and ⌘⇧⇥) at the earliest tap point and swallows it so the
/// native macOS switcher never appears, toggling our overlay instead. Escape is
/// swallowed only while the overlay is shown.
///
/// Runs on a dedicated background thread with its own CFRunLoop. The C callback
/// is kept trivial (a heavy callback trips `tapDisabledByTimeout`): it decides
/// swallow-or-pass and hops any real work to the main queue.
final class EventTap: @unchecked Sendable {
    // Set once before start(); invoked on the MAIN queue.
    var onToggle: (@MainActor () -> Void)?
    var onDismiss: (@MainActor () -> Void)?
    /// A lone ⌘ tap (no other key/modifier) while the overlay is shown.
    var onCommandTap: (@MainActor () -> Void)?

    private let kVKTab: Int64 = 48
    private let kVKEscape: Int64 = 53

    // Lone-⌘-tap detection. Accessed only on the tap thread.
    private var cmdWasDown = false
    private var cmdTapValid = false

    // Read from the tap thread to gate Escape swallowing; written from main.
    private let overlayShown = OSAllocatedUnfairLock(initialState: false)

    // `tap` is touched from the tap thread (start/handle) AND the main thread
    // (watchdog/stop), so it's lock-protected. Returning the value under lock
    // also lets ARC retain the CFMachPort for the caller's scope, so a
    // concurrent stop() setting it nil can't free it mid-use. (NSLock rather
    // than OSAllocatedUnfairLock since CFMachPort isn't Sendable.)
    private let tapLock = NSLock()
    nonisolated(unsafe) private var _tap: CFMachPort?
    private var tap: CFMachPort? {
        get { tapLock.lock(); defer { tapLock.unlock() }; return _tap }
        set { tapLock.lock(); defer { tapLock.unlock() }; _tap = newValue }
    }
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?
    private var watchdog: Timer?

    func setOverlayShown(_ shown: Bool) {
        overlayShown.withLock { $0 = shown }
    }
    private func isOverlayShown() -> Bool {
        overlayShown.withLock { $0 }
    }

    /// Installs the tap on a dedicated thread. Returns false if creation fails
    /// (almost always missing Accessibility/Input-Monitoring permission).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let ready = DispatchSemaphore(value: 0)

        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let mask = CGEventMask(
                (1 << CGEventType.keyDown.rawValue) |
                (1 << CGEventType.flagsChanged.rawValue))
            let userInfo = Unmanaged.passUnretained(self).toOpaque()
            guard let port = CGEvent.tapCreate(
                tap: .cghidEventTap,           // earliest point; beats the Game Overlay
                place: .headInsertEventTap,
                options: .defaultTap,          // active tap: required to swallow
                eventsOfInterest: mask,
                callback: eventTapCallback,
                userInfo: userInfo
            ) else {
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let rl = CFRunLoopGetCurrent()
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)

            self.tap = port
            self.runLoopSource = source
            self.threadRunLoop = rl
            ready.signal()
            CFRunLoopRun() // blocks this thread, dispatching the callback
        }
        thread.name = "com.arshawn.halo.eventtap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()

        ready.wait() // happens-before: tap (if any) is now visible to us
        let installed = (tap != nil)
        if installed { startWatchdog() }
        return installed
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let rl = threadRunLoop, let source = runLoopSource {
            CFRunLoopRemoveSource(rl, source, .commonModes)
            CFRunLoopStop(rl)
        }
        tap = nil
        runLoopSource = nil
        threadRunLoop = nil
        // CFRunLoopStop above makes CFRunLoopRun() return, so the thread's
        // closure completes and the thread exits on its own; we just drop our
        // reference. (stop() is only called at quit, so this is terminal anyway.)
        thread = nil
    }

    /// The tap can be silently disabled by the system (slow callback, user
    /// input, or a post-resign identity re-evaluation). Re-arm it periodically;
    /// a non-nil tap is not necessarily a healthy tap.
    private func startWatchdog() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.watchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                guard let self, let tap = self.tap else { return }
                if !CGEvent.tapIsEnabled(tap: tap) {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
        }
    }

    // MARK: - Decisions (called from the tap thread)

    enum Decision { case swallow, pass }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Decision {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return .pass
        }

        // Track the modifier stream to detect a LONE ⌘ tap (press+release with
        // no other key or modifier) — used to recenter the open donut.
        if type == .flagsChanged {
            handleFlagsChanged(event)
            return .pass // never swallow modifier events
        }

        guard type == .keyDown else { return .pass }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Any key pressed while ⌘ is held means ⌘ was combined, not a lone tap.
        cmdTapValid = false

        // Our chord: Tab while Command is held (with or without Shift).
        if keyCode == kVKTab && flags.contains(.maskCommand) {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat {
                let cb = onToggle
                DispatchQueue.main.async { MainActor.assumeIsolated { cb?() } }
            }
            return .swallow // swallow repeats too, so nothing leaks to the system
        }

        // Escape dismisses — but only while we're showing, else apps need it.
        if keyCode == kVKEscape && isOverlayShown() {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat {
                let cb = onDismiss
                DispatchQueue.main.async { MainActor.assumeIsolated { cb?() } }
            }
            return .swallow // swallow repeats too while shown
        }

        return .pass
    }

    /// Detect a clean ⌘-only tap: ⌘ goes down with no other modifier, then ⌘
    /// goes up with no other key pressed in between.
    private func handleFlagsChanged(_ event: CGEvent) {
        let flags = event.flags
        let cmdNow = flags.contains(.maskCommand)
        let otherMods = flags.contains(.maskShift)
            || flags.contains(.maskAlternate)
            || flags.contains(.maskControl)

        if cmdNow && !cmdWasDown {
            cmdWasDown = true
            cmdTapValid = !otherMods           // clean only if ⌘ pressed alone
        } else if !cmdNow && cmdWasDown {
            cmdWasDown = false
            let valid = cmdTapValid
            cmdTapValid = false
            if valid && isOverlayShown() {     // lone ⌘ tap while donut is open
                let cb = onCommandTap
                DispatchQueue.main.async { MainActor.assumeIsolated { cb?() } }
            }
        } else if cmdNow && otherMods {
            cmdTapValid = false                // another modifier joined ⌘
        }
    }
}

/// Free C callback. Reconstructs the EventTap from userInfo and delegates.
private func eventTapCallback(proxy: CGEventTapProxy,
                              type: CGEventType,
                              event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
    switch tap.handle(type: type, event: event) {
    case .swallow: return nil
    case .pass:    return Unmanaged.passUnretained(event)
    }
}
