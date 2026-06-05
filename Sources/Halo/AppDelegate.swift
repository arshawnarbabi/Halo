import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let permissions = Permissions()
    private let appList = AppList()
    private let eventTap = EventTap()
    private let appearance = Appearance.shared
    private var controller: SwitcherController?
    private var tapInstalled = false
    /// True when THIS process was spawned by our own relaunch (env flag), so we
    /// don't auto-relaunch again in a loop.
    private let spawnedByRelaunch = ProcessInfo.processInfo.environment["HALO_RELAUNCHED"] != nil
    private var relaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadUserSettings()   // restore persisted menu choices (ring / blur) first

        // Single-instance: the newest instance wins. Terminate any older copies
        // so a permission relaunch (or an accidental double-launch) can't leave
        // two menu-bar items, two editor windows, or two event taps both
        // swallowing ⌘⇥. (Skip for raw-binary runs with no bundle id.)
        terminateOtherInstances()

        AX.configureTimeout()
        setupStatusItem()

        let controller = SwitcherController(appList: appList, eventTap: eventTap, appearance: appearance)
        self.controller = controller
        appList.start()

        permissions.onChange = { [weak self] status in
            diag("perms changed: ax=\(status.accessibility) sr=\(status.screenRecording)")
            self?.updateStatusItem(status)
            self?.installTapIfReady(status)
        }
        // Retry the tap install on every poll tick (not just on state changes):
        // the first install attempt right after a grant can fail, and onChange
        // won't fire again while the status stays the same.
        permissions.onPoll = { [weak self] status in
            self?.installTapIfReady(status)
        }
        // Rebuild the menu when an update goes in/out of flight so the
        // "Check for Updates…" item reflects the busy state (the menu is cached).
        Updater.shared.onBusyChanged = { [weak self] _ in
            guard let self else { return }
            self.rebuildMenu(self.permissions.status)
        }
        // If a previous self-update failed mid-swap, the helper left a marker and
        // relaunched the old build — surface that instead of failing silently.
        reportFailedUpdateIfNeeded()

        permissions.refresh()
        diag("launch: ax=\(permissions.status.accessibility) sr=\(permissions.status.screenRecording) spawnedByRelaunch=\(spawnedByRelaunch)")
        permissions.requestMissing()
        permissions.startPolling()
        installTapIfReady(permissions.status)
    }

    // MARK: - Event tap install (only once core permissions are present)

    private func installTapIfReady(_ status: Permissions.Status) {
        guard !tapInstalled, status.coreReady else { return }
        if eventTap.start() {
            tapInstalled = true
            diag("event tap installed")
            permissions.stopPolling()
            updateStatusItem(status)
        } else {
            // AXIsProcessTrusted() reads true but the kernel still won't create
            // the tap — the classic "granted to a running process" case where the
            // trust state is cached and only a fresh process picks it up. Relaunch
            // once (guarded) so the new process starts trusted and the tap works.
            diag("event tap FAILED despite ax=true → relaunching to pick up grant")
            maybeRelaunchForGrant()
        }
    }

    // MARK: - Instance / relaunch management

    /// Terminate any other running instances of this app (newest wins). Keeps a
    /// permission relaunch clean and prevents duplicate menu items / event taps.
    private func terminateOtherInstances() {
        let me = NSRunningApplication.current
        guard let bundleID = me.bundleIdentifier else { return } // raw-binary run
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != me.processIdentifier
        }
        for app in others {
            diag("terminating older instance pid=\(app.processIdentifier)")
            if !app.terminate() { app.forceTerminate() }
        }
    }

    /// Auto-relaunch exactly once after a grant: only if we DIDN'T already spawn
    /// from a relaunch (loop guard) and we're a real .app bundle.
    private func maybeRelaunchForGrant() {
        guard !spawnedByRelaunch else {
            diag("already relaunched once; staying put (use the menu to retry)")
            updateStatusItem(permissions.status)
            return
        }
        relaunchApp()
    }

    /// Relaunch a fresh instance of our .app and quit this one. The new instance
    /// terminates us via terminateOtherInstances(), so the handoff is clean even
    /// before our completion handler runs.
    private func relaunchApp() {
        guard !relaunching else { return }
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else {
            diag("not an .app bundle (\(url.path)); cannot relaunch — launch via the bundle")
            return
        }
        relaunching = true
        diag("relaunching \(url.lastPathComponent)")
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.environment = ["HALO_RELAUNCHED": "1"]
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            let message = error?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let message {
                        diag("relaunch failed: \(message)")
                        self.relaunching = false
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    /// Recovery for a STALE grant (e.g. after a rebuild changed the code identity,
    /// or any time Settings shows "on" but the app isn't actually trusted): clear
    /// this app's Accessibility row and re-request, so a clean grant is recorded
    /// against the current identity. Does NOT relaunch immediately (that would
    /// land in a freshly-ungranted state); the poll loop installs/relaunches once
    /// the user re-grants.
    @objc private func resetAndRerequestAccessibility() {
        diag("tccutil reset Accessibility + re-request")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", "com.arshawn.halo"]
        try? p.run()
        p.waitUntilExit()
        tapInstalled = false
        permissions.requestMissing()  // re-adds the row + prompts
        permissions.refresh()
        permissions.startPolling()
        openAccessibilitySettings()
        updateStatusItem(permissions.status)
    }

    @objc private func relaunchFromMenu() {
        relaunchApp()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "circle.circle",
                                   accessibilityDescription: "Halo")
            button.image?.isTemplate = true
        }
        statusItem = item
        rebuildMenu(permissions.status)
    }

    private func updateStatusItem(_ status: Permissions.Status) {
        rebuildMenu(status)
    }

    private func rebuildMenu(_ status: Permissions.Status) {
        let menu = NSMenu()

        let version = Updater.currentVersion
        let headerTitle: String
        if tapInstalled {
            headerTitle = "Halo \(version) — active ✓"
        } else if status.accessibility {
            headerTitle = "Halo \(version) — granted, relaunch to activate"
        } else {
            headerTitle = "Halo \(version) — needs Accessibility"
        }
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(permItem("Accessibility (required)", granted: status.accessibility,
                              selector: #selector(openAccessibilitySettings)))
        menu.addItem(permItem("Screen Recording (previews)", granted: status.screenRecording,
                              selector: #selector(openScreenRecordingSettings)))

        // Recovery actions while the switcher isn't active yet.
        if !tapInstalled {
            menu.addItem(.separator())
            if status.accessibility {
                addItem(menu, "Relaunch to activate", #selector(relaunchFromMenu))
            }
            // For a stale grant (Settings shows "on" but the app isn't trusted —
            // common after a rebuild): clear and re-request from a clean state.
            addItem(menu, "Reset & re-request Accessibility…", #selector(resetAndRerequestAccessibility))
        }

        // Settings.
        menu.addItem(.separator())
        let ringItem = NSMenuItem(title: "Show ring", action: #selector(toggleRing), keyEquivalent: "")
        ringItem.target = self
        ringItem.state = appearance.ringHidden ? .off : .on
        menu.addItem(ringItem)

        let current = nearestBlurLevel
        let currentName = blurLevels.first { $0.value == current }?.name ?? "Custom"
        let blurItem = NSMenuItem(title: "Screen blur: \(currentName)", action: nil, keyEquivalent: "")
        let blurMenu = NSMenu()
        for (i, level) in blurLevels.enumerated() {
            let li = NSMenuItem(title: level.name, action: #selector(setBlurLevel(_:)), keyEquivalent: "")
            li.target = self
            li.tag = i
            li.state = (level.value == current) ? .on : .off
            blurMenu.addItem(li)
        }
        blurItem.submenu = blurMenu
        menu.addItem(blurItem)

        // Updates.
        menu.addItem(.separator())
        let busy = Updater.shared.isBusy
        let updateItem = NSMenuItem(title: busy ? "Updating…" : "Check for Updates…",
                                    action: busy ? nil : #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = !busy
        menu.addItem(updateItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Halo",
                                action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func checkForUpdates() {
        Updater.shared.checkForUpdates(userInitiated: true)
    }

    /// Surface a failed self-update (the swap helper restored the old build and
    /// left a marker), then clear it so it shows only once.
    private func reportFailedUpdateIfNeeded() {
        let marker = Updater.failureMarker
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        let detail = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.removeItem(at: marker)
        let alert = NSAlert()
        alert.messageText = "Update could not be installed"
        alert.informativeText = "The last update couldn't be applied, so Halo is still on the previous version. You can try again from the menu."
            + ((detail?.isEmpty == false) ? "\n\n\(detail!)" : "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Settings (menu-bar)

    /// Discrete, named screen-blur levels for the menu (no fiddly slider).
    private let blurLevels: [(name: String, value: Double)] = [
        ("No blur", 0), ("Subtle", 10), ("Medium", 25), ("Strong", 45), ("Maximum", 70),
    ]
    /// The level whose value is closest to the current blur (for the ✓).
    private var nearestBlurLevel: Double {
        blurLevels.min { abs($0.value - appearance.screenBlur) < abs($1.value - appearance.screenBlur) }?.value ?? 0
    }

    @objc private func toggleRing() {
        appearance.ringHidden.toggle()
        UserDefaults.standard.set(appearance.ringHidden, forKey: Self.prefRingHidden)
        updateStatusItem(permissions.status)
    }

    @objc private func setBlurLevel(_ sender: NSMenuItem) {
        guard blurLevels.indices.contains(sender.tag) else { return }
        appearance.screenBlur = blurLevels[sender.tag].value
        UserDefaults.standard.set(appearance.screenBlur, forKey: Self.prefScreenBlur)
        updateStatusItem(permissions.status)
    }

    // MARK: - Persistence (menu-bar settings survive relaunch)

    private static let prefRingHidden = "pref.ringHidden"
    private static let prefScreenBlur = "pref.screenBlur"

    /// Restore the user's menu choices over the hardcoded defaults. Only the two
    /// menu-bar settings persist; everything else uses the locked-in defaults.
    private func loadUserSettings() {
        let d = UserDefaults.standard
        if d.object(forKey: Self.prefRingHidden) != nil {
            appearance.ringHidden = d.bool(forKey: Self.prefRingHidden)
        }
        if d.object(forKey: Self.prefScreenBlur) != nil {
            appearance.screenBlur = d.double(forKey: Self.prefScreenBlur)
        }
        diag("loaded prefs: ringHidden=\(appearance.ringHidden) screenBlur=\(appearance.screenBlur)")
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ selector: Selector) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func permItem(_ name: String, granted: Bool, selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "\(granted ? "✓" : "✗")  \(name)",
                              action: granted ? nil : selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = !granted
        return item
    }

    @objc private func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
    @objc private func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    @objc private func quit() {
        eventTap.stop()
        appList.stop()
        permissions.stopPolling()
        NSApp.terminate(nil)
    }
}
