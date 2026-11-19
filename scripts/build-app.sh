#!/bin/zsh
# Builds Paper Companion.app into ./build. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/PaperCompanion"
APP="build/Paper Companion.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PaperCompanion"
cp Resources/sparse-routing-attention.pdf "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Paper Companion</string>
  <key>CFBundleDisplayName</key><string>Paper Companion</string>
  <key>CFBundleIdentifier</key><string>app.papercompanion.mac</string>
  <key>CFBundleExecutable</key><string>PaperCompanion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PDF Document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
# Ad-hoc signatures are otherwise identified by a hash of the exact binary, so every rebuild looked like a new
# app to the Keychain and it asked for the API key again. A fixed designated requirement keeps the identity
# the same across rebuilds, so "Always Allow" sticks.
codesign --force --sign - --identifier app.papercompanion.mac \
  --requirements '=designated => identifier "app.papercompanion.mac"' "$APP"
echo "Built $APP"
