#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ "${HDRVIEWER_SKIP_BUILD:-0}" != "1" ]; then
    HDRVIEWER_NO_LAUNCH=1 bash build.command
fi
STAGING="$(mktemp -d "$PWD/build/.dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto 'build/HDR Photo Viewer.app' "$STAGING/HDR Photo Viewer.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname 'HDR Photo Viewer' -srcfolder "$STAGING" \
    -ov -format UDZO 'build/HDR Photo Viewer.dmg'
hdiutil verify 'build/HDR Photo Viewer.dmg'
echo "Готово: $PWD/build/HDR Photo Viewer.dmg"
