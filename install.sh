#!/bin/zsh
# Y813 Print Service installer: makes a NULLTONEX Y813 (Bluetooth LE) show up as a normal macOS printer.
#
#   curl -fsSL https://raw.githubusercontent.com/DaveLinger/nulltonex-bluetooth-mac/main/install.sh | zsh
#
# Options:
#   --from-source   build the app from this checkout instead of downloading it (needs Xcode Command Line Tools)
#   --app PATH      install a downloaded Y813PrintService.zip or .app instead of downloading
#   --no-queue      don't add the "Y813" print queue
#   --uninstall     remove the print queue, background service and app
set -euo pipefail

REPO=DaveLinger/nulltonex-bluetooth-mac
ZIP_URL="${Y813_ZIP_URL:-https://github.com/$REPO/releases/latest/download/Y813PrintService.zip}"
LABEL=local.y813.printservice
APP="$HOME/Applications/Y813PrintService.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/Y813PrintService.log"
URI=ipp://127.0.0.1:8631/ipp/print
DOMAIN="gui/$(id -u)"

say() { print -P "%B==>%b $*"; }
die() { print -P "%F{red}error:%f $*" >&2; exit 1; }

stop_service() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  pkill -f "Y813PrintService.app/Contents/MacOS/Y813PrintService" 2>/dev/null || true
}

MODE=download SRC="" QUEUE=1
while (( $# )); do
  case "$1" in
    --from-source) MODE=source ;;
    --app) MODE=local; SRC="${2:?--app needs a path}"; shift ;;
    --no-queue) QUEUE=0 ;;
    --uninstall) MODE=uninstall ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
  shift
done

if [[ $MODE == uninstall ]]; then
  say "Removing print queue, service and app"
  lpadmin -x Y813 2>/dev/null || true
  stop_service
  rm -f "$PLIST"
  rm -rf "$APP"
  say "Uninstalled. (Log kept at $LOG)"
  exit 0
fi

[[ $(uname) == Darwin ]] || die "this installer is for macOS"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

case $MODE in
  download)
    say "Downloading the latest release"
    curl -fL --progress-bar -o "$TMP/app.zip" "$ZIP_URL" || die "download failed: $ZIP_URL"
    ditto -x -k "$TMP/app.zip" "$TMP"
    ;;
  local)
    [[ -e $SRC ]] || die "$SRC not found"
    if [[ $SRC == *.zip ]]; then ditto -x -k "$SRC" "$TMP"; else ditto "$SRC" "$TMP/Y813PrintService.app"; fi
    ;;
  source)
    HERE="${0:A:h}"
    [[ -x $HERE/macos/build.sh ]] || die "--from-source must be run from a checkout of $REPO"
    xcrun --find swiftc >/dev/null 2>&1 || die "swiftc not found; install the Command Line Tools: xcode-select --install"
    say "Building from source"
    "$HERE/macos/build.sh" native
    ditto "$HERE/macos/build/Y813PrintService.app" "$TMP/Y813PrintService.app"
    ;;
esac
[[ -x $TMP/Y813PrintService.app/Contents/MacOS/Y813PrintService ]] || die "no Y813PrintService.app in the download"
# A browser download marks files as quarantined; the app is ad-hoc signed, so clear it for this copy.
xattr -dr com.apple.quarantine "$TMP/Y813PrintService.app" 2>/dev/null || true

say "Installing $(defaults read "$TMP/Y813PrintService.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '') to ~/Applications"
stop_service
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
rm -rf "$APP"
ditto "$TMP/Y813PrintService.app" "$APP"

say "Checking Bluetooth permission. If macOS asks whether \"Y813 Print Service\" may use Bluetooth, click Allow."
open -W "$APP" --args authorize || true
case "$(grep -o 'authorize: [a-z]*' "$LOG" 2>/dev/null | tail -1)" in
  "authorize: allowed") say "Bluetooth permission granted" ;;
  "authorize: denied")
    print -P "%F{yellow}Bluetooth permission was denied.%f Turn on \"Y813PrintService\" in System Settings > Privacy & Security > Bluetooth, then run this installer again." ;;
  *) print -P "%F{yellow}Couldn't confirm Bluetooth permission.%f If printing fails, check System Settings > Privacy & Security > Bluetooth." ;;
esac

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
for i in {1..40}; do curl -fs "http://127.0.0.1:8631/" >/dev/null && break; sleep 0.25; done
curl -fs "http://127.0.0.1:8631/" >/dev/null || die "the service didn't start; see $LOG"
say "Background service running (starts automatically at login)"

if (( QUEUE )); then
  if lpadmin -p Y813 -E -v "$URI" -m everywhere -D "Y813 Label Printer" -L "Bluetooth LE" 2>"$TMP/lpadmin.err"; then
    say "Added printer \"Y813 Label Printer\""
  else
    print -P "%F{yellow}Couldn't add the print queue:%f $(cat "$TMP/lpadmin.err")"
    print "Adding printers needs an admin account. Ask an admin to run:"
    print "  lpadmin -p Y813 -E -v $URI -m everywhere -D \"Y813 Label Printer\""
  fi
fi

say "Done. Turn the printer on, then print a 4x6 label PDF to \"Y813 Label Printer\"."
