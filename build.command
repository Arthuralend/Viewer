#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Нужны Xcode 16+ или Command Line Tools с macOS 15+ SDK."
    echo "Установите их, затем повторно откройте build.command."
    exit 1
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p build
STAGING="$(mktemp -d "$PWD/build/.staging.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/HDR Photo Viewer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -sdk "$SDK" -target arm64-apple-macos15.0 \
    -module-cache-path "$PWD/build/ModuleCache" \
    Sources/*.swift -o "$APP/Contents/MacOS/HDRPhotoViewer" \
    -framework AppKit -framework CoreImage -framework ImageIO \
    -framework Metal -framework MetalKit -framework QuartzCore -framework UniformTypeIdentifiers
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
# Publish only after compilation and signing succeed.
if [ -d 'build/HDR Photo Viewer.app' ]; then
    mv 'build/HDR Photo Viewer.app' "build/HDR Photo Viewer.previous.$(date +%s).app"
fi
mv "$APP" 'build/HDR Photo Viewer.app'
echo "Готово: $PWD/build/HDR Photo Viewer.app"
if [ "${HDRVIEWER_NO_LAUNCH:-0}" != "1" ]; then
    open 'build/HDR Photo Viewer.app'
fi
