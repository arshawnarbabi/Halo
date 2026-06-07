import ApplicationServices
import CoreGraphics

// Private/undocumented symbols, declared via @_silgen_name so the dynamic
// linker resolves them directly (zero overhead, no dlsym). Verified to compile
// AND link against the macOS 26.4 SDK during research.
//
//   - _AXUIElementGetWindow            : resolves from HIServices, NO link flag.
//   - GetProcessForPID / SLPS symbols  : require `-framework SkyLight`
//                                        (see Package.swift linkerSettings).
//
// Every caller MUST treat these as best-effort: check the return code and fall
// back to public APIs (see WindowActivator) so a future macOS that removes or
// changes a symbol degrades gracefully instead of crashing.

/// Bridges an AX window element to its CoreGraphics window id (== SCWindow.windowID).
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement,
                          _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Obtains a ProcessSerialNumber from a pid (legacy Carbon symbol, still live).
@_silgen_name("GetProcessForPID")
@discardableResult
func GetProcessForPID(_ pid: pid_t,
                     _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

/// Sets the front process and, with a window id, the target window (SkyLight).
@_silgen_name("_SLPSSetFrontProcessWithOptions")
@discardableResult
func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>,
                                    _ windowID: CGWindowID,
                                    _ mode: UInt32) -> CGError

/// Posts a low-level event record to a process (used for the makeKeyWindow poke).
@_silgen_name("SLPSPostEventRecordTo")
@discardableResult
func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>,
                          _ bytes: UnsafeMutablePointer<UInt8>) -> CGError

// Mode constant for _SLPSSetFrontProcessWithOptions (per Hammerspoon/Halo).
let kSLPSUserGenerated: UInt32 = 0x200

/// CoreGraphics Services connection for the current process.
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

/// WindowServer-side hardware window capture (SkyLight). Unlike SCK's
/// desktop-independent screenshot — which fails with SCStreamError -3811 for any
/// window that isn't on the ACTIVE Space — this renders a window regardless of
/// Space: fullscreen apps on their own Space, other-Space windows, even
/// minimized ones (last-rendered content). Returns a CFArray of CGImage (one per
/// requested id; empty on failure). Requires Screen Recording. Same approach as
/// AltTab / yabai.
@_silgen_name("CGSHWCaptureWindowList")
func CGSHWCaptureWindowList(_ connection: Int32,
                            _ windowList: UnsafeMutablePointer<CGWindowID>,
                            _ windowCount: UInt32,
                            _ options: UInt32) -> Unmanaged<CFArray>?

// CGSHWCaptureWindowList options (per AltTab/Hammerspoon research).
let kCGSCaptureIgnoreGlobalClipShape: UInt32 = 1 << 11
let kCGSWindowCaptureNominalResolution: UInt32 = 1 << 9

/// Maps windows → the Spaces they're placed on (SkyLight). The key
/// discriminator when discovering other-Space windows via CGWindowList: a
/// window on NO Space is a phantom (created but never ordered in — every app
/// has a few) or minimized, while real windows — including fullscreen apps on
/// their own Space — report at least one Space id. Verified on macOS 26.
@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ connection: Int32,
                             _ mask: Int32,
                             _ windowIDs: CFArray) -> Unmanaged<CFArray>?

/// CGSCopySpacesForWindows mask: current | other | user Spaces.
let kCGSAllSpacesMask: Int32 = 7

/// The WindowServer-side, live, controllable behind-window blur (radius in
/// points; 0 disables). The only verified way to blur the desktop behind a
/// window with an adjustable radius on macOS — used by Terminal/iTerm2/WezTerm.
/// Requires the window to be non-opaque with a NON-ZERO background alpha.
@_silgen_name("CGSSetWindowBackgroundBlurRadius")
@discardableResult
func CGSSetWindowBackgroundBlurRadius(_ connection: Int32, _ window: Int32, _ radius: Int32) -> Int32
