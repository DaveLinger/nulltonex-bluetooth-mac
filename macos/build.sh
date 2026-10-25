#!/bin/zsh
# Build build/Y813PrintService.app with swiftc (Command Line Tools are enough), ad-hoc signed.
#   --arch native   build only for this Mac (faster; default is a universal arm64 + x86_64 binary)
#   --zip           also write build/Y813PrintService.zip (release asset)
set -euo pipefail
cd "${0:A:h}"

ARCHS=(arm64 x86_64)
ZIP=0
for a in "$@"; do
  case "$a" in
    --arch) ;;
    native) ARCHS=($(uname -m)) ;;
    --zip) ZIP=1 ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done

VERSION=${Y813_VERSION:-$(cat ../VERSION)}
MIN_MACOS=14.0
APP=build/Y813PrintService.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" build/obj

SLICES=()
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos$MIN_MACOS" \
    -import-objc-header Sources/bridge.h -lz \
    -o "build/obj/Y813PrintService-$arch" Sources/*.swift
  SLICES+=("build/obj/Y813PrintService-$arch")
done
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/Y813PrintService"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.y813.printservice</string>
  <key>CFBundleName</key><string>Y813PrintService</string>
  <key>CFBundleDisplayName</key><string>Y813 Print Service</string>
  <key>CFBundleExecutable</key><string>Y813PrintService</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Y813 Print Service sends your print jobs to the Y813 label printer over Bluetooth.</string>
</dict>
</plist>
EOF

codesign --force --sign - --identifier local.y813.printservice "$APP"
rm -rf build/obj
echo "built $APP $VERSION ($(lipo -archs "$APP/Contents/MacOS/Y813PrintService"))"

if (( ZIP )); then
  ditto -c -k --keepParent "$APP" build/Y813PrintService.zip
  echo "wrote build/Y813PrintService.zip"
fi
