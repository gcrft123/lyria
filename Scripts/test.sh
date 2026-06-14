#!/bin/bash
#
# test.sh — compile and run the pure-logic test suite.
#
# SwiftPM/XCTest don't work against this repo's direct-swiftc build (see build.sh
# for why), so the tests live in Tests/ and are compiled into a small executable
# alongside the app sources — EXCLUDING the app's @main (Bootstrap.swift); the
# test runner provides its own @main. Same module, so `internal` symbols are
# reachable. Exit code: 0 = all passed, 1 = a test failed (CI-friendly).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Toolchain selection mirrors build.sh: the macOS 26/27 SDK turns SwiftUI's
# @State/@Binding into macros that need Xcode's compiler plugin + matching SDK.
XCODE_DEV="$(xcode-select -p 2>/dev/null || true)"
if [[ "$XCODE_DEV" != *"/Xcode"*".app/"* && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
	XCODE_DEV="/Applications/Xcode.app/Contents/Developer"
fi
XCODE_SWIFTC="$XCODE_DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
XCODE_SDK="$XCODE_DEV/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
if [[ -x "$XCODE_SWIFTC" && -d "$XCODE_SDK" ]]; then
	SWIFTC="$XCODE_SWIFTC"
	SDK_PATH="$XCODE_SDK"
else
	SWIFTC="swiftc"
	SDK_PATH="$(xcrun --show-sdk-path)"
fi
TARGET="arm64-apple-macosx13.0"
SPARKLE_DIR="$ROOT/Vendor/Sparkle-2.9.3"   # app sources `import Sparkle`
OUT="$ROOT/.build/DynamicIslandTests"
mkdir -p "$ROOT/.build"

# App sources minus the app entry point, plus the test files.
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done \
	< <(find "$ROOT/Sources" -name '*.swift' ! -name 'Bootstrap.swift')
while IFS= read -r file; do SOURCES+=("$file"); done \
	< <(find "$ROOT/Tests" -name '*.swift')

echo "==> Compiling ${#SOURCES[@]} files (app sources sans @main + tests)"
"$SWIFTC" \
	-Onone \
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
	-Xlinker -rpath -Xlinker "$SPARKLE_DIR" \
	-lsqlite3 \
	-o "$OUT" \
	"${SOURCES[@]}"

echo "==> Running tests"
"$OUT"
