#!/bin/zsh
# Build build/Y813PrintService.app with swiftc (Command Line Tools are enough), ad-hoc signed.
# Note: ad-hoc signatures change on every build, so macOS asks for Bluetooth permission again.
set -euo pipefail
cd "${0:A:h}"

APP=build/Y813PrintService.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 \
  -import-objc-header Sources/bridge.h -lz \
  -o "$APP/Contents/MacOS/Y813PrintService" Sources/*.swift

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.y813.printservice</string>
  <key>CFBundleName</key><string>Y813PrintService</string>
  <key>CFBundleDisplayName</key><string>Y813 Print Service</string>
  <key>CFBundleExecutable</key><string>Y813PrintService</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Y813 Print Service sends your print jobs to the Y813 label printer over Bluetooth.</string>
</dict>
</plist>
EOF

codesign --force --sign - --identifier local.y813.printservice "$APP"
echo "built $APP"
