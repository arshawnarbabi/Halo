import AppKit

// Halo is a menu-bar agent. We bootstrap NSApplication manually from a
// SwiftPM executable (no Xcode project, no SwiftUI App scene) because we need
// full control over a custom event tap and a non-activating overlay panel —
// MenuBarExtra has no public hook to drive either.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // runtime LSUIElement: no Dock icon, no menu bar
app.run()
