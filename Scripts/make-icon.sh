#!/bin/bash
#
# make-icon.sh — assemble Resources/AppIcon.icns from the Lyria icon artwork.
#
# Uses the 1024px master exported from Icon Composer ("Icon Exports/", the
# Default light variant — already the macOS rounded-square shape with transparent
# corners), downsamples it to the standard iconset sizes with sips, and packs
# them into an .icns with iconutil. build.sh then bundles the icns. Pass a path to
# override the master (e.g. to use a different variant).
#
# (The old programmatic renderer, Scripts/icon-render.swift, is superseded by the
# Icon Composer artwork but kept for reference.)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER_SRC="${1:-$ROOT/Icon Exports/Icon-iOS-Default-1024x1024@1x.png}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MASTER="$TMP/icon.png"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"

[[ -f "$MASTER_SRC" ]] || { echo "make-icon: master not found: $MASTER_SRC" >&2; exit 1; }
echo "==> Master: $MASTER_SRC"
# Normalize to a clean 1024px PNG master (handles any source size/format).
sips -s format png -z 1024 1024 "$MASTER_SRC" --out "$MASTER" >/dev/null

echo "==> Building iconset"
for s in 16 32 128 256 512; do
	sips -z "$s" "$s"           "$MASTER" --out "$SET/icon_${s}x${s}.png"    >/dev/null
	sips -z "$((s*2))" "$((s*2))" "$MASTER" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done

echo "==> Packing AppIcon.icns"
iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
echo "==> Wrote Resources/AppIcon.icns ($(du -h "$ROOT/Resources/AppIcon.icns" | cut -f1 | tr -d ' '))"
