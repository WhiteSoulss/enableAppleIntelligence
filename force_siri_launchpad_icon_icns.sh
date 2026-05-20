#!/bin/zsh
set -euo pipefail

PASS="${SUDO_PASSWORD:-${SUDO_PASS:-}}"
MNT="/private/tmp/codex_system_rw"
DEVICE="/dev/disk3s5"
INFO="$MNT/System/Applications/Siri.app/Contents/Info.plist"
BACKUP_DIR="$HOME/Documents/Codex/siri-launchpad-icon-backups/$(date +%Y%m%d-%H%M%S)"

echo "Mounting writable system volume..."
mkdir -p "$MNT"
if ! mount | grep -q " on $MNT "; then
  if [[ -n "$PASS" ]]; then
    printf '%s\n' "$PASS" | sudo -S mount -t apfs -o nobrowse,rw "$DEVICE" "$MNT"
  else
    sudo mount -t apfs -o nobrowse,rw "$DEVICE" "$MNT"
  fi
fi

if [[ ! -f "$INFO" ]]; then
  echo "missing Siri Info.plist at $INFO" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"
cp "$INFO" "$BACKUP_DIR/Siri.Info.plist.before"

echo "Before:"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$INFO" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$INFO" 2>/dev/null || true

echo "Removing CFBundleIconName so Launchpad falls back to CFBundleIconFile/AppIcon.icns..."
if [[ -n "$PASS" ]]; then
  printf '%s\n' "$PASS" | sudo -S /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$INFO" 2>/dev/null || true
else
  sudo /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$INFO" 2>/dev/null || true
fi
plutil -lint "$INFO"
cp "$INFO" "$BACKUP_DIR/Siri.Info.plist.after"

echo "After:"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$INFO" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$INFO" 2>/dev/null || echo "(CFBundleIconName removed)"

echo "Creating new boot snapshot..."
if [[ -n "$PASS" ]]; then
  printf '%s\n' "$PASS" | sudo -S bless --mount "$MNT" --create-snapshot
else
  sudo bless --mount "$MNT" --create-snapshot
fi

echo "Refreshing user caches..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /System/Applications/Siri.app || true
/usr/bin/mdimport /System/Applications/Siri.app || true
/usr/bin/qlmanage -r cache >/dev/null 2>&1 || true
/usr/bin/killall iconservicesagent 2>/dev/null || true
/usr/bin/killall IconServicesAgent 2>/dev/null || true
/usr/bin/killall Dock 2>/dev/null || true

echo "Backup: $BACKUP_DIR"
echo "Reboot is required for the modified system snapshot to become the live root."
