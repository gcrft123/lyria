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
ENTITLEMENTS="$ROOT/Resources/DynamicIsland.entitlements"
if [[ -n "${DI_DEVID_IDENTITY:-}" ]]; then
	if codesign --force --options runtime --timestamp \
		--entitlements "$ENTITLEMENTS" \
		--sign "$DI_DEVID_IDENTITY" "$APP_BUNDLE"; then
		echo "    ✅ Developer ID signed + Hardened Runtime + entitlements (ready to notarize)"
	else
		echo "    build failed: Developer ID signing with '$DI_DEVID_IDENTITY' failed"
		exit 1
	fi
else
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
SIGN_ID="${DI_SIGN_IDENTITY:-DynamicIsland Local}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
	codesign --force --sign "$SIGN_ID" "$APP_BUNDLE" >/dev/null 2>&1 && \
		echo "    signed with stable identity: $SIGN_ID (TCC grants persist)" || \
		echo "    (codesign failed with '$SIGN_ID' — not fatal for local runs)"
else
	codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
	echo "    ⚠️  ad-hoc signed — '$SIGN_ID' not found, so FDA/Accessibility grants WILL reset."
	echo "       Create it in Keychain Access (Certificate Assistant ▸ Create a Certificate,"
	echo "       Self Signed Root, type Code Signing) or set DI_SIGN_IDENTITY to an existing one."
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
