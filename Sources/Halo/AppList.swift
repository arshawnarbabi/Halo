import AppKit

/// Pulls the pid out of an NSWorkspace app notification without sending the
/// (non-Sendable) Notification across the actor boundary.
private func activatedAppPID(_ note: Notification, requireRegular: Bool = false) -> pid_t? {
    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
        return nil
    }
    if requireRegular && app.activationPolicy != .regular { return nil }
    return app.processIdentifier
}

/// Maintains the ordered list of switchable apps in Cmd+Tab-style
/// most-recently-used order. There is no public API for the system MRU, so we
/// build our own from NSWorkspace activation notifications.
@MainActor
final class AppList {
    /// pids in MRU order (most recent first). Excludes our own process.
    private(set) var mru: [pid_t] = []

    private let selfPID = ProcessInfo.processInfo.processIdentifier
    private var observers: [NSObjectProtocol] = []

    func start() {
        seed()
        let nc = NSWorkspace.shared.notificationCenter // NOT NotificationCenter.default
        // Extract Sendable values (pid / policy) inside the block via a
        // nonisolated free function, then hop to the main actor with just those
        // — never send the Notification itself across the boundary.
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let pid = activatedAppPID(note) else { return }
            MainActor.assumeIsolated { self?.moveToFront(pid) }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let pid = activatedAppPID(note) else { return }
            MainActor.assumeIsolated { self?.remove(pid) }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let pid = activatedAppPID(note, requireRegular: true) else { return }
            MainActor.assumeIsolated { self?.append(pid) }
        })
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.forEach { nc.removeObserver($0) }
        observers.removeAll()
    }

    /// The apps to show in the ring, in MRU order, resolved to live objects.
    func switchableApps() -> [NSRunningApplication] {
        let byPID = Dictionary(uniqueKeysWithValues:
            regularApps().map { ($0.processIdentifier, $0) })
        // MRU first (those still running), then any regular app we haven't seen.
        var ordered: [NSRunningApplication] = []
        var seen = Set<pid_t>()
        for pid in mru {
            if let app = byPID[pid] {
                ordered.append(app)
                seen.insert(pid)
            }
        }
        for app in regularApps() where !seen.contains(app.processIdentifier) {
            ordered.append(app)
        }
        return ordered
    }

    // MARK: - Internals

    private func regularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != selfPID
        }
    }

    private func seed() {
        var order: [pid_t] = []
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != selfPID {
            order.append(front.processIdentifier)
        }
        for app in regularApps() where !order.contains(app.processIdentifier) {
            order.append(app.processIdentifier)
        }
        mru = order
    }

    private func moveToFront(_ pid: pid_t) {
        guard pid != selfPID else { return } // our overlay showing shouldn't reorder
        mru.removeAll { $0 == pid }
        mru.insert(pid, at: 0)
    }

    private func remove(_ pid: pid_t) {
        mru.removeAll { $0 == pid }
    }

    private func append(_ pid: pid_t) {
        if !mru.contains(pid) { mru.append(pid) }
    }
}
