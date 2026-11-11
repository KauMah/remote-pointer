#!/bin/bash
# One-time setup for the virtual mouse (Universal Control support). Run with sudo:
#   sudo helper/install.sh path/to/Karabiner-DriverKit-VirtualHIDDevice-x.y.z.pkg
# Installs the Karabiner DriverKit virtual HID driver, then runs its daemon and rp-hid-helper as launchd daemons.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
PKG="${1:?usage: sudo install.sh <Karabiner-DriverKit-VirtualHIDDevice.pkg>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
USER_UID="${SUDO_UID:?run via sudo from your user account}"
DEST="/Library/Application Support/RemotePointer"
KDAEMON="/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon"

pkgutil --check-signature "$PKG" | grep -q "Developer ID Installer: Fumihiko Takayama (G43BCU2T37)" || { echo "unexpected package signature"; exit 1; }
installer -pkg "$PKG" -target /

mkdir -p "$DEST"
install -m 755 "$HERE/rp-hid-helper" "$DEST/rp-hid-helper"

cat > /Library/LaunchDaemons/org.pqrs.Karabiner-VirtualHIDDevice-Daemon.remote-pointer.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>org.pqrs.Karabiner-VirtualHIDDevice-Daemon.remote-pointer</string>
  <key>ProgramArguments</key><array><string>$KDAEMON</string></array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
</dict></plist>
EOF

cat > /Library/LaunchDaemons/com.kaumah.remote-pointer.hid-helper.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.kaumah.remote-pointer.hid-helper</string>
  <key>ProgramArguments</key><array><string>$DEST/rp-hid-helper</string><string>$USER_UID</string></array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/remote-pointer-hid.log</string>
  <key>StandardErrorPath</key><string>/var/log/remote-pointer-hid.log</string>
</dict></plist>
EOF

for p in org.pqrs.Karabiner-VirtualHIDDevice-Daemon.remote-pointer com.kaumah.remote-pointer.hid-helper; do
  launchctl bootout system "/Library/LaunchDaemons/$p.plist" 2>/dev/null || true
  launchctl bootstrap system "/Library/LaunchDaemons/$p.plist"
done
echo "Installed. Now activate the driver (as your user, not sudo):"
echo "  /Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager activate"
