#!/bin/bash
# Build Halo with SwiftPM and assemble a signed .app bundle.
#
#   ./Scripts/build.sh           release build, assemble, codesign, open
#   ./Scripts/build.sh debug     debug build (faster), assemble, codesign, open
#   ./Scripts/build.sh release nolaunch   build+sign but don't `open`
#
# Signs with the Apple Development cert so the TCC designated requirement is
# identifier+leaf-cert based and Accessibility / Screen Recording / Input
# Monitoring grants PERSIST across rebuilds (ad-hoc `-` would churn the cdhash
# and force a re-grant every build).
set -euo pipefail

CONFIG="${1:-release}"
LAUNCH="${2:-launch}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.arshawn.halo"
APP_NAME="Halo"
EXEC_NAME="Halo"

# Signing identity. By default, auto-pick the first "Apple Development" identity
# in the keychain; override with HALO_SIGN_ID=<sha1-or-name>. A cert-leaf
# requirement (not ad-hoc) is what lets TCC grants persist across rebuilds —
# ad-hoc would churn the cdhash and silently invalidate Accessibility every build.
SIGN_ID="${HALO_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
	| awk '/Apple Development/{print $2; exit}')}"
if [[ -z "$SIGN_ID" ]]; then
	echo "ERROR: no 'Apple Development' signing identity found in the keychain." >&2
	echo "       Create one in Xcode (Settings ▸ Accounts), or set HALO_SIGN_ID to a" >&2
	echo "       valid 'security find-identity -v -p codesigning' identity." >&2
	echo "       Do NOT ad-hoc sign (codesign --sign -): TCC pins ad-hoc grants to the" >&2
	echo "       cdhash, which changes every build, so Accessibility breaks." >&2
	exit 1
fi

SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
export HALO_SDK_PATH="$SDK_PATH"

# Preflight: refuse to build unless the chosen identity is actually in the keychain.
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
	echo "ERROR: signing identity '$SIGN_ID' not found in the keychain." >&2
	echo "       Set HALO_SIGN_ID to a valid 'security find-identity -v -p codesigning' id." >&2
	exit 1
fi

echo "==> swift build ($CONFIG)  SDK=$SDK_PATH"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/$EXEC_NAME"
if [[ ! -x "$BIN" ]]; then
	echo "build failed: $BIN not found" >&2
	exit 1
fi

APP="$ROOT/build/$APP_NAME.app"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"
cp "$ROOT/Scripts/Info.plist.template" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
	cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
	/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

echo "==> codesign ($SIGN_ID)"
codesign --force --options runtime \
	--sign "$SIGN_ID" \
	--identifier "$BUNDLE_ID" \
	"$APP"
codesign --verify --verbose=2 "$APP"

# Locally built apps shouldn't be quarantined, but strip it defensively: a
# quarantined .app can be App-Translocated to a random read-only path at launch,
# which changes Bundle.main.bundleURL and breaks TCC identity / relaunch.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# Guard against a silent regression to ad-hoc: the designated requirement must be
# certificate-leaf based (stable across rebuilds), NOT a bare cdhash pin.
if codesign -d --requirements - "$APP" 2>&1 | grep -q 'cdhash H'; then
	echo "ERROR: signature is cdhash-pinned (ad-hoc) — the Accessibility grant will" >&2
	echo "       go stale on the next rebuild. Re-sign with the Apple Development cert." >&2
	exit 1
fi

echo "==> built $APP"
echo "==> designated requirement (stable, no cdhash):"
codesign -d --requirements - "$APP" 2>&1 | sed 's/^/    /'
if [[ "$LAUNCH" == "launch" ]]; then
	# kill a previous instance so the new binary owns the event tap / status item
	pkill -x "$EXEC_NAME" 2>/dev/null || true
	sleep 0.3
	open "$APP"
	echo "==> launched"
fi
