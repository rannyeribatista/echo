#!/bin/bash
# echomac-login.sh — bring EchoMac up at login.  {install | uninstall | status}
#
# A LaunchAgent that just `open`s the app: no KeepAlive, deliberately. If you
# quit EchoMac you meant it, and it should stay quit until the next login — a
# relaunching agent turns "quit" into a fight you can't win.
#
# Pairs with the app coming up already listening (EchoClient.init, 2026-08-08):
# agent opens it at login, the app starts its own poll loop, and Nic's voice is
# on the Mac without a click.
set -euo pipefail

LABEL="com.rannyeri.echo.mac.login"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEBUG_APP="$REPO/build/Build/Products/Debug/EchoMac.app"
UID_NUM="$(id -u)"

# Prefer a real installed copy; fall back to whatever Xcode last built. Override
# with ECHOMAC_APP=/path/to/EchoMac.app for a Release build somewhere else.
find_app() {
  if [ -n "${ECHOMAC_APP:-}" ]; then printf '%s\n' "$ECHOMAC_APP"; return 0; fi
  for candidate in "/Applications/EchoMac.app" "$DEBUG_APP"; do
    [ -d "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

install_agent() {
  local app
  app="$(find_app)" || {
    echo "echomac-login: no EchoMac.app found."
    echo "  Build it first (xcodegen && open Echo.xcodeproj → EchoMac scheme → ⌘R),"
    echo "  or point at one: ECHOMAC_APP=/path/to/EchoMac.app $0 install"
    exit 1
  }
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>$app</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
  plutil -lint "$PLIST" >/dev/null || { echo "echomac-login: generated plist is malformed"; exit 1; }
  launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_NUM" "$PLIST"
  echo "echomac-login: installed → $app"
  case "$app" in
    "$REPO"/build/*)
      echo "  note: that's the Xcode Debug build inside the gitignored build/ dir."
      echo "  A Clean Build Folder deletes it and login launch fails silently."
      echo "  For something durable, copy a Release build to /Applications and re-run install."
      ;;
  esac
}

uninstall_agent() {
  launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "echomac-login: removed (EchoMac no longer starts at login)"
}

status_agent() {
  if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
    echo "installed — $(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$PLIST" 2>/dev/null)"
  else
    echo "not installed"
  fi
}

case "${1:-status}" in
  install)   install_agent ;;
  uninstall) uninstall_agent ;;
  status)    status_agent ;;
  *)         echo "usage: echomac-login.sh {install|uninstall|status}" ;;
esac
