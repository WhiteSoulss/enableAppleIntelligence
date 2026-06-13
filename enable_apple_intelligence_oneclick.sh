#!/bin/zsh
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$ROOT_DIR/$(basename "$0")"

ACTION="install"
DRY_RUN=0
FORCE_GEOSERVICES_US=0
SKIP_KEXT=0
SKIP_LAUNCHDAEMON=0
SKIP_ELIGIBILITY=0
SKIP_SAE=0
SKIP_GEOSERVICES=0
SKIP_COUNTRYD=0
SKIP_APPLE_INTERNAL=0
SKIP_MACOS27_SIRI_AI=0
SKIP_SIRI_LOCATION_ICON=0
SKIP_WEB_SEARCH=0
DO_ICON_FIX=0

KEXT_ID="local.codex.RegionSpoof"
KEXT_DST="/Library/Extensions/CodexRegionSpoof.kext"
LOCAL_KEXT="$ROOT_DIR/tools/CodexRegionSpoof.kext"
LOCAL_KEXT_BIN="$LOCAL_KEXT/Contents/MacOS/CodexRegionSpoof"
LOCAL_KEXT_BIN_B64="$LOCAL_KEXT/Contents/MacOS/CodexRegionSpoof.b64"
LOADER_SCRIPT="/Library/Scripts/Codex/load-region-spoof.sh"
LOADER_PLIST="/Library/LaunchDaemons/local.codex.region-spoof-loader.plist"
SIRI_LOCATION_FIX_DIR="/Library/Scripts/Codex/SiriLocationIconFix"

ELIGIBILITYD_PLIST="/private/var/db/eligibilityd/eligibility.plist"
OS_ELIGIBILITY_PLIST="/private/var/db/os_eligibility/eligibility.plist"
ELIGIBILITY_BACKUP_BASE="/private/var/db/eligibilityd_source_backup"

GEOSERVICES_DIR="/var/db/locationd/Library/Caches/GeoServices"
GEOSERVICES_DIRECT_STORE="$GEOSERVICES_DIR/DirectReadConfigStore.plist"
COUNTRYD_PLIST="/private/var/db/com.apple.countryd/countryCodeCache.plist"
COUNTRYD_BACKUP_BASE="/private/var/db/countryd_cache_backup"

SIRI_DOMAIN="com.apple.assistant.backedup"
SIRI_KEY="SiriAvailability"
SIRI_SYSTEM_APP="/System/Applications/Siri.app"
SIRI_CORESERVICES_APP="/System/Library/CoreServices/Siri.app"

SYSTEM_RW_MNT="/private/tmp/codex_system_rw"
APPLE_INTERNAL_VARIANT_PLIST="/System/Library/CoreServices/AppleInternalVariant.plist"
APPLE_INTERNAL_VARIANT_BACKUP_BASE="/private/var/db/codex_apple_internal_variant_backup"
FEATUREFLAGS_OVERRIDE_DIR="/Library/Preferences/FeatureFlags/Domain"
GM_FEATUREFLAGS_OVERRIDE_PLIST="$FEATUREFLAGS_OVERRIDE_DIR/GenerativeModels.plist"
SYSTEM_GM_FEATUREFLAGS_PLIST="/System/Library/FeatureFlags/Domain/GenerativeModels.plist"
FEATUREFLAGS_BACKUP_BASE="/private/var/db/codex_featureflags_backup"

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

UI_LINE="----------------------------------------------------------------"

log() { printf '%s\n' "$*"; }
hr() { printf '%s\n' "$UI_LINE"; }
section() { printf '\n%s\n> %s\n' "$UI_LINE" "$1"; }
ok() { printf '  [OK]   %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
note() { printf '  [..]   %s\n' "$1"; }
kv() { printf '  %-26s %s\n' "$1:" "$2"; }
die() { printf '  [FAIL] %s\n' "$1" >&2; exit 1; }

banner() {
  local mode="$1"
  printf '\n'
  hr
  printf '  enableAppleIntelligence  |  %s\n' "$mode"
  printf '  Region identity, eligibility, Siri and model asset helpers\n'
  hr
}

usage() {
  cat <<'EOF'
Usage:
  ./enable_apple_intelligence_oneclick.sh [install|status|uninstall] [options]

Default action:
  install

Actions:
  install              Install/load region spoof kext and apply AI state fixes.
  status, verify       Print current system state.
  uninstall            Remove this project's kext/LaunchDaemon and unlock caches.

Options:
  --verify-only        Alias for status.
  --uninstall          Alias for uninstall.
  --dry-run            With uninstall, show actions without changing files.
  --skip-kext          Do not install/load CodexRegionSpoof.kext this run.
  --skip-launchdaemon  Do not install/update the boot-time loader.
  --skip-eligibility   Do not patch eligibility plist domains.
  --skip-sae           Do not force Siri SAE orchestration preference.
  --skip-location-ip   Do not write GeoServices country cache.
  --force-geoservices-us
                       Force GeoServices location country to US instead of
                       detecting the current public IP country.
  --skip-countryd      Do not force countryd cache to US.
  --skip-apple-internal
                       On macOS 27+, skip AppleInternalVariant.plist.
  --skip-macos27-siri-ai
                       On macOS 27+, skip EnhancedSiriWaitlist override.
  --skip-siri-location-icon
                       Do not install/apply the Location Services Siri icon
                       runtime patch.
  --skip-web-search    Do not normalize Siri/Safari web search to Google.
  --all                Run install and refresh Siri icon identity.
  --fix-siri-icon      Refresh Siri icon identity only.
  -h, --help           Show this help.

Recovery prerequisites:
  csrutil disable
  csrutil authenticated-root disable
  Startup Security Utility -> Reduced Security -> allow kernel extensions

After success, the recommended higher-security state is:
  csrutil authenticated-root enable
  FileVault on

Do not run csrutil enable while using the bundled ad-hoc kext. With SIP fully
enabled, the kext will not load and the Mac will naturally fall back to CH.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    install)
      ACTION="install"
      ;;
    status|verify|doctor)
      ACTION="status"
      ;;
    icon)
      ACTION="icon"
      DO_ICON_FIX=1
      ;;
    uninstall|remove)
      ACTION="uninstall"
      ;;
    --verify-only)
      ACTION="status"
      ;;
    --uninstall)
      ACTION="uninstall"
      ;;
    --dry-run)
      ACTION="uninstall"
      DRY_RUN=1
      ;;
    --all)
      ACTION="install"
      DO_ICON_FIX=1
      ;;
    --fix-siri-icon)
      ACTION="icon"
      DO_ICON_FIX=1
      FORCE_GEOSERVICES_US=1
      ;;
    --skip-kext)
      SKIP_KEXT=1
      ;;
    --skip-launchdaemon)
      SKIP_LAUNCHDAEMON=1
      ;;
    --skip-eligibility)
      SKIP_ELIGIBILITY=1
      ;;
    --skip-sae)
      SKIP_SAE=1
      ;;
    --skip-location-ip|--skip-location-cn)
      SKIP_GEOSERVICES=1
      ;;
    --force-geoservices-us|--force-location-us|--force-geo-us)
      FORCE_GEOSERVICES_US=1
      ;;
    --skip-countryd)
      SKIP_COUNTRYD=1
      ;;
    --skip-apple-internal|--skip-apple-internal-variant|--skip-internal-variant)
      SKIP_APPLE_INTERNAL=1
      ;;
    --skip-macos27-siri-ai|--skip-macos27-siri)
      SKIP_MACOS27_SIRI_AI=1
      ;;
    --skip-siri-location-icon)
      SKIP_SIRI_LOCATION_ICON=1
      ;;
    --skip-web-search)
      SKIP_WEB_SEARCH=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
  shift
done

if [[ "$(id -u)" != "0" ]]; then
  log "Need administrator privileges. Re-running with sudo..."
  sudo_args=("$ACTION")
  [[ "$DRY_RUN" == "1" ]] && sudo_args+=(--dry-run)
  [[ "$FORCE_GEOSERVICES_US" == "1" ]] && sudo_args+=(--force-geoservices-us)
  [[ "$SKIP_KEXT" == "1" ]] && sudo_args+=(--skip-kext)
  [[ "$SKIP_LAUNCHDAEMON" == "1" ]] && sudo_args+=(--skip-launchdaemon)
  [[ "$SKIP_ELIGIBILITY" == "1" ]] && sudo_args+=(--skip-eligibility)
  [[ "$SKIP_SAE" == "1" ]] && sudo_args+=(--skip-sae)
  [[ "$SKIP_GEOSERVICES" == "1" ]] && sudo_args+=(--skip-location-ip)
  [[ "$SKIP_COUNTRYD" == "1" ]] && sudo_args+=(--skip-countryd)
  [[ "$SKIP_APPLE_INTERNAL" == "1" ]] && sudo_args+=(--skip-apple-internal)
  [[ "$SKIP_MACOS27_SIRI_AI" == "1" ]] && sudo_args+=(--skip-macos27-siri-ai)
  [[ "$SKIP_SIRI_LOCATION_ICON" == "1" ]] && sudo_args+=(--skip-siri-location-icon)
  [[ "$SKIP_WEB_SEARCH" == "1" ]] && sudo_args+=(--skip-web-search)
  if [[ "$ACTION" == "icon" ]]; then
    sudo_args+=(--fix-siri-icon)
  elif [[ "$DO_ICON_FIX" == "1" ]]; then
    sudo_args+=(--all)
  fi
  exec sudo "$SELF" "${sudo_args[@]}"
fi

console_user() {
  local user
  user="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)"
  [[ -n "$user" && "$user" != "root" && "$user" != "loginwindow" ]] && echo "$user"
}

console_uid() {
  local user="$1"
  /usr/bin/id -u "$user" 2>/dev/null || true
}

console_home() {
  local user="$1"
  /usr/bin/dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null |
    /usr/bin/awk '{print $2; exit}'
}

CONSOLE_USER="$(console_user || true)"
CONSOLE_UID=""
CONSOLE_HOME=""
if [[ -n "$CONSOLE_USER" ]]; then
  CONSOLE_UID="$(console_uid "$CONSOLE_USER")"
  CONSOLE_HOME="$(console_home "$CONSOLE_USER")"
fi
[[ -n "$CONSOLE_HOME" ]] || CONSOLE_HOME="/var/root"

as_console_user() {
  if [[ -n "$CONSOLE_USER" && -n "$CONSOLE_UID" ]]; then
    /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/env \
      HOME="$CONSOLE_HOME" USER="$CONSOLE_USER" LOGNAME="$CONSOLE_USER" "$@"
  else
    "$@"
  fi
}

macos_major_version() {
  local version major
  version="$(/usr/bin/sw_vers -productVersion 2>/dev/null || echo 0)"
  major="${version%%.*}"
  [[ "$major" == <-> ]] || major=0
  echo "$major"
}

sip_disabled() {
  /usr/bin/csrutil status 2>/dev/null | /usr/bin/grep -qi disabled
}

amfi_disabled() {
  /usr/sbin/nvram boot-args 2>/dev/null | /usr/bin/grep -q 'amfi_get_out_of_my_way'
}

kext_loaded() {
  /usr/bin/kmutil showloaded --no-kernel-components 2>/dev/null |
    /usr/bin/grep -qi 'CodexRegionSpoof\|RegionSpoof'
}

root_region_is_spoofed() {
  /usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null |
    /usr/bin/grep -qi '4c4c2f41'
}

country_origin_is_usa() {
  /usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null |
    /usr/bin/grep -qi '555341'
}

yes_no() {
  if "$@"; then
    echo "yes"
  else
    echo "no"
  fi
}

auth_root_state() {
  /usr/bin/csrutil authenticated-root status 2>/dev/null |
    /usr/bin/sed -E 's/^Authenticated Root status:[[:space:]]*//; s/\.$//' |
    /usr/bin/head -1
}

eligibility_answer() {
  local plist="$1"
  local domain="$2"
  pb "Print :${domain}:os_eligibility_answer_t" "$plist" 2>/dev/null || echo "missing"
}

answer_label() {
  case "$1" in
    4) echo "4 (eligible)" ;;
    3) echo "3 (maybe)" ;;
    2) echo "2 (not eligible)" ;;
    1) echo "1 (not yet available)" ;;
    0) echo "0 (invalid)" ;;
    *) echo "$1" ;;
  esac
}

loader_installed() {
  [[ -f "$LOADER_PLIST" && -x "$LOADER_SCRIPT" ]]
}

featureflag_installed() {
  [[ -f "$GM_FEATUREFLAGS_OVERRIDE_PLIST" ]]
}

apple_internal_live() {
  apple_internal_enabled "$APPLE_INTERNAL_VARIANT_PLIST"
}

print_compact_status() {
  local macos arch sip_state ar_state amfi_state gm_answer loader_state
  macos="$(/usr/bin/sw_vers -productVersion 2>/dev/null || echo unknown)"
  arch="$(/usr/bin/uname -m 2>/dev/null || echo unknown)"
  sip_state="enabled"
  sip_disabled && sip_state="disabled"
  ar_state="$(auth_root_state)"
  [[ -n "$ar_state" ]] || ar_state="unknown"
  amfi_state="enabled"
  amfi_disabled && amfi_state="disabled by boot-arg"
  gm_answer="$(answer_label "$(eligibility_answer "$ELIGIBILITYD_PLIST" OS_ELIGIBILITY_DOMAIN_GREYMATTER)")"
  loader_state="$(yes_no loader_installed)"

  section "Quick status"
  kv "macOS" "$macos ($arch)"
  kv "Console user" "${CONSOLE_USER:-none}"
  kv "SIP" "$sip_state"
  kv "Authenticated Root" "$ar_state"
  kv "AMFI" "$amfi_state"
  kv "region-info=LL/A" "$(yes_no root_region_is_spoofed)"
  kv "country-of-origin=USA" "$(yes_no country_origin_is_usa)"
  kv "kext loaded" "$(yes_no kext_loaded)"
  kv "boot loader" "$loader_state"
  kv "GREYMATTER" "$gm_answer"
}

pb() {
  /usr/libexec/PlistBuddy -c "$1" "$2"
}

ensure_plist_file() {
  local plist="$1"
  if [[ ! -e "$plist" ]]; then
    /bin/mkdir -p "$(dirname "$plist")"
    /usr/bin/plutil -create xml1 "$plist"
  fi
}

unlock_file() {
  [[ -e "$1" ]] && /usr/bin/chflags nouchg "$1" 2>/dev/null || true
}

lock_file_eligibility() {
  [[ -e "$1" ]] || return 0
  /usr/sbin/chown root:_eligibilityd "$1" 2>/dev/null || /usr/sbin/chown root:wheel "$1" 2>/dev/null || true
  /bin/chmod 0644 "$1" 2>/dev/null || true
  /usr/bin/chflags uchg "$1" 2>/dev/null || true
}

print_sip_state() {
  section "SIP / authenticated-root"
  /usr/bin/csrutil status 2>&1 || true
  /usr/bin/csrutil authenticated-root status 2>&1 || true
}

print_boot_policy() {
  section "Boot policy"
  /usr/sbin/bputil -d 2>&1 | /usr/bin/sed -n '/OS environment:/,/Boot Args Filtering Status/p' || true
}

print_root_identity() {
  section "Root IORegistry identity"
  /usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null |
    /usr/bin/grep -Ei '"region-info"|"country-of-origin"|"model"|"model-number"|"regulatory-model-number"' || true
}

print_kext_state() {
  section "Kext"
  if [[ -d "$KEXT_DST" ]]; then
    /usr/bin/codesign -dv --verbose=2 "$KEXT_DST" 2>&1 |
      /usr/bin/grep -E 'Identifier=|Signature=|TeamIdentifier=' || true
    /usr/bin/kmutil print-diagnostics -p "$KEXT_DST" 2>&1 | /usr/bin/sed -n '1,60p' || true
  else
    log "$KEXT_DST not installed"
  fi
  log "-- loaded --"
  /usr/bin/kmutil showloaded 2>/dev/null |
    /usr/bin/grep -Ei 'Codex|RegionSpoof' || log "CodexRegionSpoof is not loaded"
}

print_eligibility_answers() {
  section "Apple Intelligence eligibility answers"
  for domain in "${ELIGIBILITYD_DOMAINS[@]}"; do
    printf '%-48s ' "$domain"
    pb "Print :${domain}:os_eligibility_answer_t" "$ELIGIBILITYD_PLIST" 2>/dev/null || echo "(missing)"
  done
  for domain in "${OS_ELIGIBILITY_DOMAINS[@]}"; do
    printf '%-48s ' "$domain"
    pb "Print :${domain}:os_eligibility_answer_t" "$OS_ELIGIBILITY_PLIST" 2>/dev/null || echo "(missing)"
  done
}

print_country_state() {
  section "countryd / GeoServices"
  if [[ -e "$COUNTRYD_PLIST" ]]; then
    /bin/ls -lO "$COUNTRYD_PLIST" 2>/dev/null || true
    /usr/bin/plutil -p "$COUNTRYD_PLIST" 2>/dev/null |
      /usr/bin/grep -E 'CountryCode|=> "US"|=> US' |
      /usr/bin/head -40 || true
  else
    log "$COUNTRYD_PLIST not present"
  fi
  log "-- GeoServices --"
  if [[ -e "$GEOSERVICES_DIRECT_STORE" ]]; then
    /usr/bin/plutil -p "$GEOSERVICES_DIRECT_STORE" 2>/dev/null || true
  else
    log "$GEOSERVICES_DIRECT_STORE not present"
  fi
}

print_macos27_state() {
  section "macOS 27 Siri AI gates"
  log "Current macOS major version: $(macos_major_version)"
  if [[ -e "$APPLE_INTERNAL_VARIANT_PLIST" ]]; then
    /bin/ls -lO "$APPLE_INTERNAL_VARIANT_PLIST" 2>/dev/null || true
    /usr/bin/plutil -p "$APPLE_INTERNAL_VARIANT_PLIST" 2>/dev/null || true
  else
    log "$APPLE_INTERNAL_VARIANT_PLIST not present on live root"
  fi
  log "-- FeatureFlags override --"
  if [[ -e "$GM_FEATUREFLAGS_OVERRIDE_PLIST" ]]; then
    /usr/bin/plutil -p "$GM_FEATUREFLAGS_OVERRIDE_PLIST" 2>/dev/null || true
  else
    log "$GM_FEATUREFLAGS_OVERRIDE_PLIST not present"
  fi
}

print_siri_state() {
  section "SiriAvailability"
  if [[ -n "$CONSOLE_USER" ]]; then
    log "Console user: $CONSOLE_USER"
    as_console_user /usr/bin/defaults read "$SIRI_DOMAIN" "$SIRI_KEY" 2>/dev/null || true
  else
    warn "No console user found"
  fi
}

preflight_install() {
  section "Environment check"
  kv "Workspace" "$ROOT_DIR"
  kv "macOS" "$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)"
  kv "Console user" "${CONSOLE_USER:-none}"

  if [[ "$(/usr/bin/uname -m)" == "arm64" ]]; then
    ok "Apple Silicon detected"
  else
    die "This project only supports Apple Silicon."
  fi

  if ! sip_disabled; then
    cat >&2 <<'MSG'
SIP is still enabled. The bundled kext is ad-hoc signed and will not load.

Boot to Recovery and run:

  csrutil disable
  csrutil authenticated-root disable

Then open Startup Security Utility:

  Reduced Security -> Allow user management of kernel extensions

Reboot and run this script again.
MSG
    exit 1
  else
    ok "SIP is disabled; kext can be loaded in Permissive/Reduced Security"
  fi

  if amfi_disabled; then
    warn "boot-args contains amfi_get_out_of_my_way. Removing it because PCC cloud AI needs AMFI."
    local args new_args
    args="$(/usr/sbin/nvram boot-args 2>/dev/null | /usr/bin/sed 's/^boot-args[[:space:]]*//' || true)"
    new_args="$(printf '%s' "$args" | /usr/bin/sed -E 's/amfi_get_out_of_my_way=[0-9]*//g' | /usr/bin/xargs || true)"
    if [[ -z "$new_args" ]]; then
      /usr/sbin/nvram -d boot-args 2>/dev/null || true
    else
      /usr/sbin/nvram boot-args="$new_args" 2>/dev/null || true
    fi
    warn "Reboot after this run so AMFI/PCC state is clean."
  else
    ok "AMFI boot-arg is clean; PCC cloud AI can attest"
  fi
}

prepare_local_kext_copy() {
  [[ -d "$LOCAL_KEXT" ]] || die "Missing local kext bundle: $LOCAL_KEXT"

  local tmp
  tmp="$(/usr/bin/mktemp -d /private/tmp/codex-kext.XXXXXX)"
  /bin/cp -R "$LOCAL_KEXT" "$tmp/CodexRegionSpoof.kext"

  if [[ ! -x "$tmp/CodexRegionSpoof.kext/Contents/MacOS/CodexRegionSpoof" ]]; then
    if [[ -f "$tmp/CodexRegionSpoof.kext/Contents/MacOS/CodexRegionSpoof.b64" ]]; then
      /usr/bin/base64 -D \
        -i "$tmp/CodexRegionSpoof.kext/Contents/MacOS/CodexRegionSpoof.b64" \
        -o "$tmp/CodexRegionSpoof.kext/Contents/MacOS/CodexRegionSpoof"
      /bin/chmod 755 "$tmp/CodexRegionSpoof.kext/Contents/MacOS/CodexRegionSpoof"
    else
      die "Missing local kext executable and .b64 payload"
    fi
  fi

  echo "$tmp/CodexRegionSpoof.kext"
}

install_kext() {
  section "Install/load CodexRegionSpoof.kext"
  local prepared_kext
  prepared_kext="$(prepare_local_kext_copy)"

  /bin/rm -rf "$KEXT_DST"
  /bin/cp -R "$prepared_kext" "$KEXT_DST"
  /usr/sbin/chown -R root:wheel "$KEXT_DST"
  /bin/chmod -R go-w "$KEXT_DST"
  ok "installed kext bundle to $KEXT_DST"

  /usr/bin/codesign -dv --verbose=2 "$KEXT_DST" 2>&1 |
    /usr/bin/grep -E 'Identifier=|Signature=|TeamIdentifier=' || true

  if kext_loaded && root_region_is_spoofed && country_origin_is_usa; then
    ok "kext already loaded and root identity is spoofed"
    return 0
  fi

  /usr/bin/kmutil load -p "$KEXT_DST" 2>&1 || true

  /bin/sleep 2
  if root_region_is_spoofed && country_origin_is_usa; then
    ok "root identity spoofed: region-info=LL/A, country-of-origin=USA"
  else
    cat <<'MSG'
The kext was installed, but IORegistry is not spoofed yet.

If this is the first load, open:

  System Settings -> Privacy & Security

Scroll to the bottom, allow the blocked system software/kernel extension, then
reboot. The LaunchDaemon will load the kext automatically on next boot.
MSG
  fi

  log "-- kernel log --"
  /sbin/dmesg | /usr/bin/grep CodexRegionSpoof | /usr/bin/tail -20 || true
}

write_siri_location_icon_patch_payload() {
  /bin/mkdir -p "$SIRI_LOCATION_FIX_DIR"
  /bin/cat > "$SIRI_LOCATION_FIX_DIR/patch_locationd_skip_assistantd_association_lldb.py" <<'PY'
"""
Runtime patch for Location Services' Siri identity.

CoreLocation often registers Siri through AssistantServices.framework. That
framework still has the legacy Siri icon, so System Settings can show the old
icon even after Apple Intelligence is active. The patch keeps the authorization
identity but rewrites only the display BundlePath to /System/Applications/Siri.app
and filters duplicate stale Siri rows.
"""

import lldb

EXPR = r'''
@import Foundation;
@import ObjectiveC;
Class cdxf_cls=(Class)NSClassFromString(@"CLClientManagerAdapter");
SEL cdxf_sel=(SEL)NSSelectorFromString(@"syncgetCopyClients");
Method cdxf_method=class_getInstanceMethod(cdxf_cls, cdxf_sel);
static id (*cdxf_origCopyClients)(id,SEL) = NULL;
if (cdxf_origCopyClients == NULL && cdxf_method != NULL) {
  cdxf_origCopyClients=(id(*)(id,SEL))method_getImplementation(cdxf_method);
  id cdxf_block = ^id(id obj) {
    id cdxf_clients = cdxf_origCopyClients(obj, cdxf_sel);
    NSMutableDictionary *cdxf_filtered = [(NSDictionary *)cdxf_clients mutableCopy];
    NSArray *cdxf_keys = [(NSDictionary *)cdxf_clients allKeys];
    for (id cdxf_key in cdxf_keys) {
      id cdxf_val = [(NSDictionary *)cdxf_clients objectForKey:cdxf_key];
      NSString *cdxf_keyLower = [[NSString stringWithFormat:@"%@", cdxf_key] lowercaseString];
      NSString *cdxf_valLower = [[NSString stringWithFormat:@"%@", cdxf_val] lowercaseString];
      BOOL cdxf_isAssistantServices = [cdxf_keyLower containsString:@"assistantservices.framework"];

      if ([cdxf_keyLower containsString:@"com.apple.assistantd"] ||
          [cdxf_keyLower containsString:@"assistant_service"] ||
          [cdxf_keyLower containsString:@"com.apple.siri"] ||
          [cdxf_keyLower containsString:@"/system/library/coreservices/siri.app"] ||
          [cdxf_keyLower containsString:@"/system/applications/siri.app"] ||
          (!cdxf_isAssistantServices &&
           ([cdxf_valLower containsString:@"com.apple.assistantd"] ||
            [cdxf_valLower containsString:@"assistant_service"] ||
            [cdxf_valLower containsString:@"com.apple.siri"] ||
            [cdxf_valLower containsString:@"assistantservices.framework"] ||
            [cdxf_valLower containsString:@"/system/library/coreservices/siri.app"] ||
            [cdxf_valLower containsString:@"/system/applications/siri.app"]))) {
        [cdxf_filtered removeObjectForKey:cdxf_key];
        continue;
      }

      if (cdxf_isAssistantServices && cdxf_val && [(NSObject *)cdxf_val isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *cdxf_rewritten = [(NSDictionary *)cdxf_val mutableCopy];
        [cdxf_rewritten setObject:@"/System/Applications/Siri.app" forKey:@"BundlePath"];
        [cdxf_filtered setObject:cdxf_rewritten forKey:cdxf_key];
      }
    }
    return cdxf_filtered;
  };
  IMP cdxf_imp=imp_implementationWithBlock(cdxf_block);
  method_setImplementation(cdxf_method, cdxf_imp);
}
@"patched syncgetCopyClients Siri display identity"
'''

def __lldb_init_module(debugger, _dict):
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    if not process or not process.IsValid():
        print("[patch-locationd-siri-filter] no process")
        return

    value = target.EvaluateExpression(EXPR)
    if not value or not value.IsValid() or value.GetError().Fail():
        print(f"[patch-locationd-siri-filter] ERROR: {value.GetError() if value else 'invalid expression'}")
        return

    print("[patch-locationd-siri-filter] patched CLClientManagerAdapter syncgetCopyClients")
    print(value.GetObjectDescription() or value.GetValue() or "")
PY
  /usr/sbin/chown -R root:wheel "$SIRI_LOCATION_FIX_DIR"
  /bin/chmod 755 "$SIRI_LOCATION_FIX_DIR"
  /bin/chmod 644 "$SIRI_LOCATION_FIX_DIR/patch_locationd_skip_assistantd_association_lldb.py"
}

clean_siri_location_rows() {
  local clients_plist="/var/db/locationd/clients.plist"
  /usr/bin/python3 - "$clients_plist" <<'PY'
import grp
import os
import plistlib
import pwd
import shutil
import sys
import time

path = sys.argv[1]
if os.path.exists(path):
    with open(path, "rb") as f:
        data = plistlib.load(f)
else:
    data = {}

def is_stale_siri_row(key, value):
    key_text = str(key).lower()
    value_text = str(value).lower()
    if "assistantservices.framework" in key_text:
        return False
    text = f"{key_text}\n{value_text}"
    return (
        "assistantd" in text
        or "assistant_service" in text
        or "com.apple.siri" in text
        or "assistantservices.framework" in text
        or "coreservices/siri.app" in text
        or "system/applications/siri.app" in text
    )

remove_keys = [key for key, value in data.items() if is_stale_siri_row(key, value)]
if os.path.exists(path):
    shutil.copy2(path, f"{path}.backup-codex-siri-icon-{time.strftime('%Y%m%d-%H%M%S')}")
for key in remove_keys:
    data.pop(key, None)

tmp = f"{path}.codex-tmp"
with open(tmp, "wb") as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)

if os.path.exists(path):
    stat = os.stat(path)
    os.chown(tmp, stat.st_uid, stat.st_gid)
    os.chmod(tmp, stat.st_mode & 0o7777)
else:
    os.chown(tmp, pwd.getpwnam("_locationd").pw_uid, grp.getgrnam("_locationd").gr_gid)
    os.chmod(tmp, 0o600)
os.replace(tmp, path)
print(f"removed={len(remove_keys)}")
for key in remove_keys:
    print(f"  {key}")
PY
}

apply_siri_location_icon_runtime_fix_now() {
  section "Location Services Siri icon runtime patch"
  local patch="$SIRI_LOCATION_FIX_DIR/patch_locationd_skip_assistantd_association_lldb.py"
  [[ -f "$patch" ]] || write_siri_location_icon_patch_payload

  /usr/bin/killall lldb debugserver 2>/dev/null || true
  /usr/bin/killall locationd 2>/dev/null || true
  /bin/sleep 1
  clean_siri_location_rows || true
  /bin/launchctl kickstart -k system/com.apple.locationd 2>/dev/null || true
  /bin/sleep 3

  local locationd_pid
  locationd_pid="$(/usr/bin/pgrep -x locationd | /usr/bin/head -1 || true)"
  if [[ -n "$locationd_pid" ]]; then
    /usr/bin/lldb --batch -p "$locationd_pid" \
      -o "command script import \"$patch\"" \
      -o 'process detach' -o quit || true
  else
    warn "locationd did not restart before patch attempt"
  fi

  if [[ -n "$CONSOLE_UID" ]]; then
    /bin/launchctl bootstrap "gui/$CONSOLE_UID" /System/Library/LaunchAgents/com.apple.assistantd.plist 2>/dev/null || true
    /bin/launchctl kickstart -k "gui/$CONSOLE_UID/com.apple.assistantd" 2>/dev/null || true
  fi
  clean_siri_location_rows || true
  as_console_user /usr/bin/killall "System Settings" SecurityPrivacyExtension cfprefsd iconservicesagent IconServicesAgent 2>/dev/null || true
}

write_loader_script() {
  local geo_mode="ip"
  local siri_location_mode="1"
  [[ "$SKIP_GEOSERVICES" == "1" ]] && geo_mode="skip"
  [[ "$FORCE_GEOSERVICES_US" == "1" ]] && geo_mode="us"
  [[ "$SKIP_SIRI_LOCATION_ICON" == "1" ]] && siri_location_mode="0"

  /bin/mkdir -p /Library/Scripts/Codex
  /bin/cat > "$LOADER_SCRIPT" <<EOF
#!/bin/zsh
set -u
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:\${PATH:-}"

LOG="/var/log/codex-region-spoof-loader.log"
KEXT="$KEXT_DST"
GEO_MODE="$geo_mode"
SIRI_LOCATION_ICON_MODE="$siri_location_mode"
SIRI_LOCATIOND_PATCH="$SIRI_LOCATION_FIX_DIR/patch_locationd_skip_assistantd_association_lldb.py"
CLIENTS_PLIST="/var/db/locationd/clients.plist"

detect_geo() {
  local cc ip city region loc json
  if [[ "\$GEO_MODE" == "us" ]]; then
    echo "US|forced|forced|forced|forced|forced to US by --force-geoservices-us"
    return 0
  fi
  json="\$(/usr/bin/curl -s --max-time 8 https://ipinfo.io/json 2>/dev/null || true)"
  if [[ -n "\$json" ]]; then
    cc="\$(printf '%s' "\$json" | /usr/bin/python3 -c 'import json,sys; print((json.load(sys.stdin).get("country") or "US").upper())' 2>/dev/null || echo US)"
    ip="\$(printf '%s' "\$json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("ip","unknown"))' 2>/dev/null || echo unknown)"
    city="\$(printf '%s' "\$json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("city","unknown"))' 2>/dev/null || echo unknown)"
    region="\$(printf '%s' "\$json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("region","unknown"))' 2>/dev/null || echo unknown)"
    loc="\$(printf '%s' "\$json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("loc","unknown"))' 2>/dev/null || echo unknown)"
    echo "\$cc|\$ip|\$city|\$region|\$loc|set from current public IP geolocation"
  else
    echo "US|unknown|unknown|unknown|unknown|public IP lookup failed; fallback US"
  fi
}

write_geoservices() {
  [[ "\$GEO_MODE" == "skip" ]] && return 0
  local line cc ip city region loc source_note
  line="\$(detect_geo)"
  IFS='|' read -r cc ip city region loc source_note <<< "\$line"
  /bin/mkdir -p "$GEOSERVICES_DIR"
  /usr/bin/python3 - "$GEOSERVICES_DIRECT_STORE" "\$cc" "\$ip" "\$city" "\$region" "\$loc" "\$source_note" <<'PY'
import plistlib
import sys
path, cc, ip, city, region, loc, source_note = sys.argv[1:8]
payload = {
    "DeviceCountryCodeSourced": {
        "cc": cc,
        "metadata": {
            "sourceNote": source_note,
            "ip": ip,
            "city": city,
            "region": region,
            "loc": loc,
        },
        "source": 262,
    }
}
with open(path, "wb") as f:
    plistlib.dump(payload, f)
PY
  /usr/sbin/chown _locationd:_locationd "$GEOSERVICES_DIRECT_STORE" 2>/dev/null || true
  /bin/chmod 0644 "$GEOSERVICES_DIRECT_STORE" 2>/dev/null || true
}

clean_siri_location_rows_for_icon_fix() {
  [[ "\$SIRI_LOCATION_ICON_MODE" == "1" ]] || return 0
  /usr/bin/python3 - "\$CLIENTS_PLIST" <<'PY'
import grp
import os
import plistlib
import pwd
import shutil
import sys
import time

path = sys.argv[1]
if os.path.exists(path):
    with open(path, "rb") as f:
        data = plistlib.load(f)
else:
    data = {}

def is_stale_siri_row(key, value):
    key_text = str(key).lower()
    value_text = str(value).lower()
    if "assistantservices.framework" in key_text:
        return False
    text = f"{key_text}\n{value_text}"
    return (
        "assistantd" in text
        or "assistant_service" in text
        or "com.apple.siri" in text
        or "assistantservices.framework" in text
        or "coreservices/siri.app" in text
        or "system/applications/siri.app" in text
    )

remove_keys = [key for key, value in data.items() if is_stale_siri_row(key, value)]
if os.path.exists(path):
    shutil.copy2(path, f"{path}.backup-codex-siri-icon-{time.strftime('%Y%m%d-%H%M%S')}")
for key in remove_keys:
    data.pop(key, None)
tmp = f"{path}.codex-tmp"
with open(tmp, "wb") as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
if os.path.exists(path):
    stat = os.stat(path)
    os.chown(tmp, stat.st_uid, stat.st_gid)
    os.chmod(tmp, stat.st_mode & 0o7777)
else:
    os.chown(tmp, pwd.getpwnam("_locationd").pw_uid, grp.getgrnam("_locationd").gr_gid)
    os.chmod(tmp, 0o600)
os.replace(tmp, path)
print(f"removed={len(remove_keys)}")
PY
}

apply_siri_location_icon_fix() {
  [[ "\$SIRI_LOCATION_ICON_MODE" == "1" ]] || return 0
  [[ -f "\$SIRI_LOCATIOND_PATCH" ]] || return 0
  /usr/bin/killall lldb debugserver 2>/dev/null || true
  /usr/bin/killall locationd 2>/dev/null || true
  /bin/sleep 1
  clean_siri_location_rows_for_icon_fix || true
  /bin/launchctl kickstart -k system/com.apple.locationd 2>/dev/null || true
  /bin/sleep 3
  local locationd_pid
  locationd_pid="\$(/usr/bin/pgrep -x locationd | /usr/bin/head -1 || true)"
  if [[ -n "\$locationd_pid" ]]; then
    /usr/bin/lldb --batch -p "\$locationd_pid" \
      -o "command script import \"\$SIRI_LOCATIOND_PATCH\"" \
      -o 'process detach' -o quit || true
  fi
  clean_siri_location_rows_for_icon_fix || true
  /usr/bin/killall "System Settings" SecurityPrivacyExtension cfprefsd iconservicesagent IconServicesAgent 2>/dev/null || true
}


{
  echo "==== \$(date) ===="
  echo "-- before --"
  /usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice | /usr/bin/grep -Ei '"region-info"|"country-of-origin"' || true

  if ! /usr/bin/kmutil showloaded 2>/dev/null | /usr/bin/grep -qi 'Codex\\|RegionSpoof'; then
    echo "loading \$KEXT"
    /usr/bin/kmutil load -p "\$KEXT" || true
  fi

  for i in 1 2 3 4 5 6 7 8; do
    /usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | /usr/bin/grep -qi '4c4c2f41' && break
    /bin/sleep 1
  done

  echo "-- after --"
  /usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice | /usr/bin/grep -Ei '"region-info"|"country-of-origin"' || true
  /usr/bin/kmutil showloaded 2>/dev/null | /usr/bin/grep -Ei 'Codex|RegionSpoof' || true

  write_geoservices
  apply_siri_location_icon_fix

  echo "refreshing region and AI daemons"
  /usr/bin/killall eligibilityd generativeexperiencesd modelcatalogd modelmanagerd countryd locationd geod routined 2>/dev/null || true
  /bin/launchctl kickstart -k system/com.apple.eligibilityd 2>/dev/null || true
  /bin/launchctl kickstart -k system/com.apple.modelcatalogd 2>/dev/null || true
  /bin/launchctl kickstart -k system/com.apple.modelmanagerd 2>/dev/null || true
} >> "\$LOG" 2>&1

exit 0
EOF
  /usr/sbin/chown root:wheel "$LOADER_SCRIPT"
  /bin/chmod 755 "$LOADER_SCRIPT"
}

install_launchdaemon() {
  section "Install boot-time loader"
  [[ "$SKIP_SIRI_LOCATION_ICON" == "0" ]] && write_siri_location_icon_patch_payload
  write_loader_script

  /bin/cat > "$LOADER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.codex.region-spoof-loader</string>
  <key>ProgramArguments</key>
  <array>
    <string>$LOADER_SCRIPT</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/var/log/codex-region-spoof-loader.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>/var/log/codex-region-spoof-loader.stderr.log</string>
</dict>
</plist>
EOF
  /usr/sbin/chown root:wheel "$LOADER_PLIST"
  /bin/chmod 644 "$LOADER_PLIST"

  /bin/launchctl bootout system "$LOADER_PLIST" 2>/dev/null || true
  /bin/launchctl bootstrap system "$LOADER_PLIST" 2>/dev/null || true
  /bin/launchctl kickstart -k system/local.codex.region-spoof-loader 2>/dev/null || true

  ok "installed and started $LOADER_PLIST"
  log "Log: /var/log/codex-region-spoof-loader.log"
}

ensure_domain() {
  local plist="$1"
  local domain="$2"

  ensure_plist_file "$plist"
  pb "Print :${domain}" "$plist" >/dev/null 2>&1 || pb "Add :${domain} dict" "$plist"

  pb "Print :${domain}:os_eligibility_answer_source_t" "$plist" >/dev/null 2>&1 \
    && pb "Set :${domain}:os_eligibility_answer_source_t 1" "$plist" \
    || pb "Add :${domain}:os_eligibility_answer_source_t integer 1" "$plist"

  pb "Print :${domain}:os_eligibility_answer_t" "$plist" >/dev/null 2>&1 \
    && pb "Set :${domain}:os_eligibility_answer_t 4" "$plist" \
    || pb "Add :${domain}:os_eligibility_answer_t integer 4" "$plist"

  pb "Print :${domain}:status" "$plist" >/dev/null 2>&1 || pb "Add :${domain}:status dict" "$plist"
}

set_status() {
  local plist="$1"
  local domain="$2"
  local input="$3"
  pb "Print :${domain}:status:${input}" "$plist" >/dev/null 2>&1 \
    && pb "Set :${domain}:status:${input} 3" "$plist" \
    || pb "Add :${domain}:status:${input} integer 3" "$plist"
}

patch_domain() {
  local plist="$1"
  local domain="$2"
  ensure_domain "$plist" "$domain"

  local inputs=(
    OS_ELIGIBILITY_INPUT_COUNTRY_BILLING
    OS_ELIGIBILITY_INPUT_COUNTRY_LOCATION
    OS_ELIGIBILITY_INPUT_DEVICE_AND_SIRI_LANGUAGE_MATCH
    OS_ELIGIBILITY_INPUT_DEVICE_CLASS
    OS_ELIGIBILITY_INPUT_DEVICE_LANGUAGE
    OS_ELIGIBILITY_INPUT_DEVICE_REGION_CODE
    OS_ELIGIBILITY_INPUT_EXTERNAL_BOOT_DRIVE
    OS_ELIGIBILITY_INPUT_GENERATIVE_MODEL_SYSTEM
    OS_ELIGIBILITY_INPUT_SHARED_IPAD
    OS_ELIGIBILITY_INPUT_SIRI_LANGUAGE
  )

  local input
  for input in "${inputs[@]}"; do
    set_status "$plist" "$domain" "$input"
  done
}

patch_eligibility_domains() {
  section "Patch eligibility domains"
  local backup_dir="$ELIGIBILITY_BACKUP_BASE/force-ai-domains-$(/bin/date +%Y%m%d-%H%M%S)"
  /bin/mkdir -p "$backup_dir"

  for plist in "$ELIGIBILITYD_PLIST" "$OS_ELIGIBILITY_PLIST"; do
    [[ -e "$plist" ]] && /bin/cp -p "$plist" "$backup_dir/$(basename "$(dirname "$plist")")-$(basename "$plist")"
    unlock_file "$plist"
    ensure_plist_file "$plist"
  done

  local domain
  for domain in "${ELIGIBILITYD_DOMAINS[@]}"; do
    log "  $domain -> ELIGIBLE"
    patch_domain "$ELIGIBILITYD_PLIST" "$domain"
  done
  for domain in "${OS_ELIGIBILITY_DOMAINS[@]}"; do
    log "  $domain -> ELIGIBLE"
    patch_domain "$OS_ELIGIBILITY_PLIST" "$domain"
  done

  lock_file_eligibility "$ELIGIBILITYD_PLIST"
  lock_file_eligibility "$OS_ELIGIBILITY_PLIST"

  /bin/launchctl kickstart -k system/com.apple.eligibilityd 2>/dev/null || /usr/bin/killall eligibilityd 2>/dev/null || true
  /usr/bin/notifyutil -p com.apple.os-eligibility-domain.change.greymatter 2>/dev/null || true
  /usr/bin/notifyutil -p com.apple.os-eligibility-domain.change.foundation-models 2>/dev/null || true
  ok "eligibility domains patched; backup: $backup_dir"
}

force_siri_sae() {
  section "Force Siri SAE orchestration"
  if [[ -z "$CONSOLE_USER" ]]; then
    warn "No console user found; skipping user SiriAvailability"
    return 0
  fi

  as_console_user /usr/bin/killall cfprefsd 2>/dev/null || true
  as_console_user /usr/bin/python3 - "$CONSOLE_HOME/Library/Preferences/${SIRI_DOMAIN}.plist" "$SIRI_KEY" <<'PY'
import os
import plistlib
import sys

path, key = sys.argv[1:3]
os.makedirs(os.path.dirname(path), exist_ok=True)

if os.path.exists(path):
    try:
        with open(path, "rb") as f:
            data = plistlib.load(f)
    except Exception:
        data = {}
else:
    data = {}

if not isinstance(data, dict):
    data = {}

data[key] = {
    "isAvailable": True,
    "siriLocale": "en-US",
    "desiredOrchestrationMode": 4,
    "unavailabilityReasons": 0,
    "allCapabilities": {
        "fullUODCapabilities": 15,
        "hybridCapabilities": 9,
        "saeCapabilities": 7,
    },
}

tmp = f"{path}.codex-tmp"
with open(tmp, "wb") as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
os.replace(tmp, path)
PY

  as_console_user /usr/bin/killall cfprefsd SiriNCService Siri SystemUIServer Dock 2>/dev/null || true
  ok "Siri SAE availability preference written for $CONSOLE_USER"
  as_console_user /usr/bin/defaults read "$SIRI_DOMAIN" "$SIRI_KEY" 2>/dev/null || true
}

detect_geo() {
  if [[ "$FORCE_GEOSERVICES_US" == "1" ]]; then
    GEO_IP_CC="US"; GEO_IP_ADDR="forced"; GEO_IP_CITY="forced"; GEO_IP_REGION="forced"; GEO_IP_LOC="forced"
    return 0
  fi
  local json cc ip city region loc
  json="$(/usr/bin/curl -s --max-time 8 https://ipinfo.io/json 2>/dev/null || true)"
  if [[ -n "$json" ]]; then
    cc="$(printf '%s' "$json" | /usr/bin/python3 -c 'import json,sys; print((json.load(sys.stdin).get("country") or "").upper())' 2>/dev/null || true)"
    ip="$(printf '%s' "$json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("ip",""))' 2>/dev/null || true)"
    city="$(printf '%s' "$json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("city",""))' 2>/dev/null || true)"
    region="$(printf '%s' "$json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("region",""))' 2>/dev/null || true)"
    loc="$(printf '%s' "$json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("loc",""))' 2>/dev/null || true)"
  fi
  GEO_IP_CC="${cc:-US}"
  GEO_IP_ADDR="${ip:-unknown}"
  GEO_IP_CITY="${city:-unknown}"
  GEO_IP_REGION="${region:-unknown}"
  GEO_IP_LOC="${loc:-unknown}"
}

write_geoservices_country() {
  section "Set GeoServices country"
  detect_geo
  local source_note="set from current public IP geolocation"
  [[ "$FORCE_GEOSERVICES_US" == "1" ]] && source_note="forced to US by --force-geoservices-us"

  local backup_dir="/private/var/db/locationd_cache_backup/geo-${GEO_IP_CC}-$(/bin/date +%Y%m%d-%H%M%S)"
  /bin/mkdir -p "$GEOSERVICES_DIR" "$backup_dir"
  [[ -e "$GEOSERVICES_DIRECT_STORE" ]] && /bin/cp -p "$GEOSERVICES_DIRECT_STORE" "$backup_dir/DirectReadConfigStore.plist.before"

  /usr/bin/python3 - "$GEOSERVICES_DIRECT_STORE" "$GEO_IP_CC" "$GEO_IP_ADDR" "$GEO_IP_CITY" "$GEO_IP_REGION" "$GEO_IP_LOC" "$source_note" <<'PY'
import plistlib
import sys
path, cc, ip, city, region, loc, source_note = sys.argv[1:8]
payload = {
    "DeviceCountryCodeSourced": {
        "cc": cc,
        "metadata": {
            "sourceNote": source_note,
            "ip": ip,
            "city": city,
            "region": region,
            "loc": loc,
        },
        "source": 262,
    }
}
with open(path, "wb") as f:
    plistlib.dump(payload, f)
PY
  /usr/sbin/chown _locationd:_locationd "$GEOSERVICES_DIRECT_STORE" 2>/dev/null || true
  /bin/chmod 0644 "$GEOSERVICES_DIRECT_STORE" 2>/dev/null || true
  /usr/bin/killall locationd geod routined Maps Weather CoreLocationAgent 2>/dev/null || true

  ok "GeoServices country set to $GEO_IP_CC"
  note "IP source: $GEO_IP_ADDR, $GEO_IP_CITY, $GEO_IP_REGION, $GEO_IP_LOC"
  note "Backup: $backup_dir"
}

force_countryd_us() {
  section "Force countryd cache to US"
  if [[ ! -e "$COUNTRYD_PLIST" ]]; then
    warn "$COUNTRYD_PLIST not found; skipping"
    return 0
  fi

  local backup_dir="$COUNTRYD_BACKUP_BASE/force-us-$(/bin/date +%Y%m%d-%H%M%S)"
  /bin/mkdir -p "$backup_dir"
  /bin/cp -p "$COUNTRYD_PLIST" "$backup_dir/countryCodeCache.plist.before"
  unlock_file "$COUNTRYD_PLIST"
  /bin/chmod 0644 "$COUNTRYD_PLIST" 2>/dev/null || true

  /usr/bin/python3 - "$COUNTRYD_PLIST" <<'PY'
import os
import plistlib
import sys
path = sys.argv[1]
with open(path, "rb") as f:
    data = plistlib.load(f)
changed = 0
def force_us(value):
    global changed
    if isinstance(value, dict):
        return {key: force_us(item) for key, item in value.items()}
    if isinstance(value, list):
        return [force_us(item) for item in value]
    if isinstance(value, str) and len(value) == 2 and value.isalpha() and value.isupper():
        changed += value != "US"
        return "US"
    return value
data = force_us(data)
tmp = f"{path}.codex-tmp"
with open(tmp, "wb") as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
stat = os.stat(path)
os.chown(tmp, stat.st_uid, stat.st_gid)
os.chmod(tmp, 0o644)
os.replace(tmp, path)
print(f"changed={changed}")
PY

  /bin/chmod 0444 "$COUNTRYD_PLIST" 2>/dev/null || true
  /usr/bin/chflags uchg "$COUNTRYD_PLIST" 2>/dev/null || true
  /usr/bin/killall countryd 2>/dev/null || true
  ok "countryd cache forced to US; backup: $backup_dir"
}

find_system_volume_device() {
  local root_dev sys_dev
  root_dev="$(/sbin/mount | /usr/bin/awk '$3 == "/" {print $1; exit}')"
  [[ -n "$root_dev" ]] || die "Could not determine root APFS snapshot device"
  sys_dev="$(printf '%s' "$root_dev" | /usr/bin/sed -E 's/(s[0-9]+)s[0-9]+$/\1/')"
  echo "$sys_dev"
}

mount_system_rw() {
  local sys_dev
  sys_dev="$(find_system_volume_device)"
  /bin/mkdir -p "$SYSTEM_RW_MNT"
  if ! /sbin/mount | /usr/bin/grep -q " on ${SYSTEM_RW_MNT} "; then
    log "Mounting System volume read-write: $sys_dev -> $SYSTEM_RW_MNT"
    /sbin/mount -t apfs -o nobrowse,rw "$sys_dev" "$SYSTEM_RW_MNT"
  fi
}

apple_internal_enabled() {
  [[ -f "$1" ]] || return 1
  pb 'Print :AppleInternal' "$1" 2>/dev/null | /usr/bin/grep -qi true
}

install_apple_internal_variant() {
  section "AppleInternalVariant marker"
  local major mounted_plist backup_dir
  major="$(macos_major_version)"
  if (( major < 27 )); then
    log "macOS major version is $major; skipping macOS 27-only AppleInternalVariant marker."
    return 0
  fi
  if apple_internal_enabled "$APPLE_INTERNAL_VARIANT_PLIST"; then
    ok "live root already has AppleInternalVariant enabled"
    return 0
  fi
  if ! /usr/bin/csrutil authenticated-root status 2>/dev/null | /usr/bin/grep -qi disabled; then
    cat >&2 <<'MSG'
AppleInternalVariant.plist must be written into the sealed System volume.
Authenticated Root is enabled, so this step cannot continue.

Boot to Recovery and run:

  csrutil disable
  csrutil authenticated-root disable

Then boot macOS and rerun this script.
MSG
    exit 1
  fi

  backup_dir="$APPLE_INTERNAL_VARIANT_BACKUP_BASE/backup-$(/bin/date +%Y%m%d-%H%M%S)"
  mounted_plist="${SYSTEM_RW_MNT}${APPLE_INTERNAL_VARIANT_PLIST}"
  /bin/mkdir -p "$backup_dir"

  mount_system_rw
  [[ -e "$mounted_plist" ]] && /bin/cp -p "$mounted_plist" "$backup_dir/AppleInternalVariant.snapshot.before"
  /bin/mkdir -p "$(dirname "$mounted_plist")"
  /bin/cat > "$mounted_plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AppleInternal</key>
  <true/>
</dict>
</plist>
PLIST
  /usr/sbin/chown root:wheel "$mounted_plist"
  /bin/chmod 0644 "$mounted_plist"
  /usr/bin/plutil -lint "$mounted_plist"

  /usr/sbin/bless --mount "$SYSTEM_RW_MNT" --create-snapshot --setBoot
  ok "AppleInternalVariant written; reboot required. Backup: $backup_dir"
}

install_macos27_featureflag() {
  section "macOS 27 EnhancedSiriWaitlist FeatureFlags"
  local major backup_dir
  major="$(macos_major_version)"
  if (( major < 27 )); then
    log "macOS major version is $major; skipping macOS 27-only FeatureFlags override."
    return 0
  fi

  backup_dir="$FEATUREFLAGS_BACKUP_BASE/generative-models-$(/bin/date +%Y%m%d-%H%M%S)"
  /bin/mkdir -p "$FEATUREFLAGS_OVERRIDE_DIR" "$backup_dir"
  [[ -e "$SYSTEM_GM_FEATUREFLAGS_PLIST" ]] && /bin/cp -p "$SYSTEM_GM_FEATUREFLAGS_PLIST" "$backup_dir/System.GenerativeModels.plist.before" 2>/dev/null || true
  [[ -e "$GM_FEATUREFLAGS_OVERRIDE_PLIST" ]] && /bin/cp -p "$GM_FEATUREFLAGS_OVERRIDE_PLIST" "$backup_dir/Library.GenerativeModels.plist.before" 2>/dev/null || true

  /usr/bin/python3 - "$GM_FEATUREFLAGS_OVERRIDE_PLIST" <<'PY'
import os
import plistlib
import sys
path = sys.argv[1]
if os.path.exists(path):
    with open(path, "rb") as f:
        data = plistlib.load(f)
else:
    data = {}
if not isinstance(data, dict):
    data = {}
entry = data.get("EnhancedSiriWaitlist")
if not isinstance(entry, dict):
    entry = {}
entry["Enabled"] = False
data["EnhancedSiriWaitlist"] = entry
tmp = f"{path}.codex-tmp"
with open(tmp, "wb") as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
os.replace(tmp, path)
PY
  /usr/sbin/chown root:wheel "$GM_FEATUREFLAGS_OVERRIDE_PLIST"
  /bin/chmod 0644 "$GM_FEATUREFLAGS_OVERRIDE_PLIST"
  ok "FeatureFlags override installed; backup: $backup_dir"
}

mirror_siri_availability_to_appleidsettings() {
  [[ -n "$CONSOLE_USER" ]] || return 0
  section "Mirror SiriAvailability to AppleIDSettings"

  local src="$CONSOLE_HOME/Library/Preferences/${SIRI_DOMAIN}.plist"
  local dst="$CONSOLE_HOME/Library/Containers/com.apple.systempreferences.AppleIDSettings/Data/Library/Preferences/${SIRI_DOMAIN}.plist"
  local backup_dir="$CONSOLE_HOME/Documents/Codex/appleidsettings-siri-availability-backups/$(/bin/date +%Y%m%d-%H%M%S)"

  if [[ ! -f "$src" ]]; then
    warn "Missing $src; skipping AppleIDSettings mirror"
    return 0
  fi

  /bin/mkdir -p "$(dirname "$dst")" "$backup_dir"
  [[ -f "$dst" ]] && /bin/cp -p "$dst" "$backup_dir/${SIRI_DOMAIN}.plist.before"
  /bin/cp -p "$src" "$dst"
  /usr/sbin/chown "$CONSOLE_USER":staff "$dst" 2>/dev/null || true
  /bin/chmod 600 "$dst" 2>/dev/null || true
  /usr/bin/plutil -lint "$dst" >/dev/null
  ok "mirrored SiriAvailability into AppleIDSettings container"
}

force_web_search_provider_google() {
  section "Normalize Siri/Safari web search provider"
  [[ -n "$CONSOLE_USER" ]] || { warn "No console user found; skipping web search provider"; return 0; }

  as_console_user /usr/bin/defaults write NSGlobalDomain NSWebServicesProviderWebSearch -dict \
    NSDefaultDisplayName Google \
    NSProviderIdentifier com.google.www \
    NSProviderIdentifier2 com.google.www

  /usr/bin/python3 - "$CONSOLE_HOME" <<'PY'
import os
import plistlib
import shutil
import sys
import time

home = sys.argv[1]
paths = [
    os.path.join(home, "Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist"),
    os.path.join(home, "Library/Preferences/com.apple.Safari.plist"),
]

for path in paths:
    if not os.path.exists(path):
        continue
    try:
        with open(path, "rb") as f:
            data = plistlib.load(f)
    except Exception as exc:
        print(f"{path}: read failed: {exc}")
        continue
    recent = data.get("RecentWebSearches")
    if not isinstance(recent, list):
        print(f"{path}: no RecentWebSearches")
        continue
    kept = [item for item in recent if "baidu" not in str(item).lower()]
    removed = len(recent) - len(kept)
    if removed == 0:
        print(f"{path}: removed stale Baidu searches=0")
        continue
    backup = f"{path}.backup-codex-baidu-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, backup)
    data["RecentWebSearches"] = kept
    tmp = f"{path}.codex-tmp"
    with open(tmp, "wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
    stat = os.stat(path)
    os.chown(tmp, stat.st_uid, stat.st_gid)
    os.chmod(tmp, stat.st_mode & 0o7777)
    os.replace(tmp, path)
    print(f"{path}: removed stale Baidu searches={removed}, backup={backup}")
PY

  as_console_user /usr/bin/killall cfprefsd Safari assistantd SiriNCService Siri 2>/dev/null || true
  as_console_user /usr/bin/defaults read NSGlobalDomain NSWebServicesProviderWebSearch 2>/dev/null || true
}

restore_siri_menu_bar_extra() {
  [[ -n "$CONSOLE_USER" ]] || return 0
  section "Restore Siri menu bar extra"
  as_console_user /usr/bin/defaults write com.apple.systemuiserver menuExtras -array /System/Library/CoreServices/Siri.bundle
  as_console_user /usr/bin/killall SystemUIServer 2>/dev/null || true
}

refresh_siri_icon_identity() {
  section "Refresh Siri icon identity"
  [[ -n "$CONSOLE_USER" ]] || { warn "No console user found; skipping Siri icon refresh"; return 0; }

  mirror_siri_availability_to_appleidsettings

  local backup_dir="$CONSOLE_HOME/Documents/Codex/siri-icon-source-backups/$(/bin/date +%Y%m%d-%H%M%S)"
  local probe_log="$backup_dir/iconservices-probe.txt"
  /bin/mkdir -p "$backup_dir"
  /bin/cp "$SIRI_SYSTEM_APP/Contents/Info.plist" "$backup_dir/SystemApplications.Siri.Info.plist.live" 2>/dev/null || true
  /bin/cp "$SIRI_CORESERVICES_APP/Contents/Info.plist" "$backup_dir/CoreServices.Siri.Info.plist.live" 2>/dev/null || true

  log "-- Siri identity sources --"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SIRI_SYSTEM_APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$SIRI_SYSTEM_APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$SIRI_SYSTEM_APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SIRI_CORESERVICES_APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$SIRI_CORESERVICES_APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$SIRI_CORESERVICES_APP/Contents/Info.plist" 2>/dev/null || true

  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -kill -r -domain local -domain system -domain user >/dev/null 2>&1 || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$SIRI_SYSTEM_APP" >/dev/null 2>&1 || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$SIRI_CORESERVICES_APP" >/dev/null 2>&1 || true
  /usr/bin/mdimport "$SIRI_SYSTEM_APP" >/dev/null 2>&1 || true
  /usr/bin/mdimport "$SIRI_CORESERVICES_APP" >/dev/null 2>&1 || true
  /usr/bin/qlmanage -r cache >/dev/null 2>&1 || true
  as_console_user /usr/bin/killall iconservicesagent IconServicesAgent Dock "System Settings" AppleIDSettings cfprefsd 2>/dev/null || true

  as_console_user /usr/bin/swift - > "$probe_log" <<'SWIFT' || true
import AppKit

let paths = [
    "/System/Library/CoreServices/Siri.app",
    "/System/Applications/Siri.app"
]

var ok = false
for path in paths {
    let image = NSWorkspace.shared.icon(forFile: path)
    let text = String(describing: image)
    print("provider icon for \(path): \(text)")
    if text.contains("com.apple.application-icon.siri-intelligence") {
        ok = true
    }
}

exit(ok ? 0 : 2)
SWIFT

  /bin/cat "$probe_log" 2>/dev/null || true
  if ! /usr/bin/grep -q 'com.apple.application-icon.siri-intelligence' "$probe_log" 2>/dev/null; then
    warn "IconServices did not report siri-intelligence yet. Reboot/relogin and verify Apple Intelligence availability first."
  fi
  log "Backup: $backup_dir"
}

refresh_ai_daemons() {
  section "Refresh AI daemons"
  /usr/bin/killall eligibilityd generativeexperiencesd modelcatalogd modelmanagerd 2>/dev/null || true
  /bin/launchctl kickstart -k system/com.apple.eligibilityd 2>/dev/null || true
  /bin/launchctl kickstart -k system/com.apple.modelcatalogd 2>/dev/null || true
  /bin/launchctl kickstart -k system/com.apple.modelmanagerd 2>/dev/null || true
  [[ -n "$CONSOLE_USER" ]] && as_console_user /usr/bin/killall "System Settings" SiriPreferenceExtension SiriNCService Siri cfprefsd 2>/dev/null || true
}

run_status() {
  banner "status"
  print_compact_status
  section "Detailed diagnostics"
  kv "Script" "$SELF"
  print_sip_state
  print_boot_policy
  print_root_identity
  print_kext_state
  print_eligibility_answers
  print_country_state
  print_macos27_state
  print_siri_state
}

run_install() {
  banner "install"
  preflight_install

  [[ "$SKIP_KEXT" == "0" ]] && install_kext
  [[ "$SKIP_LAUNCHDAEMON" == "0" ]] && install_launchdaemon
  [[ "$SKIP_ELIGIBILITY" == "0" ]] && patch_eligibility_domains
  [[ "$SKIP_SAE" == "0" ]] && force_siri_sae
  [[ "$SKIP_GEOSERVICES" == "0" ]] && write_geoservices_country
  [[ "$SKIP_COUNTRYD" == "0" ]] && force_countryd_us
  [[ "$SKIP_APPLE_INTERNAL" == "0" ]] && install_apple_internal_variant
  [[ "$SKIP_MACOS27_SIRI_AI" == "0" ]] && install_macos27_featureflag
  [[ "$SKIP_WEB_SEARCH" == "0" ]] && force_web_search_provider_google
  [[ "$SKIP_SIRI_LOCATION_ICON" == "0" ]] && apply_siri_location_icon_runtime_fix_now
  refresh_ai_daemons
  restore_siri_menu_bar_extra
  [[ "$DO_ICON_FIX" == "1" ]] && refresh_siri_icon_identity

  print_compact_status
  section "Result"
  cat <<'MSG'
[OK] Core steps finished.

Reboot after the first successful run, especially if:
  - you just allowed the kext in Privacy & Security
  - AMFI boot-args were removed
  - AppleInternalVariant was written on macOS 27+
  - AI assets are still downloading

After everything works, the recommended higher-security recovery setting is:
  csrutil authenticated-root enable
  FileVault on

Do not run csrutil enable while relying on this ad-hoc kext.
MSG
}

backup_for_uninstall() {
  BACKUP_ROOT="$CONSOLE_HOME/Documents/Codex/enableAppleIntelligence-restore-backups/$(/bin/date +%Y%m%d-%H%M%S)"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "Dry run backup root would be: $BACKUP_ROOT"
    return 0
  fi
  /bin/mkdir -p "$BACKUP_ROOT"
  for p in "$KEXT_DST" "$LOADER_SCRIPT" "$LOADER_PLIST" "$SIRI_LOCATION_FIX_DIR" "$ELIGIBILITYD_PLIST" "$OS_ELIGIBILITY_PLIST" "$COUNTRYD_PLIST" "$GEOSERVICES_DIRECT_STORE" "$GM_FEATUREFLAGS_OVERRIDE_PLIST"; do
    [[ -e "$p" ]] || continue
    /bin/mkdir -p "$BACKUP_ROOT$(dirname "$p")"
    /bin/cp -a "$p" "$BACKUP_ROOT$p" 2>/dev/null || true
  done
  run_status > "$BACKUP_ROOT/status-before.txt" 2>&1 || true
  log "Backup: $BACKUP_ROOT"
}

do_or_print() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ $*"
  else
    "$@"
  fi
}

remove_apple_internal_variant() {
  section "Remove AppleInternalVariant marker"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ remove $APPLE_INTERNAL_VARIANT_PLIST from mounted System volume and bless new snapshot"
    return 0
  fi
  if ! /usr/bin/csrutil authenticated-root status 2>/dev/null | /usr/bin/grep -qi disabled; then
    warn "Authenticated Root is enabled; skipping sealed-system AppleInternalVariant removal."
    warn "To remove it, boot Recovery, run csrutil authenticated-root disable, boot back, rerun uninstall."
    return 0
  fi
  local mounted_plist="${SYSTEM_RW_MNT}${APPLE_INTERNAL_VARIANT_PLIST}"
  mount_system_rw
  if [[ -e "$mounted_plist" ]]; then
    /bin/rm -f "$mounted_plist"
    /usr/sbin/bless --mount "$SYSTEM_RW_MNT" --create-snapshot --setBoot
    ok "removed AppleInternalVariant from new boot snapshot; reboot required"
  else
    log "$mounted_plist not present"
  fi
}

run_uninstall() {
  banner "uninstall"
  section "Uninstall / restore"
  backup_for_uninstall

  do_or_print /bin/launchctl bootout system "$LOADER_PLIST" 2>/dev/null || true
  do_or_print /bin/rm -f "$LOADER_PLIST" "$LOADER_SCRIPT"
  do_or_print /bin/rm -rf "$SIRI_LOCATION_FIX_DIR"

  if [[ -d "$KEXT_DST" ]]; then
    do_or_print /usr/bin/kmutil unload -p "$KEXT_DST" 2>/dev/null || true
    do_or_print /bin/rm -rf "$KEXT_DST"
  fi

  for plist in "$ELIGIBILITYD_PLIST" "$OS_ELIGIBILITY_PLIST" "$COUNTRYD_PLIST"; do
    [[ -e "$plist" ]] || continue
    do_or_print /usr/bin/chflags nouchg "$plist" 2>/dev/null || true
  done
  for plist in "$ELIGIBILITYD_PLIST" "$OS_ELIGIBILITY_PLIST"; do
    [[ -e "$plist" ]] && do_or_print /bin/rm -f "$plist"
  done

  [[ -e "$GM_FEATUREFLAGS_OVERRIDE_PLIST" ]] && do_or_print /bin/rm -f "$GM_FEATUREFLAGS_OVERRIDE_PLIST"
  remove_apple_internal_variant

  if [[ -n "$CONSOLE_USER" ]]; then
    do_or_print as_console_user /usr/bin/defaults delete "$SIRI_DOMAIN" "$SIRI_KEY" 2>/dev/null || true
  fi

  do_or_print /usr/bin/killall eligibilityd generativeexperiencesd modelcatalogd modelmanagerd countryd locationd 2>/dev/null || true
  run_status

  section "Next steps"
  log "Reboot. If you want full stock security back, set Full Security, csrutil enable, and csrutil authenticated-root enable in Recovery."
}

case "$ACTION" in
  install)
    run_install
    ;;
  status)
    run_status
    ;;
  icon)
    banner "Siri icon refresh"
    refresh_siri_icon_identity
    print_compact_status
    ;;
  uninstall)
    run_uninstall
    ;;
  *)
    usage
    exit 2
    ;;
esac
