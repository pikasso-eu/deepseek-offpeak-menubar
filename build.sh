#!/bin/bash
# Builds "DeepSeek Off-Peak Menubar" as a macOS .app bundle.
# Usage:  ./build.sh
# Result: build/DeepSeekOffPeak.app
set -euo pipefail
cd "$(dirname "$0")"

APP="build/DeepSeekOffPeak.app"
BIN="$APP/Contents/MacOS/DeepSeekOffPeak"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary: Intel (x86_64) + Apple Silicon (arm64) when the SDK supports it.
ARCHS=()
for arch in x86_64 arm64; do
    echo "Compiling for $arch ..."
    if swiftc -parse-as-library -O \
        -target "${arch}-apple-macos13.0" \
        -module-cache-path "$PWD/build/module-cache-${arch}" \
        -o "$APP/Contents/MacOS/DeepSeekOffPeak-${arch}" \
        DeepSeekOffPeak.swift; then
        ARCHS+=("$arch")
    else
        echo "  -> $arch not available with this SDK, skipping"
    fi
done

if [ ${#ARCHS[@]} -eq 0 ]; then
    echo "error: no architecture could be built" >&2
    exit 1
elif [ ${#ARCHS[@]} -eq 1 ]; then
    mv "$APP/Contents/MacOS/DeepSeekOffPeak-${ARCHS[0]}" "$BIN"
else
    lipo -create "${ARCHS[@]/#/$APP/Contents/MacOS/DeepSeekOffPeak-}" -output "$BIN"
    rm -f "$APP/Contents/MacOS/DeepSeekOffPeak-"*
fi

cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/. "$APP/Contents/Resources/"

# Ad-hoc signature (needed for login item / notifications on recent macOS).
if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP" 2>/dev/null || true
fi

echo ""
echo "Built: $APP ($(lipo -archs "$BIN" 2>/dev/null || echo "single arch"))"
echo ""
echo "Run the menu bar app:"
echo "  open \"$PWD/$APP\""
echo ""
echo "Command line:"
echo "  \"$PWD/$BIN\" --help"
