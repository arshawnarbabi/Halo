// swift-tools-version:6.2
// NOTE: tools-version MUST be >= 6.2 — `.macOS(.v26)` is unavailable below it
// (verified: 6.0 errors "'v26' was introduced in PackageDescription 6.2").
import PackageDescription
import Foundation

// SkyLight is a private framework; its TBD lives in the SDK's PrivateFrameworks
// dir. We resolve the SDK path at manifest-eval time so the package stays
// portable across machines. `_AXUIElementGetWindow` needs no flag (HIServices),
// but the SLPS focus symbols only link with an explicit `-framework SkyLight`.
let sdkPath = ProcessInfo.processInfo.environment["HALO_SDK_PATH"]
    ?? "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
let privateFrameworks = sdkPath + "/System/Library/PrivateFrameworks"

let package = Package(
    name: "Halo",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Halo",
            path: "Sources/Halo",
            linkerSettings: [
                .unsafeFlags(["-F", privateFrameworks, "-framework", "SkyLight"])
            ]
        )
    ]
)
