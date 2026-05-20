#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

DO_ICON_FIX=0
DO_INSTALL_LAUNCHDAEMON=1
DO_LOAD_KEXT=1
DO_ELIGIBILITY=1
DO_SAE=1
DO_LOCATION_CN_FIX=1
DO_VERIFY_ONLY=0

KEXT="/Library/Extensions/CodexRegionSpoof.kext"
LOCAL_KEXT="$ROOT_DIR/tools/CodexRegionSpoof.kext"
LOCAL_KEXT_BIN="$LOCAL_KEXT/Contents/MacOS/CodexRegionSpoof"
LOCAL_KEXT_BIN_B64="$LOCAL_KEXT/Contents/MacOS/CodexRegionSpoof.b64"
LOADER_SCRIPT="/Library/Scripts/Codex/load-region-spoof.sh"
LOADER_PLIST="/Library/LaunchDaemons/local.codex.region-spoof-loader.plist"
GEOSERVICES_DIR="/var/db/locationd/Library/Caches/GeoServices"
GEOSERVICES_DIRECT_STORE="${GEOSERVICES_DIR}/DirectReadConfigStore.plist"

ELIGIBILITYD_PLIST="/private/var/db/eligibilityd/eligibility.plist"
OS_ELIGIBILITY_PLIST="/private/var/db/os_eligibility/eligibility.plist"
ELIGIBILITY_BACKUP_BASE="/private/var/db/eligibilityd_source_backup"

SIRI_DOMAIN="com.apple.assistant.backedup"
SIRI_KEY="SiriAvailability"
SIRI_PREF="$HOME/Library/Preferences/${SIRI_DOMAIN}.plist"

SIRI_ICON_MNT="/private/tmp/codex_system_rw"
SIRI_ICON_DEVICE="/dev/disk3s5"
SIRI_ICON_INFO="${SIRI_ICON_MNT}/System/Applications/Siri.app/Contents/Info.plist"

ELIGIBILITYD_DOMAINS=(
  OS_ELIGIBILITY_DOMAIN_GREYMATTER
  OS_ELIGIBILITY_DOMAIN_FOUNDATION_MODELS
  OS_ELIGIBILITY_DOMAIN_PERSONAL_QA
  OS_ELIGIBILITY_DOMAIN_SIRI_WITH_APP_INTENTS
  OS_ELIGIBILITY_DOMAIN_TERBIUM
)

OS_ELIGIBILITY_DOMAINS=(
  OS_ELIGIBILITY_DOMAIN_AI_LABELING
  OS_ELIGIBILITY_DOMAIN_IRON
  OS_ELIGIBILITY_DOMAIN_STRONTIUM
  OS_ELIGIBILITY_DOMAIN_SWIFT_ASSIST
  OS_ELIGIBILITY_DOMAIN_XCODE_LLM
)

usage() {
  cat <<'EOF'
Usage:
  ./enable_apple_intelligence_oneclick.sh [options]

Options:
  --all                 Run core enable steps and Siri Launchpad icon snapshot fix.
  --fix-siri-icon       Patch /System/Applications/Siri.app Info.plist so Launchpad
                        falls back to the new AppIcon.icns. Requires reboot.
  --verify-only         Only print current state; do not change anything.
  --skip-kext           Do not load CodexRegionSpoof.kext this run.
  --skip-launchdaemon   Do not install/update the boot-time kext loader.
  --skip-eligibility    Do not patch eligibility plists.
  --skip-sae            Do not force Siri SAE orchestration preference.
  --skip-location-cn    Do not pin GeoServices location country cache to CN.
  -h, --help            Show this help.

Recovery prerequisites:
  1. csrutil disable
  2. csrutil authenticated-root disable
  3. Startup Security Utility -> Reduced Security -> allow kernel extensions
  4. tools/CodexRegionSpoof.kext present in this repository, or already
     installed at /Library/Extensions/CodexRegionSpoof.kext

What this single script does:
  - verifies SIP / SSV / root IORegistry region state
  - installs/loads the kernel-side region-info spoof kext
  - installs a boot-time LaunchDaemon to reload that kext
  - patches Apple Intelligence eligibility domains to answer_t = 4
  - forces Siri SAE orchestration mode
  - keeps GeoServices location country on CN so Maps/Weather can locate in China
  - refreshes affected availability clients
  - optionally patches the Siri Launchpad icon source and blesses a snapshot

No sudo password is stored. sudo prompts normally.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      DO_ICON_FIX=1
      ;;
    --fix-siri-icon)
      DO_ICON_FIX=1
      ;;
    --verify-only)
      DO_VERIFY_ONLY=1
      DO_LOAD_KEXT=0
      DO_INSTALL_LAUNCHDAEMON=0
      DO_ELIGIBILITY=0
      DO_SAE=0
      DO_LOCATION_CN_FIX=0
      DO_ICON_FIX=0
      ;;
    --skip-kext)
      DO_LOAD_KEXT=0
      ;;
    --skip-launchdaemon)
      DO_INSTALL_LAUNCHDAEMON=0
      ;;
    --skip-eligibility)
      DO_ELIGIBILITY=0
      ;;
    --skip-sae)
      DO_SAE=0
      ;;
    --skip-location-cn)
      DO_LOCATION_CN_FIX=0
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

require_path() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "Missing required path: $path" >&2
    exit 1
  fi
}

ensure_region_spoof_kext_installed() {
  if [[ -d "$KEXT" ]]; then
    return 0
  fi

  section "Install CodexRegionSpoof.kext"
  if [[ ! -d "$LOCAL_KEXT" ]]; then
    echo "Missing $KEXT and missing local bundle $LOCAL_KEXT" >&2
    echo "Place CodexRegionSpoof.kext in tools/ or install it manually under /Library/Extensions." >&2
    exit 1
  fi

  if [[ ! -x "$LOCAL_KEXT_BIN" && -f "$LOCAL_KEXT_BIN_B64" ]]; then
    echo "Reconstructing local kext executable from base64 payload..."
    /usr/bin/base64 -D -i "$LOCAL_KEXT_BIN_B64" -o "$LOCAL_KEXT_BIN"
    chmod 755 "$LOCAL_KEXT_BIN"
  fi

  if [[ ! -x "$LOCAL_KEXT_BIN" ]]; then
    echo "Missing local kext executable: $LOCAL_KEXT_BIN" >&2
    exit 1
  fi

  echo "Installing $LOCAL_KEXT -> $KEXT"
  run_root rm -rf "$KEXT"
  run_root cp -R "$LOCAL_KEXT" "$KEXT"
  run_root chown -R root:wheel "$KEXT"
  run_root chmod -R go-w "$KEXT"
  codesign -dv --verbose=2 "$KEXT" 2>&1 | grep -E 'Identifier=|Signature=|TeamIdentifier=' || true
}

sudo_keepalive_start() {
  sudo -v
  while true; do
    sudo -n true 2>/dev/null || exit
    sleep 60
  done &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill ${SUDO_KEEPALIVE_PID:-0} 2>/dev/null || true' EXIT
}

run_root() {
  if [[ "$(id -u)" == "0" ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

pb_sudo() {
  run_root /usr/libexec/PlistBuddy -c "$1" "$2"
}

print_boot_policy() {
  section "Boot policy"
  if command -v bputil >/dev/null 2>&1; then
    run_root bputil -d 2>&1 | sed -n '/OS environment:/,/Boot Args Filtering Status/p' || true
  else
    echo "bputil not found"
  fi
}

print_sip_state() {
  section "SIP / SSV"
  csrutil status 2>&1 || true
  csrutil authenticated-root status 2>&1 || true
}

print_root_region_state() {
  section "Root region state"
  echo "-- NVRAM --"
  nvram -p 2>/dev/null | grep -E '^(region-info|boot-args)' || true

  echo
  echo "-- IOPlatformExpertDevice --"
  ioreg -rd1 -c IOPlatformExpertDevice |
    grep -Ei '"region-info"|"country-of-origin"|"model"|"model-number"|"regulatory-model-number"' || true

  echo
  echo "-- kext install/authentication --"
  if [[ -d "$KEXT" ]]; then
    codesign -dv --verbose=2 "$KEXT" 2>&1 |
      grep -E 'Identifier=|Authority=|TeamIdentifier=' || true
    run_root kmutil print-diagnostics -p "$KEXT" 2>&1 | sed -n '1,80p' || true
  else
    echo "$KEXT not installed"
  fi

  echo
  echo "-- loaded status --"
  run_root kmutil showloaded 2>/dev/null | grep -E -i 'Codex|RegionSpoof' || echo "CodexRegionSpoof is not loaded"
}

load_region_spoof_kext() {
  section "Load root region spoof kext"
  ensure_region_spoof_kext_installed

  run_root kmutil load -p "$KEXT" || true

  echo
  echo "-- kernel log --"
  run_root dmesg | grep CodexRegionSpoof | tail -20 || true

  echo
  echo "-- loaded status --"
  run_root kmutil showloaded 2>/dev/null | grep -E -i 'Codex|RegionSpoof' || true

  echo
  echo "-- IORegistry after load --"
  ioreg -rd1 -c IOPlatformExpertDevice |
    grep -Ei '"region-info"|"country-of-origin"|"model"|"model-number"|"regulatory-model-number"' || true
}

install_region_spoof_launchdaemon() {
  section "Install boot-time kext loader"
  ensure_region_spoof_kext_installed

  run_root mkdir -p /Library/Scripts/Codex

  local tmp_script
  tmp_script="$(mktemp)"
  cat > "$tmp_script" <<'EOF'
#!/bin/zsh
set -u

LOG="/var/log/codex-region-spoof-loader.log"
KEXT="/Library/Extensions/CodexRegionSpoof.kext"

{
  echo "==== $(date) ===="
  echo "before:"
  /usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice | /usr/bin/grep -Ei '"region-info"|"country-of-origin"' || true

  if /usr/bin/kmutil showloaded 2>/dev/null | /usr/bin/grep -qi 'local.codex.RegionSpoof'; then
    echo "CodexRegionSpoof already loaded"
  else
    echo "loading $KEXT"
    /usr/bin/kmutil load -p "$KEXT" || true
  fi

  /bin/sleep 1
  echo "after:"
  /usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice | /usr/bin/grep -Ei '"region-info"|"country-of-origin"' || true
  /usr/bin/kmutil showloaded 2>/dev/null | /usr/bin/grep -Ei 'Codex|RegionSpoof' || true

  echo "restarting AI availability daemons"
  /usr/bin/killall eligibilityd generativeexperiencesd modelcatalogd 2>/dev/null || true

  echo "pinning GeoServices location country cache to CN for mainland Maps location"
  /bin/mkdir -p /var/db/locationd/Library/Caches/GeoServices
  /bin/cat > /var/db/locationd/Library/Caches/GeoServices/DirectReadConfigStore.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>DeviceCountryCodeSourced</key>
  <dict>
    <key>cc</key>
    <string>CN</string>
    <key>metadata</key>
    <dict/>
    <key>source</key>
    <integer>262</integer>
  </dict>
</dict>
</plist>
PLIST
  /usr/sbin/chown _locationd:_locationd /var/db/locationd/Library/Caches/GeoServices/DirectReadConfigStore.plist 2>/dev/null || true
  /bin/chmod 0644 /var/db/locationd/Library/Caches/GeoServices/DirectReadConfigStore.plist 2>/dev/null || true
  /usr/bin/killall locationd geod routined 2>/dev/null || true
} >> "$LOG" 2>&1

exit 0
EOF
  run_root install -o root -g wheel -m 755 "$tmp_script" "$LOADER_SCRIPT"
  rm -f "$tmp_script"

  local tmp_plist
  tmp_plist="$(mktemp)"
  cat > "$tmp_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.codex.region-spoof-loader</string>
  <key>ProgramArguments</key>
  <array>
    <string>${LOADER_SCRIPT}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>LaunchOnlyOnce</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/var/log/codex-region-spoof-loader.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>/var/log/codex-region-spoof-loader.stderr.log</string>
</dict>
</plist>
EOF
  run_root install -o root -g wheel -m 644 "$tmp_plist" "$LOADER_PLIST"
  rm -f "$tmp_plist"

  run_root launchctl bootout system "$LOADER_PLIST" 2>/dev/null || true
  run_root launchctl bootstrap system "$LOADER_PLIST" 2>/dev/null || true
  run_root launchctl kickstart -k system/local.codex.region-spoof-loader 2>/dev/null || true

  echo "Installed and started: $LOADER_PLIST"
  echo "Log: /var/log/codex-region-spoof-loader.log"
}

unlock_plist() {
  local plist="$1"
  [[ -e "$plist" ]] || return 0
  run_root chflags nouchg "$plist" 2>/dev/null || true
}

lock_plist() {
  local plist="$1"
  [[ -e "$plist" ]] || return 0
  run_root chown root:_eligibilityd "$plist"
  run_root chmod 0644 "$plist"
  run_root chflags uchg "$plist"
}

ensure_domain() {
  local plist="$1"
  local domain="$2"

  pb_sudo "Print :${domain}" "$plist" >/dev/null 2>&1 || pb_sudo "Add :${domain} dict" "$plist"

  pb_sudo "Print :${domain}:os_eligibility_answer_source_t" "$plist" >/dev/null 2>&1 \
    && pb_sudo "Set :${domain}:os_eligibility_answer_source_t 1" "$plist" \
    || pb_sudo "Add :${domain}:os_eligibility_answer_source_t integer 1" "$plist"

  pb_sudo "Print :${domain}:os_eligibility_answer_t" "$plist" >/dev/null 2>&1 \
    && pb_sudo "Set :${domain}:os_eligibility_answer_t 4" "$plist" \
    || pb_sudo "Add :${domain}:os_eligibility_answer_t integer 4" "$plist"

  pb_sudo "Print :${domain}:status" "$plist" >/dev/null 2>&1 || pb_sudo "Add :${domain}:status dict" "$plist"
}

set_status_if_present_or_add() {
  local plist="$1"
  local domain="$2"
  local input="$3"
  pb_sudo "Print :${domain}:status:${input}" "$plist" >/dev/null 2>&1 \
    && pb_sudo "Set :${domain}:status:${input} 3" "$plist" \
    || pb_sudo "Add :${domain}:status:${input} integer 3" "$plist"
}

normalize_existing_status_values() {
  local plist="$1"
  local domain="$2"
  local keys
  keys=("${(@f)$(pb_sudo "Print :${domain}:status" "$plist" 2>/dev/null \
    | sed -n 's/^[[:space:]]*\([^ =][^ =]*\)[[:space:]]*=.*/\1/p')}")

  local key
  for key in "${keys[@]}"; do
    [[ "$key" == "Dict" || -z "$key" ]] && continue
    pb_sudo "Set :${domain}:status:${key} 3" "$plist" >/dev/null 2>&1 || true
  done
}

patch_domain() {
  local plist="$1"
  local domain="$2"

  ensure_domain "$plist" "$domain"
  normalize_existing_status_values "$plist" "$domain"

  case "$domain" in
    OS_ELIGIBILITY_DOMAIN_GREYMATTER)
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_COUNTRY_BILLING
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_COUNTRY_LOCATION
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_DEVICE_AND_SIRI_LANGUAGE_MATCH
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_DEVICE_CLASS
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_DEVICE_LANGUAGE
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_DEVICE_REGION_CODE
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_EXTERNAL_BOOT_DRIVE
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_GENERATIVE_MODEL_SYSTEM
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_SHARED_IPAD
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_SIRI_LANGUAGE
      ;;
    OS_ELIGIBILITY_DOMAIN_IRON)
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_COUNTRY_BILLING
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_COUNTRY_LOCATION
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_DEVICE_CLASS
      ;;
    OS_ELIGIBILITY_DOMAIN_SWIFT_ASSIST|OS_ELIGIBILITY_DOMAIN_XCODE_LLM)
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_DEVICE_CLASS
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_DEVICE_REGION_CODE
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_EXTERNAL_BOOT_DRIVE
      ;;
    OS_ELIGIBILITY_DOMAIN_STRONTIUM)
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_DEVICE_CLASS
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_DEVICE_REGION_CODE
      ;;
    *)
      set_status_if_present_or_add "$plist" "$domain" OS_ELIGIBILITY_INPUT_DEVICE_REGION_CODE
      ;;
  esac
}

patch_eligibility_domains() {
  section "Patch Apple Intelligence eligibility domains"
  local backup_dir="${ELIGIBILITY_BACKUP_BASE}/force-ai-domains-$(date +%Y%m%d-%H%M%S)"

  run_root mkdir -p "$backup_dir"
  for plist in "$ELIGIBILITYD_PLIST" "$OS_ELIGIBILITY_PLIST"; do
    if [[ -e "$plist" ]]; then
      run_root cp -p "$plist" "$backup_dir/$(basename "$(dirname "$plist")")-$(basename "$plist")"
    fi
  done
  echo "Backup: $backup_dir"

  unlock_plist "$ELIGIBILITYD_PLIST"
  unlock_plist "$OS_ELIGIBILITY_PLIST"

  for domain in "${ELIGIBILITYD_DOMAINS[@]}"; do
    echo "  $domain -> ELIGIBLE"
    patch_domain "$ELIGIBILITYD_PLIST" "$domain"
  done

  for domain in "${OS_ELIGIBILITY_DOMAINS[@]}"; do
    echo "  $domain -> ELIGIBLE"
    patch_domain "$OS_ELIGIBILITY_PLIST" "$domain"
  done

  lock_plist "$ELIGIBILITYD_PLIST"
  lock_plist "$OS_ELIGIBILITY_PLIST"

  run_root launchctl kickstart -k system/com.apple.eligibilityd 2>/dev/null || run_root killall eligibilityd 2>/dev/null || true
  notifyutil -p com.apple.os-eligibility-domain.change.greymatter 2>/dev/null || true
  notifyutil -p com.apple.os-eligibility-domain.change.foundation-models 2>/dev/null || true
  notifyutil -p com.apple.os-eligibility-domain.change.personal-qa 2>/dev/null || true
  notifyutil -p com.apple.os-eligibility-domain.change.siri-with-app-intents 2>/dev/null || true
  notifyutil -p com.apple.os-eligibility-domain.change.terbium 2>/dev/null || true
  notifyutil -p com.apple.os-eligibility-domain.change.iron 2>/dev/null || true
  notifyutil -p com.apple.os-eligibility-domain.change.strontium 2>/dev/null || true
  notifyutil -p com.apple.os-eligibility-domain.change.swift-assist 2>/dev/null || true
  notifyutil -p com.apple.os-eligibility-domain.change.xcode-llm 2>/dev/null || true
}

print_eligibility_answers() {
  section "Apple Intelligence eligibility answers"
  for domain in "${ELIGIBILITYD_DOMAINS[@]}"; do
    printf '%-48s ' "$domain"
    pb_sudo "Print :${domain}:os_eligibility_answer_t" "$ELIGIBILITYD_PLIST" 2>/dev/null || echo "(missing)"
  done
  for domain in "${OS_ELIGIBILITY_DOMAINS[@]}"; do
    printf '%-48s ' "$domain"
    pb_sudo "Print :${domain}:os_eligibility_answer_t" "$OS_ELIGIBILITY_PLIST" 2>/dev/null || echo "(missing)"
  done
}

force_siri_sae_orchestration_mode() {
  section "Force Siri SAE orchestration mode"
  local mode="4"
  local backup_dir="$ROOT_DIR/backups/siri-availability"
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  mkdir -p "$backup_dir"

  echo "-- current SiriAvailability --"
  defaults read "$SIRI_DOMAIN" "$SIRI_KEY" 2>/dev/null || true

  if [[ -f "$SIRI_PREF" ]]; then
    cp -p "$SIRI_PREF" "$backup_dir/${SIRI_DOMAIN}.${ts}.plist"
    echo "Backup: $backup_dir/${SIRI_DOMAIN}.${ts}.plist"
  fi

  if /usr/libexec/PlistBuddy -c "Print :${SIRI_KEY}" "$SIRI_PREF" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :${SIRI_KEY}:isAvailable true" "$SIRI_PREF" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :${SIRI_KEY}:desiredOrchestrationMode $mode" "$SIRI_PREF"
    /usr/libexec/PlistBuddy -c "Set :${SIRI_KEY}:unavailabilityReasons 0" "$SIRI_PREF" 2>/dev/null || true
  else
    defaults write "$SIRI_DOMAIN" "$SIRI_KEY" -dict \
      isAvailable -bool true \
      siriLocale -string "en-US" \
      desiredOrchestrationMode -int "$mode" \
      unavailabilityReasons -int 0 \
      allCapabilities -dict fullUODCapabilities -int 15 hybridCapabilities -int 9 saeCapabilities -int 7
  fi

  /usr/bin/plutil -convert binary1 "$SIRI_PREF" 2>/dev/null || true

  killall cfprefsd 2>/dev/null || true
  killall SiriNCService Siri SystemUIServer Dock 2>/dev/null || true
  sleep 1

  echo "-- new SiriAvailability --"
  defaults read "$SIRI_DOMAIN" "$SIRI_KEY" 2>/dev/null || true
}

pin_geoservices_location_country_cn() {
  section "Pin GeoServices location country to CN"
  local backup_dir="/private/var/db/locationd_cache_backup/geo-cn-$(date +%Y%m%d-%H%M%S)"

  run_root mkdir -p "$GEOSERVICES_DIR" "$backup_dir"
  if [[ -e "$GEOSERVICES_DIRECT_STORE" ]]; then
    run_root cp -p "$GEOSERVICES_DIRECT_STORE" "$backup_dir/DirectReadConfigStore.plist.before"
    echo "Backup: $backup_dir/DirectReadConfigStore.plist.before"
  fi

  local tmp_store
  tmp_store="$(mktemp)"
  cat > "$tmp_store" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>DeviceCountryCodeSourced</key>
  <dict>
    <key>cc</key>
    <string>CN</string>
    <key>metadata</key>
    <dict/>
    <key>source</key>
    <integer>262</integer>
  </dict>
</dict>
</plist>
EOF
  run_root install -o _locationd -g _locationd -m 0644 "$tmp_store" "$GEOSERVICES_DIRECT_STORE"
  rm -f "$tmp_store"

  echo "-- GeoServices DirectReadConfigStore --"
  run_root plutil -p "$GEOSERVICES_DIRECT_STORE" 2>/dev/null || true

  killall Maps Weather 2>/dev/null || true
  killall CoreLocationAgent 2>/dev/null || true
  run_root killall locationd geod routined 2>/dev/null || true
  echo "Pinned location country cache to CN. Reopen Maps/Weather and test current location."
}

restore_siri_menu_bar_extra() {
  section "Restore Siri menu bar extra"
  defaults write com.apple.systemuiserver menuExtras -array /System/Library/CoreServices/Siri.bundle
  killall SystemUIServer 2>/dev/null || true
  echo "Requested /System/Library/CoreServices/Siri.bundle in SystemUIServer menu extras."
}

refresh_ai_clients() {
  section "Refresh AI clients"
  run_root killall eligibilityd generativeexperiencesd modelcatalogd 2>/dev/null || true
  killall "System Settings" SiriPreferenceExtension SiriNCService Siri SystemUIServer Dock cfprefsd 2>/dev/null || true
  notifyutil -p com.apple.os-eligibility-domain.change.greymatter 2>/dev/null || true
  notifyutil -p com.apple.gms.availability.notification.private 2>/dev/null || true
  sleep 2
}

patch_siri_launchpad_icon_source() {
  section "Patch Siri Launchpad icon source"
  local backup_dir="$HOME/Documents/Codex/siri-launchpad-icon-backups/$(date +%Y%m%d-%H%M%S)"

  mkdir -p "$SIRI_ICON_MNT"
  if ! mount | grep -q " on ${SIRI_ICON_MNT} "; then
    run_root mount -t apfs -o nobrowse,rw "$SIRI_ICON_DEVICE" "$SIRI_ICON_MNT"
  fi

  if [[ ! -f "$SIRI_ICON_INFO" ]]; then
    echo "Missing Siri Info.plist at $SIRI_ICON_INFO" >&2
    exit 1
  fi

  mkdir -p "$backup_dir"
  cp "$SIRI_ICON_INFO" "$backup_dir/Siri.Info.plist.before"

  echo "-- before --"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$SIRI_ICON_INFO" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$SIRI_ICON_INFO" 2>/dev/null || true

  echo "Removing CFBundleIconName so Launchpad falls back to CFBundleIconFile/AppIcon.icns..."
  run_root /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$SIRI_ICON_INFO" 2>/dev/null || true
  plutil -lint "$SIRI_ICON_INFO"
  cp "$SIRI_ICON_INFO" "$backup_dir/Siri.Info.plist.after"

  echo "-- after --"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$SIRI_ICON_INFO" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$SIRI_ICON_INFO" 2>/dev/null || echo "(CFBundleIconName removed)"

  echo "Creating new boot snapshot..."
  run_root bless --mount "$SIRI_ICON_MNT" --create-snapshot

  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /System/Applications/Siri.app || true
  /usr/bin/mdimport /System/Applications/Siri.app || true
  /usr/bin/qlmanage -r cache >/dev/null 2>&1 || true
  killall iconservicesagent IconServicesAgent Dock 2>/dev/null || true

  echo "Backup: $backup_dir"
  echo "Reboot is required for the modified system snapshot to become the live root."
}

final_hints() {
  echo
  echo "Useful verification commands:"
  echo "  ./enable_apple_intelligence_oneclick.sh --verify-only"
  echo "  defaults read com.apple.assistant.backedup SiriAvailability"
  echo "  sudo tail -100 /var/log/codex-region-spoof-loader.log"
}

section "Preflight"
echo "Workspace: $ROOT_DIR"
echo "macOS: $(sw_vers -productVersion 2>/dev/null || true)"

if [[ "$DO_VERIFY_ONLY" == "0" && ( "$DO_LOAD_KEXT" == "1" || "$DO_INSTALL_LAUNCHDAEMON" == "1" || "$DO_ELIGIBILITY" == "1" || "$DO_LOCATION_CN_FIX" == "1" || "$DO_ICON_FIX" == "1" ) ]]; then
  section "sudo"
  echo "Requesting sudo once for kext/eligibility/system-snapshot operations..."
  sudo_keepalive_start
fi

print_sip_state
print_root_region_state

if [[ "$DO_VERIFY_ONLY" == "1" ]]; then
  print_eligibility_answers
  section "SiriAvailability"
  defaults read "$SIRI_DOMAIN" "$SIRI_KEY" 2>/dev/null || true
  final_hints
  exit 0
fi

[[ "$DO_LOAD_KEXT" == "1" ]] && load_region_spoof_kext
[[ "$DO_INSTALL_LAUNCHDAEMON" == "1" ]] && install_region_spoof_launchdaemon
[[ "$DO_ELIGIBILITY" == "1" ]] && patch_eligibility_domains
[[ "$DO_SAE" == "1" ]] && force_siri_sae_orchestration_mode
[[ "$DO_LOCATION_CN_FIX" == "1" ]] && pin_geoservices_location_country_cn

refresh_ai_clients
restore_siri_menu_bar_extra
[[ "$DO_ICON_FIX" == "1" ]] && patch_siri_launchpad_icon_source

section "Final verification snapshot"
print_root_region_state
print_eligibility_answers
section "SiriAvailability"
defaults read "$SIRI_DOMAIN" "$SIRI_KEY" 2>/dev/null || true

final_hints
echo
echo "Done. Reopen System Settings > Apple Intelligence & Siri and test Writing Tools, Image Playground, Photos Clean Up."
if [[ "$DO_ICON_FIX" == "1" ]]; then
  echo "Because --fix-siri-icon/--all was used, reboot before judging the Launchpad Siri icon."
fi
