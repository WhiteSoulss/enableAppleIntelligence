#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

DO_ICON_FIX=0
DO_INSTALL_LAUNCHDAEMON=1
DO_LOAD_KEXT=1
DO_ELIGIBILITY=1
DO_SAE=1
DO_LOCATION_IP_FIX=1
FORCE_GEOSERVICES_US=0
DO_SIRI_LOCATION_ICON_RUNTIME_FIX=1
DO_WEB_SEARCH_FIX=1
DO_VERIFY_ONLY=0
DO_UNINSTALL=0
DO_UNINSTALL_DRY_RUN=0
DO_ICON_ONLY=0

KEXT="/Library/Extensions/CodexRegionSpoof.kext"
LOCAL_KEXT="$ROOT_DIR/tools/CodexRegionSpoof.kext"
LOCAL_KEXT_BIN="$LOCAL_KEXT/Contents/MacOS/CodexRegionSpoof"
LOCAL_KEXT_BIN_B64="$LOCAL_KEXT/Contents/MacOS/CodexRegionSpoof.b64"
LOADER_SCRIPT="/Library/Scripts/Codex/load-region-spoof.sh"
LOADER_PLIST="/Library/LaunchDaemons/local.codex.region-spoof-loader.plist"
SIRI_LOCATION_FIX_DIR="/Library/Scripts/Codex/SiriLocationIconFix"
SIRI_LOCATION_FIX_AGENT="$HOME/Library/LaunchAgents/local.codex.siri-location-icon-fix.plist"
GEOSERVICES_DIR="/var/db/locationd/Library/Caches/GeoServices"
GEOSERVICES_DIRECT_STORE="${GEOSERVICES_DIR}/DirectReadConfigStore.plist"

ELIGIBILITYD_PLIST="/private/var/db/eligibilityd/eligibility.plist"
OS_ELIGIBILITY_PLIST="/private/var/db/os_eligibility/eligibility.plist"
ELIGIBILITY_BACKUP_BASE="/private/var/db/eligibilityd_source_backup"
UNINSTALL_BACKUP_ROOT="$HOME/Documents/Codex/enableAppleIntelligence-restore-backups/$(date +%Y%m%d-%H%M%S)"

SIRI_DOMAIN="com.apple.assistant.backedup"
SIRI_KEY="SiriAvailability"
SIRI_PREF="$HOME/Library/Preferences/${SIRI_DOMAIN}.plist"
APPLEID_SETTINGS_SIRI_PREF="$HOME/Library/Containers/com.apple.systempreferences.AppleIDSettings/Data/Library/Preferences/${SIRI_DOMAIN}.plist"
SIRI_SYSTEM_APP="/System/Applications/Siri.app"
SIRI_CORESERVICES_APP="/System/Library/CoreServices/Siri.app"

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
  --all                 Run core enable steps and refresh the Siri icon identity.
  --fix-siri-icon       Refresh/verify the Siri icon identity only.
                        Uses Apple's built-in IconServices
                        com.apple.application-icon.siri-intelligence asset.
  --verify-only         Only print current state; do not change anything.
  --uninstall           Back up local state, remove kext/LaunchDaemon, clear forced caches.
  --dry-run             With --uninstall, print restore actions without changing anything.
  --skip-kext           Do not load CodexRegionSpoof.kext this run.
  --skip-launchdaemon   Do not install/update the boot-time kext loader.
  --skip-eligibility    Do not patch eligibility plists.
  --skip-sae            Do not force Siri SAE orchestration preference.
  --skip-location-ip    Do not set GeoServices location country from public IP.
  --force-geoservices-us
                        Force GeoServices location country cache to US instead
                        of using the current public IP exit country.
  --skip-siri-location-icon
                        Do not integrate the Location Services Siri icon runtime fix.
  --skip-web-search     Do not normalize the Siri/Safari web search provider to Google.
  -h, --help            Show this help.

Recovery prerequisites:
  1. csrutil disable
  2. csrutil authenticated-root disable
  3. Startup Security Utility -> Reduced Security -> allow kernel extensions
  4. tools/CodexRegionSpoof.kext present in this repository, or already
     installed at /Library/Extensions/CodexRegionSpoof.kext

What this single script does:
  - verifies SIP / SSV / root IORegistry region state
  - installs/loads the kernel-side region-info / country-of-origin spoof kext
  - installs a boot-time LaunchDaemon to reload that kext
  - patches Apple Intelligence eligibility domains to answer_t = 4
  - forces Siri SAE orchestration mode
  - sets GeoServices location country from the current public IP exit country
    or forces it to US with --force-geoservices-us
  - integrates the Location Services Siri icon fix into load-region-spoof.sh
  - normalizes the Siri/Safari web search provider to Google
  - refreshes affected availability clients
  - refreshes the Siri icon identity cache used by com.apple.siri

Core steps use normal sudo prompting. The Siri Location Services icon runtime
fix is applied once now and then re-applied by the existing boot-time
load-region-spoof.sh flow after reboot.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      DO_ICON_FIX=1
      ;;
    --fix-siri-icon)
      DO_ICON_FIX=1
      DO_ICON_ONLY=1
      DO_LOAD_KEXT=0
      DO_INSTALL_LAUNCHDAEMON=0
      DO_ELIGIBILITY=0
      DO_SAE=0
      DO_LOCATION_IP_FIX=0
      DO_SIRI_LOCATION_ICON_RUNTIME_FIX=0
      DO_WEB_SEARCH_FIX=0
      ;;
    --verify-only)
      DO_VERIFY_ONLY=1
      DO_LOAD_KEXT=0
      DO_INSTALL_LAUNCHDAEMON=0
      DO_ELIGIBILITY=0
      DO_SAE=0
      DO_LOCATION_IP_FIX=0
      DO_ICON_FIX=0
      DO_WEB_SEARCH_FIX=0
      ;;
    --uninstall)
      DO_UNINSTALL=1
      DO_LOAD_KEXT=0
      DO_INSTALL_LAUNCHDAEMON=0
      DO_ELIGIBILITY=0
      DO_SAE=0
      DO_LOCATION_IP_FIX=0
      DO_SIRI_LOCATION_ICON_RUNTIME_FIX=0
      DO_WEB_SEARCH_FIX=0
      DO_ICON_FIX=0
      ;;
    --dry-run)
      DO_UNINSTALL=1
      DO_UNINSTALL_DRY_RUN=1
      DO_LOAD_KEXT=0
      DO_INSTALL_LAUNCHDAEMON=0
      DO_ELIGIBILITY=0
      DO_SAE=0
      DO_LOCATION_IP_FIX=0
      DO_SIRI_LOCATION_ICON_RUNTIME_FIX=0
      DO_WEB_SEARCH_FIX=0
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
    --skip-location-ip|--skip-location-cn)
      DO_LOCATION_IP_FIX=0
      ;;
    --force-geoservices-us|--force-location-us|--force-geo-us)
      DO_LOCATION_IP_FIX=1
      FORCE_GEOSERVICES_US=1
      ;;
    --skip-siri-location-icon)
      DO_SIRI_LOCATION_ICON_RUNTIME_FIX=0
      ;;
    --skip-web-search)
      DO_WEB_SEARCH_FIX=0
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
  local required_path="$1"
  if [[ ! -e "$required_path" ]]; then
    echo "Missing required path: $required_path" >&2
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
  if [[ -n "${SUDO_PASSWORD:-}" ]]; then
    printf '%s\n' "$SUDO_PASSWORD" | sudo -S -v
  else
    sudo -v
  fi
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
  elif [[ -n "${SUDO_PASSWORD:-}" ]]; then
    printf '%s\n' "$SUDO_PASSWORD" | sudo -S "$@"
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

write_siri_location_icon_patch_payload() {
  local locationd_tmp

  locationd_tmp="$(mktemp)"

  cat > "$locationd_tmp" <<'PY'
"""
Runtime patch for the Location Services Siri identity.

The real CoreLocation authorization identity for Siri is
AssistantServices.framework. Its bundle still carries the old siri-osx.icns,
so System Settings shows the old icon even though Apple Intelligence is active.

Keep that authorization identity intact, but rewrite only the display BundlePath
returned by locationd to /System/Applications/Siri.app. Also filter stale rows
created by older experiments, such as com.apple.assistantd or CoreServices/Siri.
"""

import lldb


METHOD = "syncgetCopyClients"
CLASS = "CLClientManagerAdapter"


EXPR = r'''
@import Foundation;
@import ObjectiveC;
Class cdxf_cls=(Class)NSClassFromString(@"CLClientManagerAdapter");
SEL cdxf_sel=(SEL)NSSelectorFromString(@"syncgetCopyClients");
Method cdxf_method=class_getInstanceMethod(cdxf_cls, cdxf_sel);
static id (*cdxf_origCopyClients)(id,SEL) = NULL;
if (cdxf_origCopyClients == NULL) {
  cdxf_origCopyClients=(id(*)(id,SEL))method_getImplementation(cdxf_method);
  id cdxf_block = ^id(id obj) {
    id cdxf_clients = cdxf_origCopyClients(obj, cdxf_sel);
    NSMutableDictionary *cdxf_filtered = [(NSDictionary *)cdxf_clients mutableCopy];
    NSArray *cdxf_keys = [(NSDictionary *)cdxf_clients allKeys];
    for (id cdxf_key in cdxf_keys) {
      id cdxf_val = [(NSDictionary *)cdxf_clients objectForKey:cdxf_key];
      NSString *cdxf_keyLower = [[NSString stringWithFormat:@"%@", cdxf_key] lowercaseString];
      NSString *cdxf_valLower = [[NSString stringWithFormat:@"%@", cdxf_val] lowercaseString];
      BOOL cdxf_isAssistantServices =
        [cdxf_keyLower containsString:@"assistantservices.framework"];

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
@"patched syncgetCopyClients Siri duplicate filter"
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

    print(f"[patch-locationd-siri-filter] patched {CLASS} {METHOD}")
    print(value.GetObjectDescription() or value.GetValue() or "")
PY

  run_root mkdir -p "$SIRI_LOCATION_FIX_DIR"
  run_root rm -f "$SIRI_LOCATION_FIX_DIR/patch_assistant_effective_siri_location_lldb.py"
  run_root install -o root -g wheel -m 644 "$locationd_tmp" "$SIRI_LOCATION_FIX_DIR/patch_locationd_skip_assistantd_association_lldb.py"
  rm -f "$locationd_tmp"
}

install_siri_location_icon_payload() {
  write_siri_location_icon_patch_payload
}

install_region_spoof_launchdaemon() {
  section "Install boot-time kext loader"
  ensure_region_spoof_kext_installed
  install_siri_location_icon_payload

  run_root mkdir -p /Library/Scripts/Codex

  local tmp_script
  tmp_script="$(mktemp)"
  cat > "$tmp_script" <<'EOF'
#!/bin/zsh
set -u

LOG="/var/log/codex-region-spoof-loader.log"
KEXT="/Library/Extensions/CodexRegionSpoof.kext"
SIRI_FIX_DIR="/Library/Scripts/Codex/SiriLocationIconFix"
SIRI_LOCATIOND_PATCH="$SIRI_FIX_DIR/patch_locationd_skip_assistantd_association_lldb.py"
ASSISTANTD_PLIST="/System/Library/LaunchAgents/com.apple.assistantd.plist"
CLIENTS_PLIST="/var/db/locationd/clients.plist"
FORCE_GEOSERVICES_US="__CODEX_FORCE_GEOSERVICES_US__"

console_user() {
  /usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true
}

console_uid() {
  local user="$1"
  /usr/bin/id -u "$user" 2>/dev/null || true
}

clean_siri_location_rows_for_icon_fix() {
  if [[ ! -f "$CLIENTS_PLIST" ]]; then
    echo "Location Services clients plist not present yet; creating empty clients plist: $CLIENTS_PLIST"
  fi

  /usr/bin/python3 - "$CLIENTS_PLIST" <<'PY'
import os
import plistlib
import grp
import pwd
import shutil
import sys
import time

plist_path = sys.argv[1]
if os.path.exists(plist_path):
    with open(plist_path, "rb") as f:
        data = plistlib.load(f)
else:
    data = {}

def is_siri_location_row(key, value):
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

remove_keys = [key for key, value in data.items() if is_siri_location_row(key, value)]

backup = f"{plist_path}.backup-codex-siri-icon-{time.strftime('%Y%m%d-%H%M%S')}"
if os.path.exists(plist_path):
    shutil.copy2(plist_path, backup)
for key in remove_keys:
    data.pop(key, None)

tmp = f"{plist_path}.codex-tmp"
with open(tmp, "wb") as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)

if os.path.exists(plist_path):
    stat = os.stat(plist_path)
    os.chown(tmp, stat.st_uid, stat.st_gid)
    os.chmod(tmp, stat.st_mode & 0o7777)
else:
    os.chown(tmp, pwd.getpwnam("_locationd").pw_uid, grp.getgrnam("_locationd").gr_gid)
    os.chmod(tmp, 0o600)
os.replace(tmp, plist_path)

print(f"backup={backup}")
print(f"removed={len(remove_keys)}")
for key in remove_keys:
    print(f"  {key}")
print("kept natural AssistantServices.framework Siri row if present")
PY
}

apply_siri_location_icon_fix() {
  if [[ ! -f "$SIRI_LOCATIOND_PATCH" ]]; then
    echo "Siri Location icon payload missing under $SIRI_FIX_DIR; skipping"
    return 0
  fi

  local user=""
  local uid=""
  for _ in {1..150}; do
    user="$(console_user)"
    if [[ -n "$user" && "$user" != "root" && "$user" != "loginwindow" ]]; then
      uid="$(console_uid "$user")"
      [[ -n "$uid" ]] && break
    fi
    /bin/sleep 2
  done

  if [[ -z "$uid" ]]; then
    echo "No logged-in console user found; skipping Siri Location icon runtime fix"
    return 0
  fi

  echo "applying Siri Location icon runtime fix for $user uid=$uid"
  /usr/bin/killall lldb debugserver 2>/dev/null || true

  /usr/bin/killall locationd 2>/dev/null || true
  /bin/sleep 1
  clean_siri_location_rows_for_icon_fix || true
  /bin/launchctl kickstart -k system/com.apple.locationd 2>/dev/null || true
  /bin/sleep 3

  local locationd_pid
  locationd_pid="$(/usr/bin/pgrep -x locationd | /usr/bin/head -1 || true)"
  if [[ -n "$locationd_pid" ]]; then
    /usr/bin/lldb --batch -p "$locationd_pid" \
      -o "command script import \"$SIRI_LOCATIOND_PATCH\"" \
      -o 'process detach' -o quit || true
  else
    echo "locationd did not restart before patch attempt"
  fi

  /bin/launchctl bootstrap "gui/$uid" "$ASSISTANTD_PLIST" 2>/dev/null || true
  /bin/launchctl kickstart -k "gui/$uid/com.apple.assistantd" 2>/dev/null || true
  /bin/sleep 3
  clean_siri_location_rows_for_icon_fix || true

  /usr/bin/killall "System Settings" SecurityPrivacyExtension cfprefsd iconservicesagent IconServicesAgent 2>/dev/null || true
}

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

  SOURCE_NOTE="set from current public IP geolocation"
  GEO_CC=""
  GEO_IP=""
  GEO_CITY=""
  GEO_REGION=""
  GEO_LOC=""
  if [ "$FORCE_GEOSERVICES_US" = "1" ]; then
    GEO_CC="US"
    GEO_IP="forced"
    GEO_CITY="forced"
    GEO_REGION="forced"
    GEO_LOC="forced"
    SOURCE_NOTE="forced to US by --force-geoservices-us"
    echo "forcing GeoServices location country cache to US"
  elif /usr/bin/curl -s --max-time 8 https://ipinfo.io/json >/tmp/codex_geo_ip.json 2>/dev/null; then
    echo "setting GeoServices location country cache from public IP"
    GEO_CC="$(/usr/bin/python3 -c 'import json,sys; print((json.load(open("/tmp/codex_geo_ip.json")).get("country") or "").upper())' 2>/dev/null || true)"
    GEO_IP="$(/usr/bin/python3 -c 'import json; print(json.load(open("/tmp/codex_geo_ip.json")).get("ip",""))' 2>/dev/null || true)"
    GEO_CITY="$(/usr/bin/python3 -c 'import json; print(json.load(open("/tmp/codex_geo_ip.json")).get("city",""))' 2>/dev/null || true)"
    GEO_REGION="$(/usr/bin/python3 -c 'import json; print(json.load(open("/tmp/codex_geo_ip.json")).get("region",""))' 2>/dev/null || true)"
    GEO_LOC="$(/usr/bin/python3 -c 'import json; print(json.load(open("/tmp/codex_geo_ip.json")).get("loc",""))' 2>/dev/null || true)"
  fi
  if [ -z "$GEO_CC" ]; then
    GEO_CC="US"
    GEO_IP="unknown"
    GEO_CITY="unknown"
    GEO_REGION="unknown"
    GEO_LOC="unknown"
    echo "public IP lookup failed; falling back to GeoServices country US"
  fi
  /bin/mkdir -p /var/db/locationd/Library/Caches/GeoServices
  /usr/bin/python3 - "$GEO_CC" "$GEO_IP" "$GEO_CITY" "$GEO_REGION" "$GEO_LOC" "$SOURCE_NOTE" <<'PY'
import plistlib
import sys

cc, ip, city, region, loc, source_note = sys.argv[1:7]
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
with open("/var/db/locationd/Library/Caches/GeoServices/DirectReadConfigStore.plist", "wb") as f:
    plistlib.dump(payload, f)
PY
  /bin/rm -f /tmp/codex_geo_ip.json 2>/dev/null || true
  /usr/sbin/chown _locationd:_locationd /var/db/locationd/Library/Caches/GeoServices/DirectReadConfigStore.plist 2>/dev/null || true
  /bin/chmod 0644 /var/db/locationd/Library/Caches/GeoServices/DirectReadConfigStore.plist 2>/dev/null || true
  /usr/bin/killall locationd geod routined 2>/dev/null || true
  apply_siri_location_icon_fix
} >> "$LOG" 2>&1

exit 0
EOF
  /usr/bin/perl -0pi -e "s/__CODEX_FORCE_GEOSERVICES_US__/${FORCE_GEOSERVICES_US}/g" "$tmp_script"
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

  mirror_siri_availability_to_appleidsettings
}

mirror_siri_availability_to_appleidsettings() {
  section "Mirror SiriAvailability into AppleIDSettings container"
  local dst_dir backup_dir ts
  dst_dir="$(dirname "$APPLEID_SETTINGS_SIRI_PREF")"
  backup_dir="$ROOT_DIR/backups/appleidsettings-siri-availability"
  ts="$(date +%Y%m%d-%H%M%S)"

  if [[ ! -f "$SIRI_PREF" ]]; then
    echo "Global SiriAvailability plist is missing: $SIRI_PREF"
    return 0
  fi

  mkdir -p "$dst_dir" "$backup_dir"
  if [[ -f "$APPLEID_SETTINGS_SIRI_PREF" ]]; then
    cp -p "$APPLEID_SETTINGS_SIRI_PREF" "$backup_dir/${SIRI_DOMAIN}.AppleIDSettings.${ts}.plist"
    echo "Backup: $backup_dir/${SIRI_DOMAIN}.AppleIDSettings.${ts}.plist"
  fi

  cp -p "$SIRI_PREF" "$APPLEID_SETTINGS_SIRI_PREF"
  chmod 600 "$APPLEID_SETTINGS_SIRI_PREF" 2>/dev/null || true
  plutil -lint "$APPLEID_SETTINGS_SIRI_PREF" >/dev/null

  echo "AppleIDSettings is sandboxed; its NSHomeDirectory is the container."
  echo "Mirrored ${SIRI_DOMAIN}/${SIRI_KEY} so AOSUI can resolve the built-in"
  echo "com.apple.application-icon.siri-intelligence icon for com.apple.siri."
  killall AppleIDSettings "System Settings" cfprefsd iconservicesagent IconServicesAgent 2>/dev/null || true
}

detect_public_ip_geo() {
  local json cc ip city region loc
  if [[ "${FORCE_GEOSERVICES_US:-0}" == "1" ]]; then
    GEO_IP_CC="US"
    GEO_IP_ADDR="forced"
    GEO_IP_CITY="forced"
    GEO_IP_REGION="forced"
    GEO_IP_LOC="forced"
    return 0
  fi

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

pin_geoservices_location_country_from_ip() {
  section "Set GeoServices location country"
  detect_public_ip_geo
  local source_note="set from current public IP geolocation"
  if [[ "${FORCE_GEOSERVICES_US:-0}" == "1" ]]; then
    source_note="forced to US by --force-geoservices-us"
  fi

  local backup_dir="/private/var/db/locationd_cache_backup/geo-ip-${GEO_IP_CC}-$(date +%Y%m%d-%H%M%S)"

  run_root mkdir -p "$GEOSERVICES_DIR" "$backup_dir"
  if [[ -e "$GEOSERVICES_DIRECT_STORE" ]]; then
    run_root cp -p "$GEOSERVICES_DIRECT_STORE" "$backup_dir/DirectReadConfigStore.plist.before"
    echo "Backup: $backup_dir/DirectReadConfigStore.plist.before"
  fi

  local tmp_store
  tmp_store="$(mktemp)"
  /usr/bin/python3 - "$tmp_store" "$GEO_IP_CC" "$GEO_IP_ADDR" "$GEO_IP_CITY" "$GEO_IP_REGION" "$GEO_IP_LOC" "$source_note" <<'PY'
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
  run_root install -o _locationd -g _locationd -m 0644 "$tmp_store" "$GEOSERVICES_DIRECT_STORE"
  rm -f "$tmp_store"

  if [[ "${FORCE_GEOSERVICES_US:-0}" == "1" ]]; then
    echo "Forced GeoServices country: ${GEO_IP_CC}"
  else
    echo "Detected public IP country: ${GEO_IP_CC} (${GEO_IP_ADDR}, ${GEO_IP_CITY}, ${GEO_IP_REGION}, ${GEO_IP_LOC})"
  fi
  echo "-- GeoServices DirectReadConfigStore --"
  run_root plutil -p "$GEOSERVICES_DIRECT_STORE" 2>/dev/null || true

  killall Maps Weather 2>/dev/null || true
  killall CoreLocationAgent 2>/dev/null || true
  run_root killall locationd geod routined 2>/dev/null || true
  echo "Set GeoServices location country cache. Reopen Maps/Weather and test current location."
}

force_web_search_provider_google() {
  section "Normalize Siri/Safari web search provider"

  defaults write NSGlobalDomain NSWebServicesProviderWebSearch -dict \
    NSDefaultDisplayName Google \
    NSProviderIdentifier com.google.www \
    NSProviderIdentifier2 com.google.www

  /usr/bin/python3 <<'PY'
import os
import plistlib
import shutil
import time

paths = [
    os.path.expanduser("~/Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist"),
    os.path.expanduser("~/Library/Preferences/com.apple.Safari.plist"),
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

  killall cfprefsd Safari assistantd SiriNCService Siri 2>/dev/null || true
  echo "Web search provider:"
  defaults read NSGlobalDomain NSWebServicesProviderWebSearch 2>/dev/null || true
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

clean_siri_location_rows_now() {
  local cleaner="/tmp/codex_fix_siri_location_clean_clients.py"
  local clients_plist="/var/db/locationd/clients.plist"

  if [[ ! -f "$clients_plist" ]]; then
    echo "Location Services clients plist not present yet; creating empty clients plist: $clients_plist"
  fi

  cat > "$cleaner" <<'PY'
import os
import plistlib
import grp
import pwd
import shutil
import sys
import time

plist_path = sys.argv[1]

if os.path.exists(plist_path):
    with open(plist_path, "rb") as f:
        data = plistlib.load(f)
else:
    data = {}

def is_siri_location_row(key, value):
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

remove_keys = [key for key, value in data.items() if is_siri_location_row(key, value)]

backup = f"{plist_path}.backup-codex-siri-icon-{time.strftime('%Y%m%d-%H%M%S')}"
if os.path.exists(plist_path):
    shutil.copy2(plist_path, backup)

for key in remove_keys:
    data.pop(key, None)

tmp = f"{plist_path}.codex-tmp"
with open(tmp, "wb") as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)

if os.path.exists(plist_path):
    stat = os.stat(plist_path)
    os.chown(tmp, stat.st_uid, stat.st_gid)
    os.chmod(tmp, stat.st_mode & 0o7777)
else:
    os.chown(tmp, pwd.getpwnam("_locationd").pw_uid, grp.getgrnam("_locationd").gr_gid)
    os.chmod(tmp, 0o600)
os.replace(tmp, plist_path)

print(f"backup={backup}")
print(f"removed={len(remove_keys)}")
for key in remove_keys:
    print(f"  {key}")
print("kept natural AssistantServices.framework Siri row if present")
PY

  run_root /usr/bin/python3 "$cleaner" "$clients_plist"
  rm -f "$cleaner"
}

apply_siri_location_icon_runtime_fix_now() {
  section "Apply Location Services Siri icon runtime fix now"

  local locationd_patch="$SIRI_LOCATION_FIX_DIR/patch_locationd_skip_assistantd_association_lldb.py"
  local assistantd_label="gui/$(id -u)/com.apple.assistantd"
  local assistantd_plist="/System/Library/LaunchAgents/com.apple.assistantd.plist"
  local locationd_lldb_log="/tmp/codex_fix_siri_location_icon_locationd.log"
  local clients_dump="/tmp/codex_fix_siri_location_clients.txt"
  local locationd_pid
  local spe_pid

  if [[ ! -f "$locationd_patch" ]]; then
    echo "Missing Location Services Siri icon patch scripts; skipping immediate runtime fix."
    return 0
  fi

  echo "== 1. Remove stale derived Siri Location Services rows =="
  run_root /usr/bin/killall lldb debugserver 2>/dev/null || true

  echo
  echo "== 2. Restart and patch locationd client-list output =="
  run_root /usr/bin/killall locationd 2>/dev/null || true
  sleep 1
  clean_siri_location_rows_now || true
  run_root /bin/launchctl kickstart -k system/com.apple.locationd 2>/dev/null || true
  sleep 3

  locationd_pid="$(pgrep -x locationd | head -1 || true)"
  if [[ -z "$locationd_pid" ]]; then
    echo "locationd did not restart; skipping immediate locationd patch."
  else
    rm -f "$locationd_lldb_log"
    run_root /usr/bin/lldb --batch -p "$locationd_pid" \
      -o "command script import \"$locationd_patch\"" \
      -o 'process detach' -o quit > "$locationd_lldb_log" 2>&1 || true
    tail -30 "$locationd_lldb_log" || true
  fi

  echo
  echo "== 3. Keep assistantd running so Launchpad Siri remains functional =="
  launchctl bootstrap "gui/$(id -u)" "$assistantd_plist" 2>/dev/null || true
  launchctl kickstart -k "$assistantd_label" 2>/dev/null || true
  sleep 2
  clean_siri_location_rows_now || true

  echo
  echo "== 4. Restart UI and trigger Location Services reload =="
  killall "System Settings" SecurityPrivacyExtension cfprefsd iconservicesagent IconServicesAgent 2>/dev/null || true
  sleep 2

  echo
  echo "== 5. Verify CoreLocation identities =="
  spe_pid="$(pgrep -f 'SecurityPrivacyExtension.appex.*SecurityPrivacyExtension' | head -1 || true)"
  if [[ -n "$spe_pid" ]]; then
    /usr/bin/lldb --batch -p "$spe_pid" \
      -o 'expr -l objc++ -O -- [NSClassFromString(@"CLLocationManager") userLocationClientsWithInfo]' \
      -o 'process detach' -o quit > "$clients_dump" 2>&1 || true
    grep -Ei 'AssistantServices.framework|System/Applications/Siri.app|CoreServices/Siri.app|assistantd|assistant_service|com.apple.Siri' "$clients_dump" || true
    echo "CoreLocation dump: $clients_dump"
  else
    echo "SecurityPrivacyExtension is not running; open Location Services to visually verify."
  fi
}

install_siri_location_icon_runtime_fix() {
  section "Integrate Location Services Siri icon runtime fix"

  install_siri_location_icon_payload

  if [[ -f "$SIRI_LOCATION_FIX_AGENT" ]]; then
    launchctl bootout "gui/$(id -u)" "$SIRI_LOCATION_FIX_AGENT" 2>/dev/null || true
    rm -f "$SIRI_LOCATION_FIX_AGENT"
    echo "Removed old standalone LaunchAgent: $SIRI_LOCATION_FIX_AGENT"
  fi

  run_root rm -f /Library/Scripts/Codex/SiriLocationIconFix/run-siri-location-icon-fix.sh 2>/dev/null || true
  run_root rm -f /Library/Scripts/Codex/SiriLocationIconFix/fix_siri_location_icon_oneclick.sh 2>/dev/null || true

  apply_siri_location_icon_runtime_fix_now || true

  echo "Siri Location icon fix payload is now used by: $LOADER_SCRIPT"
}

patch_siri_launchpad_icon_source() {
  section "Refresh Siri icon identity used by com.apple.siri"
  local backup_dir="$HOME/Documents/Codex/siri-icon-source-backups/$(date +%Y%m%d-%H%M%S)"
  local probe_log="$backup_dir/iconservices-probe.txt"

  mirror_siri_availability_to_appleidsettings

  mkdir -p "$backup_dir"
  cp "$SIRI_SYSTEM_APP/Contents/Info.plist" "$backup_dir/SystemApplications.Siri.Info.plist.live" 2>/dev/null || true
  cp "$SIRI_CORESERVICES_APP/Contents/Info.plist" "$backup_dir/CoreServices.Siri.Info.plist.live" 2>/dev/null || true

  echo "-- Live Siri identity sources --"
  echo "User-facing Siri app:"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SIRI_SYSTEM_APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$SIRI_SYSTEM_APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$SIRI_SYSTEM_APP/Contents/Info.plist" 2>/dev/null || true
  echo "Legacy service Siri app still used by AOSUI/iCloud lists:"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SIRI_CORESERVICES_APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$SIRI_CORESERVICES_APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$SIRI_CORESERVICES_APP/Contents/Info.plist" 2>/dev/null || true

  echo
  echo "AOSUI/iCloud asks for com.apple.siri. On a working system, IconServices"
  echo "aliases that app icon to Apple's built-in content type:"
  echo "  com.apple.application-icon.siri-intelligence"
  echo "No generated image or copied .icns is used here."
  echo
  echo "Refreshing LaunchServices/IconServices caches..."
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user >/dev/null 2>&1 || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$SIRI_SYSTEM_APP" || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$SIRI_CORESERVICES_APP" || true
  /usr/bin/mdimport "$SIRI_SYSTEM_APP" || true
  /usr/bin/mdimport "$SIRI_CORESERVICES_APP" || true
  /usr/bin/qlmanage -r cache >/dev/null 2>&1 || true
  killall iconservicesagent IconServicesAgent Dock "System Settings" AppleIDSettings cfprefsd 2>/dev/null || true

  if /usr/bin/swift - > "$probe_log" <<'SWIFT'
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
  then
    :
  else
    true
  fi
  cat "$probe_log"
  if ! grep -q 'com.apple.application-icon.siri-intelligence' "$probe_log"; then
    echo
    echo "WARNING: IconServices did not report the Siri Apple Intelligence type."
    echo "Do not replace icons by hand. First verify Apple Intelligence availability"
    echo "and rerun after reboot/login."
  fi

  echo "Backup: $backup_dir"
}

uninstall_run() {
  echo "+ $*"
  if [[ "$DO_UNINSTALL_DRY_RUN" == "0" ]]; then
    "$@"
  fi
}

uninstall_run_root() {
  echo "+ sudo $*"
  if [[ "$DO_UNINSTALL_DRY_RUN" == "0" ]]; then
    run_root "$@"
  fi
}

uninstall_backup_path() {
  local src="$1"
  local dst="$UNINSTALL_BACKUP_ROOT$src"
  if [[ -e "$src" ]]; then
    uninstall_run mkdir -p "$(dirname "$dst")"
    uninstall_run_root cp -a "$src" "$dst"
  fi
}

uninstall_backup_state() {
  section "Back up current state"
  uninstall_run mkdir -p "$UNINSTALL_BACKUP_ROOT"

  uninstall_backup_path "$KEXT"
  uninstall_backup_path "$LOADER_SCRIPT"
  uninstall_backup_path "$LOADER_PLIST"
  uninstall_backup_path "$SIRI_LOCATION_FIX_DIR"
  uninstall_backup_path "$SIRI_LOCATION_FIX_AGENT"
  uninstall_backup_path "$APPLEID_SETTINGS_SIRI_PREF"
  uninstall_backup_path "$ELIGIBILITYD_PLIST"
  uninstall_backup_path "$OS_ELIGIBILITY_PLIST"

  if [[ "$DO_UNINSTALL_DRY_RUN" == "0" ]]; then
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
      run_root kmutil showloaded 2>/dev/null | grep -Ei 'Codex|RegionSpoof' || true
      echo
      echo "== GMS defaults =="
      defaults read com.apple.gms.availability 2>/dev/null || true
      echo
      echo "== SiriAvailability =="
      defaults read com.apple.assistant.backedup SiriAvailability 2>/dev/null || true
      echo
      echo "== generative assistant settings =="
      defaults read com.apple.siri.generativeassistantsettings 2>/dev/null || true
    } > "$UNINSTALL_BACKUP_ROOT/state-before.txt"
  fi

  echo "Backup directory: $UNINSTALL_BACKUP_ROOT"
}

uninstall_remove_launch_items() {
  section "Remove launch items"
  uninstall_run_root launchctl bootout system "$LOADER_PLIST" 2>/dev/null || true
  uninstall_run_root rm -f "$LOADER_PLIST"
  uninstall_run_root rm -f "$LOADER_SCRIPT"
  uninstall_run_root rm -rf "$SIRI_LOCATION_FIX_DIR"

  if [[ -f "$SIRI_LOCATION_FIX_AGENT" ]]; then
    uninstall_run launchctl bootout "gui/$(id -u)" "$SIRI_LOCATION_FIX_AGENT" 2>/dev/null || true
    uninstall_run rm -f "$SIRI_LOCATION_FIX_AGENT"
  fi
}

uninstall_remove_kext() {
  section "Unload and remove CodexRegionSpoof.kext"
  if [[ -d "$KEXT" ]]; then
    uninstall_run_root kmutil unload -p "$KEXT" 2>/dev/null || true
    uninstall_run_root rm -rf "$KEXT"
  else
    echo "$KEXT not installed"
  fi
}

uninstall_clear_eligibility_cache() {
  section "Clear forced eligibility caches"
  for plist in "$ELIGIBILITYD_PLIST" "$OS_ELIGIBILITY_PLIST"; do
    if [[ -e "$plist" ]]; then
      uninstall_run_root chflags nouchg "$plist" 2>/dev/null || true
      uninstall_run_root rm -f "$plist"
      echo "Removed $plist; eligibilityd will recompute it."
    else
      echo "$plist not present"
    fi
  done
}

uninstall_clear_user_defaults() {
  section "Clear user-level Apple Intelligence force defaults"
  uninstall_run defaults delete com.apple.gms.availability 2>/dev/null || true
  uninstall_run defaults delete com.apple.siri.generativeassistantsettings isEnabled 2>/dev/null || true
  uninstall_run defaults delete com.apple.assistant.backedup SiriAvailability 2>/dev/null || true
  uninstall_run rm -f "$APPLEID_SETTINGS_SIRI_PREF"
}

uninstall_restart_services() {
  section "Restart related services"
  uninstall_run_root killall eligibilityd generativeexperiencesd modelcatalogd 2>/dev/null || true
  uninstall_run killall "System Settings" SiriPreferenceExtension SiriNCService Siri SystemUIServer Dock cfprefsd 2>/dev/null || true
}

uninstall_print_final_state() {
  section "Current state after uninstall attempt"
  csrutil status 2>&1 || true
  csrutil authenticated-root status 2>&1 || true
  echo
  ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | grep -Ei '"region-info"|"country-of-origin"|"model"|"model-number"' || true
  echo
  if [[ "$DO_UNINSTALL_DRY_RUN" == "0" ]]; then
    run_root kmutil showloaded 2>/dev/null | grep -Ei 'Codex|RegionSpoof' || echo "CodexRegionSpoof not loaded"
  fi
}

run_uninstall_restore() {
  section "Apple Intelligence uninstall / restore"
  echo "Workspace: $ROOT_DIR"
  echo "Dry run: $DO_UNINSTALL_DRY_RUN"
  echo "This will remove the kext and clear forced eligibility caches. Reboot is required."

  if [[ "$DO_UNINSTALL_DRY_RUN" == "0" ]]; then
    sudo_keepalive_start
  fi

  uninstall_backup_state
  uninstall_remove_launch_items
  uninstall_remove_kext
  uninstall_clear_eligibility_cache
  uninstall_clear_user_defaults
  uninstall_restart_services
  uninstall_print_final_state

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
  $UNINSTALL_BACKUP_ROOT
EOF
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

if [[ "$DO_UNINSTALL" == "1" ]]; then
  run_uninstall_restore
  exit 0
fi

if [[ "$DO_VERIFY_ONLY" == "0" && ( "$DO_LOAD_KEXT" == "1" || "$DO_INSTALL_LAUNCHDAEMON" == "1" || "$DO_ELIGIBILITY" == "1" || "$DO_LOCATION_IP_FIX" == "1" ) ]]; then
  section "sudo"
  echo "Requesting sudo once for kext/eligibility/system-snapshot operations..."
  sudo_keepalive_start
fi

print_sip_state

if [[ "$DO_ICON_ONLY" == "1" ]]; then
  patch_siri_launchpad_icon_source
  final_hints
  echo
  echo "Done. Reopen Launchpad after Dock/IconServices restarts."
  exit 0
fi

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
[[ "$DO_LOCATION_IP_FIX" == "1" ]] && pin_geoservices_location_country_from_ip
[[ "$DO_WEB_SEARCH_FIX" == "1" ]] && force_web_search_provider_google
[[ "$DO_SIRI_LOCATION_ICON_RUNTIME_FIX" == "1" ]] && install_siri_location_icon_runtime_fix

if [[ "$DO_ICON_ONLY" == "0" ]]; then
  refresh_ai_clients
  restore_siri_menu_bar_extra
fi
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
  echo "Because --fix-siri-icon/--all was used, close and reopen System Settings/Launchpad after IconServices refresh."
fi
