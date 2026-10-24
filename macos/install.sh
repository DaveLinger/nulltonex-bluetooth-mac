#!/bin/zsh
# Install Y813 Print Service for the current user:
#   ~/Applications/Y813PrintService.app + LaunchAgent local.y813.printservice (starts at login).
#   --queue     also add the CUPS queue "Y813" (IPP Everywhere -> ipp://127.0.0.1:8631/ipp/print)
#   --uninstall remove the queue, LaunchAgent and app
set -euo pipefail
cd "${0:A:h}"

LABEL=local.y813.printservice
APP="$HOME/Applications/Y813PrintService.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
URI=ipp://127.0.0.1:8631/ipp/print
DOMAIN="gui/$(id -u)"

if [[ "${1:-}" == "--uninstall" ]]; then
  lpadmin -x Y813 2>/dev/null || true
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$APP"
  echo "uninstalled"
  exit 0
fi

./build.sh
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
rm -rf "$APP"
cp -R build/Y813PrintService.app "$APP"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/MacOS/Y813PrintService</string>
    <string>serve</string>
    <string>--density</string><string>11</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/Y813PrintService.stderr.log</string>
</dict>
</plist>
EOF

launchctl bootstrap "$DOMAIN" "$PLIST"
echo "LaunchAgent loaded; log: ~/Library/Logs/Y813PrintService.log"

if [[ "${1:-}" == "--queue" ]]; then
  for i in {1..20}; do curl -fs "http://127.0.0.1:8631/" >/dev/null && break; sleep 0.5; done
  lpadmin -p Y813 -E -v "$URI" -m everywhere -D "Y813 Label Printer" -L "Bluetooth LE"
  echo "queue Y813 added"
fi
