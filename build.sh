#!/bin/bash
#
# Builds DynamicIsland into a launchable .app bundle.
#
# SwiftPM is intentionally not used: the installed Command Line Tools ship a
# PackageDescription library that is out of sync with its manifest API, so
# `swift build` fails to link the manifest. Compiling directly with swiftc
# sidesteps that and works with just the Command Line Tools.
#
# Usage:
#   ./build.sh          build the app bundle
#   ./build.sh run      build, then launch it
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# User-facing app/bundle/executable name. (The source dir + bundle identifier keep
# their original names so TCC grants and persisted settings survive the rebrand.)
APP_NAME="Lyria"

BUILD_DIR="$ROOT/.build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"

# macOS 26/27 SDKs turn SwiftUI's @State/@Binding/etc. into MACROS that need the
# `SwiftUIMacros` compiler plugin. That plugin ships with Xcode but NOT the
# Command Line Tools, and it must be paired with Xcode's matching SDK (mixing
# Xcode's plugin with the CLT SDK fails at `_makeStorage_v0`). So build with
# Xcode's toolchain + SDK when Xcode is present; otherwise fall back to the CLT
# swiftc (fine on macOS ≤ 25, where @State is still a property wrapper).
XCODE_DEV="$(xcode-select -p 2>/dev/null || true)"
if [[ "$XCODE_DEV" != *"/Xcode"*".app/"* && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
	XCODE_DEV="/Applications/Xcode.app/Contents/Developer"
fi
XCODE_SWIFTC="$XCODE_DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
XCODE_SDK="$XCODE_DEV/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
if [[ -x "$XCODE_SWIFTC" && -d "$XCODE_SDK" ]]; then
	SWIFTC="$XCODE_SWIFTC"
	SDK_PATH="$XCODE_SDK"
	echo "==> Toolchain: Xcode (SwiftUI macro plugin available)"
else
	SWIFTC="swiftc"
	SDK_PATH="$(xcrun --show-sdk-path)"
	echo "==> Toolchain: Command Line Tools (no SwiftUI macro plugin — fails on macOS 26+)"
fi
# Minimum supported macOS; the build machine can be newer.
TARGET="arm64-apple-macosx13.0"

# Sparkle auto-update framework (vendored, universal). `-F` puts it on the
# framework search path so `import Sparkle` resolves; it's embedded + signed below.
SPARKLE_DIR="$ROOT/Vendor/Sparkle-2.9.3"

echo "==> Cleaning previous bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "==> Collecting sources"
SOURCES=()
while IFS= read -r file; do
	SOURCES+=("$file")
done < <(find "$ROOT/Sources" -name '*.swift')

echo "==> Compiling ${#SOURCES[@]} files"
"$SWIFTC" \
	-O \
	-swift-version 5 \
	-sdk "$SDK_PATH" \
	-target "$TARGET" \
	-import-objc-header "$ROOT/Sources/DynamicIsland/DynamicIsland-Bridging.h" \
	-I "$ROOT/Sources/DynamicIsland" \
	-framework ScriptingBridge \
	-framework AVKit \
	-framework CoreAudio \
	-framework AudioToolbox \
	-framework CoreMediaIO \
	-framework CoreWLAN \
	-framework IOBluetooth \
	-framework IOKit \
	-framework EventKit \
	-framework CoreLocation \
	-F "$SPARKLE_DIR" \
	-framework Sparkle \
	-Xlinker -rpath -Xlinker @executable_path/../Frameworks \
	-lsqlite3 \
	-o "$MACOS_DIR/$APP_NAME" \
	"${SOURCES[@]}"

# Liquid Glass (the macOS 26 control redesign) is gated by the binary's LINKED-SDK
# field in LC_BUILD_VERSION, which `-target …macosx13.0` stamps to 13.0 along with
# the deployment minimum. Bump just the SDK field to 26.0 so the SYSTEM controls
# (Toggle/Slider/Picker) render Liquid Glass on macOS 26+, while `minos` stays 13.0
# so the app still deploys back to macOS 13. (vtool invalidates the link-time ad-hoc
# signature; the real signing below fixes that.)
if command -v vtool >/dev/null 2>&1; then
	vtool -set-build-version macos 13.0 26.0 -replace \
		-output "$MACOS_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME" >/dev/null 2>&1 \
		&& echo "==> Linked-SDK stamped 26.0 (Liquid Glass on macOS 26+, deploys to 13)" \
		|| echo "==> vtool failed — controls will use the legacy appearance"
fi

echo "==> Assembling bundle"
cp "$ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# App icon (optional): the Info.plist points CFBundleIconFile at "AppIcon", so
# include it if it's been generated (Scripts/make-icon.sh). Without it the app
# just shows the generic icon — harmless for local runs.
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
	cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Embed Sparkle.framework so the app can self-update. The binary links it via
# @rpath (set at link time to @executable_path/../Frameworks). Copied fresh each
# build since the bundle is wiped above; signed inside-out in the signing step.
echo "==> Embedding Sparkle.framework"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"
cp -R "$SPARKLE_DIR/Sparkle.framework" "$FRAMEWORKS_DIR/"

# Sign with a STABLE self-signed code-signing certificate so TCC keys its grants
# (Full Disk Access, Accessibility) to the designated requirement — bundle ID +
# the cert's leaf hash — which survives rebuilds. Ad-hoc (`--sign -`) keys grants
# to the cdhash instead, which changes every build and wipes the grants, forcing
# a re-grant each time. Create the cert once via Keychain Access ▸ Certificate
# Assistant ▸ Create a Certificate (Self Signed Root, type Code Signing), then
# grant the two permissions once and they persist. Falls back to ad-hoc (with a
# warning) when the cert isn't on this machine, so the build still works.
# NB: no `-v` — a self-signed cert is "not trusted" so `-v` (valid-only) hides
# it, but it signs fine and TCC's designated requirement only checks the leaf
# cert hash (not the trust chain), so grants still persist.
# PRODUCTION (distribution) path: set DI_DEVID_IDENTITY to a "Developer ID
# Application: …" identity to produce a Hardened-Runtime, entitled, timestamped
# binary ready to notarize (see Scripts/make-dmg.sh). This is the only signing
# that runs on other people's Macs without a Gatekeeper warning. Local dev keeps
# using the self-signed identity below (no env var set).
# Resolve the signing identity + flags ONCE, then sign inside-out: Sparkle's
# nested helpers and framework first, the app last (so the app's seal covers the
# freshly-signed framework). Two paths:
#   • PRODUCTION — set DI_DEVID_IDENTITY to a "Developer ID Application: …"
#     identity for a Hardened-Runtime, timestamped, entitled bundle ready to
#     notarize (Scripts/make-dmg.sh). The only signing that runs warning-free on
#     other Macs.
#   • LOCAL DEV — a STABLE self-signed cert ("DynamicIsland Local" by default) so
#     TCC keys its grants (Full Disk Access, Accessibility) to the designated
#     requirement (bundle ID + the cert's leaf hash), which survives rebuilds.
#     Ad-hoc (`--sign -`) keys to the cdhash instead, which changes every build
#     and wipes grants. Create the cert once via Keychain Access ▸ Certificate
#     Assistant ▸ Create a Certificate (Self Signed Root, type Code Signing).
# NB: no `-v` — a self-signed cert is "not trusted" so `-v` (valid-only) hides
# it, but it signs fine and TCC only checks the leaf cert hash, not the chain.
ENTITLEMENTS="$ROOT/Resources/DynamicIsland.entitlements"
SPARKLE_FW="$FRAMEWORKS_DIR/Sparkle.framework"

if [[ -n "${DI_DEVID_IDENTITY:-}" ]]; then
	SIGN_ID="$DI_DEVID_IDENTITY"
	HARDEN=(--options runtime --timestamp)   # required for notarization
	SIGN_DESC="Developer ID + Hardened Runtime + entitlements (ready to notarize)"
	SIGN_FATAL=1
else
	HARDEN=()
	SIGN_FATAL=0
	want="${DI_SIGN_IDENTITY:-DynamicIsland Local}"
	if security find-identity -p codesigning 2>/dev/null | grep -qF "$want"; then
		SIGN_ID="$want"
		SIGN_DESC="stable identity: $want (TCC grants persist)"
	else
		SIGN_ID="-"
		SIGN_DESC="ad-hoc — '$want' not found, so FDA/Accessibility grants WILL reset"
	fi
fi

# Sparkle's helpers, deepest first (XPC services → Autoupdate → Updater.app →
# framework). No app entitlements on these; Hardened Runtime is applied for the
# Developer ID path so they remain notarizable.
sv="$SPARKLE_FW/Versions/B"
sign_fail=0
for item in \
	"$sv/XPCServices/Downloader.xpc" \
	"$sv/XPCServices/Installer.xpc" \
	"$sv/Autoupdate" \
	"$sv/Updater.app" \
	"$SPARKLE_FW"; do
	codesign --force ${HARDEN[@]+"${HARDEN[@]}"} --sign "$SIGN_ID" "$item" >/dev/null 2>&1 || sign_fail=1
done

# The app last. The Developer ID path also applies the app entitlements.
if [[ -n "${DI_DEVID_IDENTITY:-}" ]]; then
	codesign --force ${HARDEN[@]+"${HARDEN[@]}"} --entitlements "$ENTITLEMENTS" \
		--sign "$SIGN_ID" "$APP_BUNDLE" >/dev/null 2>&1 || sign_fail=1
else
	codesign --force --sign "$SIGN_ID" "$APP_BUNDLE" >/dev/null 2>&1 || sign_fail=1
fi

if [[ "$sign_fail" == "0" ]]; then
	echo "    signed — $SIGN_DESC"
elif [[ "$SIGN_FATAL" == "1" ]]; then
	echo "    build failed: Developer ID signing with '$SIGN_ID' failed"
	exit 1
else
	echo "    ⚠️  signing had errors ($SIGN_DESC) — usually non-fatal for local runs."
	if [[ "$SIGN_ID" == "-" ]]; then
		echo "       Create 'DynamicIsland Local' in Keychain Access (Certificate Assistant ▸"
		echo "       Create a Certificate, Self Signed Root, type Code Signing) to keep grants."
	fi
fi

echo "==> Built $APP_BUNDLE"

# Design-system compliance (see DESIGN_GUIDELINES.md). Advisory by default; set
# DESIGN_LINT_STRICT=1 to fail the build on any violation.
if [[ -x "$ROOT/Scripts/design-lint.sh" ]]; then
	echo "==> Design lint"
	if ! "$ROOT/Scripts/design-lint.sh" --summary; then
		if [[ "${DESIGN_LINT_STRICT:-0}" == "1" ]]; then
			echo "    build failed: design violations (DESIGN_LINT_STRICT=1)"
			exit 1
		fi
		echo "    (advisory — run ./Scripts/design-lint.sh for details; DESIGN_LINT_STRICT=1 to enforce)"
	fi
fi

if [[ "${1:-}" == "run" ]]; then
	echo "==> Launching"
	open "$APP_BUNDLE"
fi
