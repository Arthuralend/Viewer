#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
NATIVE_ARCH="$(uname -m)"
if [ "$NATIVE_ARCH" = arm64 ]; then
    'build/HDR Photo Viewer.app/Contents/MacOS/HDRPhotoViewer' --self-test
else
    # The distributed application stays arm64. Run identical checks natively
    # on Intel builders, which cannot execute an Apple Silicon binary.
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
    xcrun swiftc -swift-version 5 -O -sdk "$SDK" -target "${NATIVE_ARCH}-apple-macos15.0" \
        -module-cache-path "$PWD/build/ModuleCache" \
        Sources/*.swift -o build/NativeChecks \
        -framework AppKit -framework CoreImage -framework ImageIO \
        -framework Metal -framework MetalKit -framework QuartzCore -framework UniformTypeIdentifiers
    build/NativeChecks --self-test
fi
