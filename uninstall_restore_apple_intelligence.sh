#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

KEXT="/Library/Extensions/CodexRegionSpoof.kext"
LOADER_SCRIPT="/Library/Scripts/Codex/load-region-spoof.sh"
LOADER_PLIST="/Library/LaunchDaemons/local.codex.region-spoof-loader.plist"
WATCHER_PLIST="$HOME/Library/LaunchAgents/com.samcheng.spe-ai-region-watcher.plist"

ELIGIBILITYD_PLIST="/private/var/db/eligibilityd/eligibility.plist"
OS_ELIGIBILITY_PLIST="/private/var/db/os_eligibility/eligibility.plist"
BACKUP_ROOT="$HOME/Documents/Codex/enableAppleIntelligence-restore-backups/$(date +%Y%m%d-%H%M%S)"

usage() {
  cat <<'EOF'
Usage:
  ./uninstall_restore_apple_intelligence.sh [--dry-run]

What this script does:
  - backs up current local state
  - unloads and removes CodexRegionSpoof.kext
  - removes the boot-time kext LaunchDaemon and loader script
  - removes the old SPE watcher LaunchAgent if installed
  - unlocks and removes eligibility cache plists so eligibilityd can recompute
  - removes user-level Apple Intelligence force defaults
  - restarts relevant daemons where possible

What it does NOT do:
  - it does not switch Startup Security back to Full Security
  - it does not run csrutil enable/disable
  - it does not modify sealed system snapshots

After running, reboot. For full Apple Pay / highest-security recovery, enter
Recovery and choose Full Security after this uninstall is complete.
EOF
}

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

section() {
  echo
  echo "== $1 =="
}

run() {
  echo "+ $*"
  if [[ "$DRY_RUN" == "0" ]]; then
    "$@"
  fi
}

run_root() {
  if [[ "$(id -u)" == "0" ]]; then
    run "$@"
  else
    echo "+ sudo $*"
    if [[ "$DRY_RUN" == "0" ]]; then
      sudo "$@"
    fi
  fi
}

sudo_keepalive_start() {
  if [[ "$DRY_RUN" == "1" || "$(id -u)" == "0" ]]; then
    return
  fi
  sudo -v
  while true; do
    sudo -n true 2>/dev/null || exit
    sleep 60
  done &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill ${SUDO_KEEPALIVE_PID:-0} 2>/dev/null || true' EXIT
}

backup_path() {
  local src="$1"
  local dst="$BACKUP_ROOT$src"
  if [[ -e "$src" ]]; then
    run mkdir -p "$(dirname "$dst")"
    run_root cp -a "$src" "$dst"
  fi
}

backup_state() {
  section "Back up current state"
  run mkdir -p "$BACKUP_ROOT"

  backup_path "$KEXT"
  backup_path "$LOADER_SCRIPT"
  backup_path "$LOADER_PLIST"
  backup_path "$WATCHER_PLIST"
  backup_path "$ELIGIBILITYD_PLIST"
  backup_path "$OS_ELIGIBILITY_PLIST"

  if [[ "$DRY_RUN" == "0" ]]; then
    {
      echo "== date =="
      date
      echo
      echo "== csrutil =="
      csrutil status 2>&1 || true
      csrutil authenticated-root status 2>&1 || true
      echo
      echo "== IOPlatformExpertDevice =="
      ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | grep -Ei '"region-info"|"country-of-origin"|"model"|"model-number"' || true
      echo
      echo "== loaded kext =="
      sudo kmutil showloaded 2>/dev/null | grep -Ei 'Codex|RegionSpoof' || true
      echo
      echo "== GMS defaults =="
      defaults read com.apple.gms.availability 2>/dev/null || true
      echo
      echo "== SiriAvailability =="
      defaults read com.apple.assistant.backedup SiriAvailability 2>/dev/null || true
      echo
      echo "== generative assistant settings =="
      defaults read com.apple.siri.generativeassistantsettings 2>/dev/null || true
    } > "$BACKUP_ROOT/state-before.txt"
  fi

  echo "Backup directory: $BACKUP_ROOT"
}

remove_launch_items() {
  section "Remove launch items"
  run_root launchctl bootout system "$LOADER_PLIST" 2>/dev/null || true
  run_root rm -f "$LOADER_PLIST"
  run_root rm -f "$LOADER_SCRIPT"

  if [[ -f "$WATCHER_PLIST" ]]; then
    run launchctl bootout "gui/$(id -u)" "$WATCHER_PLIST" 2>/dev/null || true
    run rm -f "$WATCHER_PLIST"
  fi
}

remove_kext() {
  section "Unload and remove CodexRegionSpoof.kext"
  if [[ -d "$KEXT" ]]; then
    run_root kmutil unload -p "$KEXT" 2>/dev/null || true
    run_root rm -rf "$KEXT"
  else
    echo "$KEXT not installed"
  fi
}

clear_eligibility_cache() {
  section "Clear forced eligibility caches"
  for plist in "$ELIGIBILITYD_PLIST" "$OS_ELIGIBILITY_PLIST"; do
    if [[ -e "$plist" ]]; then
      run_root chflags nouchg "$plist" 2>/dev/null || true
      run_root rm -f "$plist"
      echo "Removed $plist; eligibilityd will recompute it."
    else
      echo "$plist not present"
    fi
  done
}

clear_user_defaults() {
  section "Clear user-level Apple Intelligence force defaults"
  run defaults delete com.apple.gms.availability 2>/dev/null || true
  run defaults delete com.apple.siri.generativeassistantsettings isEnabled 2>/dev/null || true
  run defaults delete com.apple.assistant.backedup SiriAvailability 2>/dev/null || true
}

restart_services() {
  section "Restart related services"
  run_root killall eligibilityd generativeexperiencesd modelcatalogd 2>/dev/null || true
  run killall "System Settings" SiriPreferenceExtension SiriNCService Siri SystemUIServer Dock cfprefsd 2>/dev/null || true
}

print_final_state() {
  section "Current state after uninstall attempt"
  csrutil status 2>&1 || true
  csrutil authenticated-root status 2>&1 || true
  echo
  ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | grep -Ei '"region-info"|"country-of-origin"|"model"|"model-number"' || true
  echo
  if [[ "$DRY_RUN" == "0" ]]; then
    sudo kmutil showloaded 2>/dev/null | grep -Ei 'Codex|RegionSpoof' || echo "CodexRegionSpoof not loaded"
  fi
}

section "Apple Intelligence uninstall / restore"
echo "Workspace: $ROOT_DIR"
echo "Dry run: $DRY_RUN"
echo "This will remove the kext and clear forced eligibility caches. Reboot is required."

sudo_keepalive_start
backup_state
remove_launch_items
remove_kext
clear_eligibility_cache
clear_user_defaults
restart_services
print_final_state

section "Next steps"
cat <<EOF
1. Reboot.
2. Check root identity:
   ioreg -rd1 -c IOPlatformExpertDevice | grep -Ei 'region-info|country-of-origin'

3. If you want Apple Pay / highest security back, enter Recovery and set:
   - Full Security
   - csrutil enable
   - csrutil authenticated-root enable

Backup saved at:
  $BACKUP_ROOT
EOF
