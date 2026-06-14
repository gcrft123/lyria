#!/bin/bash
#
# release.sh — cut a Sparkle release: build, archive, sign, and (re)generate the
# appcast that Lyria's updater reads.
#
# What it does, end to end:
#   1. Builds the app bundle (./build.sh). For a distributable build, set
#      DI_DEVID_IDENTITY to a "Developer ID Application: …" identity first so the
#      result is Hardened-Runtime + entitled + timestamped (notarizable). Without
#      it you get the local self-signed build — fine for testing the update flow,
#      but Gatekeeper will warn on other Macs.
#   2. Zips the .app into dist/Lyria-<version>.zip (ditto, --keepParent).
#   3. Runs Sparkle's generate_appcast over dist/, which EdDSA-signs every archive
#      with the private key generate_keys put in your login keychain, writes the
#      enclosure's sparkle:edSignature, and builds binary deltas from older
#      versions still sitting in dist/.
#   4. Copies the resulting appcast.xml into docs/ so GitHub Pages serves it at
#      the SUFeedURL (https://gcrft123.github.io/lyria/appcast.xml).
#
# After running:
#   • Create a GitHub release tagged v<version> on gcrft123/lyria and upload the
#     dist/Lyria-<version>.zip (and any *.delta files) as assets — the appcast
#     enclosure URLs point at exactly that release's download path.
#   • Commit & push docs/appcast.xml so Pages publishes the new feed.
#
# Keep the dist/ directory across releases: generate_appcast needs the older
# archives present to produce deltas, and to keep prior <item>s in the feed.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE_BIN="$ROOT/Vendor/Sparkle-2.9.3/bin"
APP_BUNDLE="$ROOT/.build/Lyria.app"
DIST="$ROOT/dist"
INFO_PLIST="$ROOT/Resources/Info.plist"

# GitHub release where the binaries live; the appcast enclosure URLs are built
# from this. The tag is v<version> by convention.
GH_REPO="gcrft123/lyria"

plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"; }

VERSION="$(plist_get CFBundleShortVersionString)"
BUILD="$(plist_get CFBundleVersion)"
TAG="v$VERSION"
DOWNLOAD_PREFIX="https://github.com/$GH_REPO/releases/download/$TAG/"
ARCHIVE="$DIST/Lyria-$VERSION.zip"

echo "==> Releasing Lyria $VERSION (build $BUILD), tag $TAG"

# A new build number is what Sparkle compares to decide "is there an update?".
# Warn if it collides with an archive already in dist for a different version.
if [[ -f "$ARCHIVE" ]]; then
	echo "    note: $ARCHIVE already exists — it will be overwritten."
fi

# generate_appcast (which signs each archive with the EdDSA private key from the
# login keychain) and sign_update must both be present and executable.
if [[ ! -x "$SPARKLE_BIN/generate_appcast" || ! -x "$SPARKLE_BIN/sign_update" ]]; then
	echo "    build failed: Sparkle tools not found at $SPARKLE_BIN" >&2
	exit 1
fi

echo "==> Building app bundle"
if [[ -n "${DI_DEVID_IDENTITY:-}" ]]; then
	echo "    (Developer ID: $DI_DEVID_IDENTITY — notarizable build)"
else
	echo "    ⚠️  no DI_DEVID_IDENTITY set — local self-signed build (Gatekeeper will warn on other Macs)."
fi
"$ROOT/build.sh"

[[ -d "$APP_BUNDLE" ]] || { echo "    build failed: $APP_BUNDLE missing" >&2; exit 1; }

echo "==> Archiving → $ARCHIVE"
mkdir -p "$DIST"
rm -f "$ARCHIVE"
# ditto --keepParent so the zip contains Lyria.app at its root (what Sparkle and
# Finder expect). -c create, -k PKZip, --sequesterRsrc keeps xattrs tidy.
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE"

echo "==> Generating + signing appcast"
# --download-url-prefix makes each <enclosure url> absolute, pointing at the
# GitHub release assets. generate_appcast signs each archive (EdDSA, keychain
# key) and writes deltas for older versions still in dist/.
"$SPARKLE_BIN/generate_appcast" \
	--download-url-prefix "$DOWNLOAD_PREFIX" \
	"$DIST"

[[ -f "$DIST/appcast.xml" ]] || { echo "    build failed: appcast.xml not produced" >&2; exit 1; }

echo "==> Publishing appcast → docs/appcast.xml"
cp "$DIST/appcast.xml" "$ROOT/docs/appcast.xml"

cat <<EOF

✅ Release prepared for Lyria $VERSION.

Next steps (manual, by design — these publish to the public repo):
  1. Create the GitHub release and upload the assets:
       gh release create $TAG \\
         "$ARCHIVE"$( ls "$DIST"/*.delta >/dev/null 2>&1 && printf ' \\\n         %q' "$DIST"/*.delta ) \\
         --repo $GH_REPO --title "Lyria $VERSION" --notes "…"
  2. Commit & push the feed so Pages serves it:
       git add docs/appcast.xml && git commit -m "Release $VERSION appcast" && git push
EOF
