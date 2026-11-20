#!/bin/zsh
# Renders the app icon (the "margin" drawing) at every macOS size and packs it into Resources/AppIcon.icns,
# which scripts/build-app.sh copies into the app. Needs swiftc and iconutil (Xcode command-line tools).
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(cd ../../.. && pwd)"
mkdir -p ../bin
swiftc -O -suppress-warnings -o ../bin/icon ../cutter/Core.swift ../cutter/Ink.swift main.swift
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  ../bin/icon margin "$SET/icon_${s}x${s}.png" $s > /dev/null
  ../bin/icon margin "$SET/icon_${s}x${s}@2x.png" $((s * 2)) > /dev/null
done
iconutil -c icns "$SET" -o "$REPO/Resources/AppIcon.icns"
../bin/icon margin "$REPO/Resources/AppIcon-1024.png" 1024 > /dev/null
rm -rf "$(dirname "$SET")"
echo "wrote $REPO/Resources/AppIcon.icns"
