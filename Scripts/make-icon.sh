#!/bin/bash
#
# make-icon.sh — render the app icon and assemble Resources/AppIcon.icns.
#
# Renders a 1024px master with Scripts/icon-render.swift, downsamples it to the
# standard iconset sizes with sips, and packs them into an .icns with iconutil.
# Run once (or after editing icon-render.swift); build.sh then bundles the icns.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MASTER="$TMP/icon.png"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"

echo "==> Rendering master (1024px)"
swift "$ROOT/Scripts/icon-render.swift" "$MASTER"

echo "==> Building iconset"
for s in 16 32 128 256 512; do
	sips -z "$s" "$s"           "$MASTER" --out "$SET/icon_${s}x${s}.png"    >/dev/null
	sips -z "$((s*2))" "$((s*2))" "$MASTER" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done

echo "==> Packing AppIcon.icns"
iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
echo "==> Wrote Resources/AppIcon.icns ($(du -h "$ROOT/Resources/AppIcon.icns" | cut -f1 | tr -d ' '))"
