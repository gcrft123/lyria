#!/bin/bash
#
# make-dmg.sh — package DynamicIsland.app into a distributable .dmg.
#
# Builds the app (unless DI_SKIP_BUILD=1), stages it next to an /Applications
# symlink so the user can drag-to-install, and produces a compressed DMG.
#
# DISTRIBUTION CAVEAT — read this:
#   The app is signed with a SELF-SIGNED certificate, not an Apple "Developer ID",
#   and is NOT notarized. The DMG runs everywhere, but on a DIFFERENT Mac macOS
#   Gatekeeper blocks the first launch ("Apple cannot check it for malicious
#   software"). The recipient opens it once via either:
#       • right-click the app in /Applications → Open → Open, or
#       • Terminal:  xattr -dr com.apple.quarantine /Applications/DynamicIsland.app
#   To remove that step you need a paid Apple Developer ID + notarization (see
#   the notes at the bottom of this file).
#
# Usage:
#   ./Scripts/make-dmg.sh [output.dmg]     # defaults to .build/DynamicIsland-<version>.dmg
#   DI_SKIP_BUILD=1 ./Scripts/make-dmg.sh  # package the existing .build/ bundle as-is
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="DynamicIsland"
VOL_NAME="Dynamic Island"
APP_BUNDLE="$ROOT/.build/$APP_NAME.app"
PLIST="$ROOT/Resources/Info.plist"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo 0.0.0)"
OUT="${1:-$ROOT/.build/${APP_NAME}-${VERSION}.dmg}"

if [[ "${DI_SKIP_BUILD:-0}" != "1" ]]; then
	echo "==> Building app"
	"$ROOT/build.sh"
fi

[[ -d "$APP_BUNDLE" ]] || { echo "error: $APP_BUNDLE not found — build it first."; exit 1; }

echo "==> Verifying signature"
codesign --verify --deep --strict "$APP_BUNDLE" 2>/dev/null \
	&& echo "    signature OK" \
	|| echo "    ⚠️  signature check failed (still packaging — local/self-signed)"

echo "==> Staging"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_BUNDLE" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating DMG"
rm -f "$OUT"
hdiutil create \
	-volname "$VOL_NAME" \
	-srcfolder "$STAGE" \
	-fs HFS+ \
	-format UDZO \
	-ov \
	"$OUT" >/dev/null

SIZE="$(du -h "$OUT" | cut -f1 | tr -d ' ')"
echo "==> Built $OUT  ($SIZE)"

# ── Notarization (the no-warning distribution path) ──────────────────────────
# Set DI_NOTARY_PROFILE to a `notarytool` keychain profile to notarize + staple
# the DMG. The app must already be signed with a real Developer ID + Hardened
# Runtime — i.e. it was built with DI_DEVID_IDENTITY set (see build.sh). Create
# the profile once with:
#     xcrun notarytool store-credentials AC_NOTARY \
#         --apple-id "<id>" --team-id "<TEAMID>" --password "<app-specific-pw>"
if [[ -n "${DI_NOTARY_PROFILE:-}" ]]; then
	echo "==> Notarizing (profile: $DI_NOTARY_PROFILE) — this can take a few minutes"
	if xcrun notarytool submit "$OUT" --keychain-profile "$DI_NOTARY_PROFILE" --wait; then
		echo "==> Stapling ticket"
		xcrun stapler staple "$OUT" && echo "    ✅ notarized + stapled — installs cleanly on any Mac"
		xcrun stapler validate "$OUT" >/dev/null 2>&1 && echo "    staple validated"
	else
		echo "    ❌ notarization failed — 'xcrun notarytool log <id> --keychain-profile $DI_NOTARY_PROFILE' for details"
		exit 1
	fi
else
	echo "    Self-signed / not notarized — first launch on another Mac needs"
	echo "    right-click → Open (see the caveat at the top of this script)."
fi

# ── One-time setup to ship a clean, no-warning DMG (Apple Developer Program) ──
#   1. Get a "Developer ID Application" cert (Apple Developer → Certificates).
#   2. Store a notarytool credential profile (see the DI_NOTARY_PROFILE block above).
#   3. Build + package + notarize in one command:
#        DI_DEVID_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
#        DI_NOTARY_PROFILE=AC_NOTARY ./Scripts/make-dmg.sh
#      build.sh applies Hardened Runtime + Resources/DynamicIsland.entitlements;
#      this script then notarizes + staples the DMG.
