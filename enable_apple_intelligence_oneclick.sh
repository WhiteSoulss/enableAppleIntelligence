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
DO_SIRI_LOCATION_ICON_RUNTIME_FIX=1
DO_VERIFY_ONLY=0

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
  --all                 Run core enable steps and the Siri Launchpad icon snapshot fix.
  --fix-siri-icon       Patch Siri Launchpad icon source only.
                        Requires authenticated-root disabled and a reboot.
  --verify-only         Only print current state; do not change anything.
  --skip-kext           Do not load CodexRegionSpoof.kext this run.
  --skip-launchdaemon   Do not install/update the boot-time kext loader.
  --skip-eligibility    Do not patch eligibility plists.
  --skip-sae            Do not force Siri SAE orchestration preference.
  --skip-location-ip    Do not set GeoServices location country from public IP.
  --skip-siri-location-icon
                        Do not integrate the Location Services Siri icon runtime fix.
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
  - integrates the Location Services Siri icon fix into load-region-spoof.sh
  - refreshes affected availability clients
  - optionally patches Siri Launchpad icon source and blesses a snapshot

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
      ;;
    --verify-only)
      DO_VERIFY_ONLY=1
      DO_LOAD_KEXT=0
      DO_INSTALL_LAUNCHDAEMON=0
      DO_ELIGIBILITY=0
      DO_SAE=0
      DO_LOCATION_IP_FIX=0
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
    --skip-siri-location-icon)
      DO_SIRI_LOCATION_ICON_RUNTIME_FIX=0
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
  local assistant_tmp
  local locationd_tmp

  assistant_tmp="$(mktemp)"
  locationd_tmp="$(mktemp)"

  cat > "$assistant_tmp" <<'PY'
"""
Patch assistantd's AssistantServices effective Siri location bundle helpers.

Location Services can show the old Siri icon when assistantd registers through
AssistantServices.framework. This makes the effective CoreLocation identity
resolve to /System/Library/CoreServices/Siri.app instead.
"""

import lldb
import struct


SIRI_APP = "/System/Library/CoreServices/Siri.app"
FUNC_BUNDLE = "AFEffectiveSiriBundleForLocation"
FUNC_PATH = "AFEffectiveSiriBundlePathForLocation"


def _u64_from_expr(target, expr):
    value = target.EvaluateExpression(expr)
    if not value or not value.IsValid() or value.GetError().Fail():
        raise RuntimeError(f"expression failed: {expr}: {value.GetError() if value else 'invalid'}")
    return int(value.GetValue(), 0)


def _find_func(target, name):
    matches = target.FindFunctions(name)
    if matches.GetSize() == 0:
        raise RuntimeError(f"symbol not found: {name}")
    symctx = matches.GetContextAtIndex(0)
    addr = symctx.GetSymbol().GetStartAddress().GetLoadAddress(target)
    if addr == lldb.LLDB_INVALID_ADDRESS:
        raise RuntimeError(f"symbol has invalid load address: {name}")
    return addr


def _mov_x0_imm64(value):
    chunks = [(value >> shift) & 0xFFFF for shift in (0, 16, 32, 48)]
    insns = [0xD2800000 | (chunks[0] << 5)]
    for hw in range(1, 4):
        insns.append(0xF2800000 | (hw << 21) | (chunks[hw] << 5))
    return b"".join(struct.pack("<I", i) for i in insns)


def _patch_return_constant(process, func_addr, value, epilogue):
    stub = _mov_x0_imm64(value) + epilogue + struct.pack("<I", 0xD65F03C0)
    err = lldb.SBError()
    old = process.ReadMemory(func_addr + 16, len(stub), err)
    if err.Fail():
        raise RuntimeError(f"read failed @ 0x{func_addr + 16:x}: {err}")
    err = lldb.SBError()
    written = process.WriteMemory(func_addr + 16, stub, err)
    if err.Fail() or written != len(stub):
        raise RuntimeError(f"write failed @ 0x{func_addr + 16:x}: {err}, written={written}")
    return old, stub


def __lldb_init_module(debugger, _dict):
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    if not process or not process.IsValid():
        print("[patch-assistant-effective-siri-location] no process")
        return

    try:
        bundle_obj = _u64_from_expr(
            target,
            f'(unsigned long long)[[NSBundle bundleWithPath:@"{SIRI_APP}"] retain]',
        )
        path_obj = _u64_from_expr(
            target,
            f'(unsigned long long)[@"{SIRI_APP}" retain]',
        )
        bundle_func = _find_func(target, FUNC_BUNDLE)
        path_func = _find_func(target, FUNC_PATH)

        err = lldb.SBError()
        epilogue = process.ReadMemory(path_func + 88, 12, err)
        if err.Fail() or len(epilogue) != 12:
            raise RuntimeError(f"failed to read epilogue: {err}")

        old_bundle, new_bundle = _patch_return_constant(process, bundle_func, bundle_obj, epilogue)
        old_path, new_path = _patch_return_constant(process, path_func, path_obj, epilogue)

        print(f"[patch-assistant-effective-siri-location] Siri app: {SIRI_APP}")
        print(f"[patch-assistant-effective-siri-location] retained bundle=0x{bundle_obj:x} path=0x{path_obj:x}")
        print(f"[patch-assistant-effective-siri-location] patched {FUNC_BUNDLE} @ 0x{bundle_func:x}+16")
        print(f"  old={old_bundle.hex()} new={new_bundle.hex()}")
        print(f"[patch-assistant-effective-siri-location] patched {FUNC_PATH} @ 0x{path_func:x}+16")
        print(f"  old={old_path.hex()} new={new_path.hex()}")
    except Exception as exc:
        print(f"[patch-assistant-effective-siri-location] ERROR: {exc}")
PY

  cat > "$locationd_tmp" <<'PY'
"""
Runtime patch for the Location Services duplicate Siri row.

When assistantd registers an effective CoreLocation identity, locationd can
associate it back to the natural audit identity com.apple.assistantd. That
creates a second Siri row using the old assistantd icon. This makes
CLClientManagerAdapter syncgetAssociateRegistrationIdentity:withName: return
false, so the old identity is not associated into the auth database.
"""

import lldb
import struct


METHOD = "syncgetAssociateRegistrationIdentity:withName:"
CLASS = "CLClientManagerAdapter"
RETURN_FALSE = struct.pack("<II", 0x52800000, 0xD65F03C0)


def _eval_objc(target, expr):
    value = target.EvaluateExpression(expr)
    if not value or not value.IsValid() or value.GetError().Fail():
        raise RuntimeError(f"expression failed: {expr}: {value.GetError() if value else 'invalid'}")
    text = value.GetValue() or value.GetObjectDescription() or ""
    return int(text, 0) & 0x7FFFFFFFFF


def __lldb_init_module(debugger, _dict):
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    if not process or not process.IsValid():
        print("[patch-locationd-association] no process")
        return

    try:
        addr = _eval_objc(
            target,
            (
                "@import ObjectiveC; "
                f'(unsigned long long)method_getImplementation(class_getInstanceMethod((Class)objc_getClass("{CLASS}"), sel_registerName("{METHOD}")))'
            ),
        )
        err = lldb.SBError()
        old = process.ReadMemory(addr, len(RETURN_FALSE), err)
        if err.Fail():
            raise RuntimeError(f"read failed @ 0x{addr:x}: {err}")

        err = lldb.SBError()
        written = process.WriteMemory(addr, RETURN_FALSE, err)
        if err.Fail() or written != len(RETURN_FALSE):
            raise RuntimeError(f"write failed @ 0x{addr:x}: {err}, written={written}")

        print(f"[patch-locationd-association] patched {CLASS} {METHOD} @ 0x{addr:x}")
        print(f"  old={old.hex()} new={RETURN_FALSE.hex()}")
    except Exception as exc:
        print(f"[patch-locationd-association] ERROR: {exc}")
PY

  run_root mkdir -p "$SIRI_LOCATION_FIX_DIR"
  run_root install -o root -g wheel -m 644 "$assistant_tmp" "$SIRI_LOCATION_FIX_DIR/patch_assistant_effective_siri_location_lldb.py"
  run_root install -o root -g wheel -m 644 "$locationd_tmp" "$SIRI_LOCATION_FIX_DIR/patch_locationd_skip_assistantd_association_lldb.py"
  rm -f "$assistant_tmp" "$locationd_tmp"
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
SIRI_ASSISTANTD_PATCH="$SIRI_FIX_DIR/patch_assistant_effective_siri_location_lldb.py"
SIRI_LOCATIOND_PATCH="$SIRI_FIX_DIR/patch_locationd_skip_assistantd_association_lldb.py"
ASSISTANTD_PLIST="/System/Library/LaunchAgents/com.apple.assistantd.plist"
CLIENTS_PLIST="/var/db/locationd/clients.plist"

console_user() {
  /usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true
}

console_uid() {
  local user="$1"
  /usr/bin/id -u "$user" 2>/dev/null || true
}

clean_siri_location_rows_for_icon_fix() {
  if [[ ! -f "$CLIENTS_PLIST" ]]; then
    echo "Location Services clients plist not present yet: $CLIENTS_PLIST"
    return 0
  fi

  /usr/bin/python3 - "$CLIENTS_PLIST" <<'PY'
import os
import plistlib
import shutil
import sys
import time

plist_path = sys.argv[1]
with open(plist_path, "rb") as f:
    data = plistlib.load(f)

def is_siri_location_row(key, value):
    text = f"{key}\n{value}".lower()
    return (
        "assistantd" in text
        or "assistantservices.framework" in text
        or "com.apple.siri" in text
        or "coreservices/siri.app" in text
    )

remove_keys = [key for key, value in data.items() if is_siri_location_row(key, value)]
if not remove_keys:
    print("removed=0")
    raise SystemExit(0)

backup = f"{plist_path}.backup-codex-siri-icon-{time.strftime('%Y%m%d-%H%M%S')}"
shutil.copy2(plist_path, backup)
for key in remove_keys:
    data.pop(key, None)

tmp = f"{plist_path}.codex-tmp"
with open(tmp, "wb") as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)

stat = os.stat(plist_path)
os.chown(tmp, stat.st_uid, stat.st_gid)
os.chmod(tmp, stat.st_mode & 0o7777)
os.replace(tmp, plist_path)

print(f"backup={backup}")
print(f"removed={len(remove_keys)}")
for key in remove_keys:
    print(f"  {key}")
PY
}

apply_siri_location_icon_fix() {
  if [[ ! -f "$SIRI_ASSISTANTD_PATCH" || ! -f "$SIRI_LOCATIOND_PATCH" ]]; then
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
  /bin/launchctl bootout "gui/$uid/com.apple.assistantd" 2>/dev/null || true
  /usr/bin/killall assistantd 2>/dev/null || true
  clean_siri_location_rows_for_icon_fix || true

  /usr/bin/killall locationd 2>/dev/null || true
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

  local lldb_cmds="/tmp/codex_loader_assistantd_location_icon.lldb"
  local lldb_log="/tmp/codex_loader_assistantd_location_icon.log"
  /bin/cat > "$lldb_cmds" <<EOF2
process attach -w -n assistantd
command script import "$SIRI_ASSISTANTD_PATCH"
expr -l objc++ -O -- (id)AFEffectiveSiriBundleForLocation()
expr -l objc++ -O -- (id)AFEffectiveSiriBundlePathForLocation()
process continue
EOF2

  /usr/bin/pkill -f 'codex_loader_assistantd_location_icon|lldb.*assistantd' 2>/dev/null || true
  /bin/rm -f "$lldb_log" 2>/dev/null || true
  (/usr/bin/lldb -s "$lldb_cmds" > "$lldb_log" 2>&1) &
  /bin/sleep 1

  /bin/launchctl bootstrap "gui/$uid" "$ASSISTANTD_PLIST" 2>/dev/null || true
  /bin/launchctl kickstart -k "gui/$uid/com.apple.assistantd" 2>/dev/null || true

  for _ in {1..30}; do
    if /usr/bin/grep -q "/System/Library/CoreServices/Siri.app" "$lldb_log" 2>/dev/null; then
      break
    fi
    /bin/sleep 1
  done

  /usr/bin/tail -40 "$lldb_log" 2>/dev/null || true
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

  echo "setting GeoServices location country cache from public IP"
  GEO_CC=""
  GEO_IP=""
  GEO_CITY=""
  GEO_REGION=""
  GEO_LOC=""
  if /usr/bin/curl -s --max-time 8 https://ipinfo.io/json >/tmp/codex_geo_ip.json 2>/dev/null; then
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
  /usr/bin/python3 - "$GEO_CC" "$GEO_IP" "$GEO_CITY" "$GEO_REGION" "$GEO_LOC" <<'PY'
import plistlib
import sys

cc, ip, city, region, loc = sys.argv[1:6]
payload = {
    "DeviceCountryCodeSourced": {
        "cc": cc,
        "metadata": {
            "sourceNote": "set from current public IP geolocation",
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

detect_public_ip_geo() {
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

pin_geoservices_location_country_from_ip() {
  section "Set GeoServices location country from public IP"
  detect_public_ip_geo

  local backup_dir="/private/var/db/locationd_cache_backup/geo-ip-${GEO_IP_CC}-$(date +%Y%m%d-%H%M%S)"

  run_root mkdir -p "$GEOSERVICES_DIR" "$backup_dir"
  if [[ -e "$GEOSERVICES_DIRECT_STORE" ]]; then
    run_root cp -p "$GEOSERVICES_DIRECT_STORE" "$backup_dir/DirectReadConfigStore.plist.before"
    echo "Backup: $backup_dir/DirectReadConfigStore.plist.before"
  fi

  local tmp_store
  tmp_store="$(mktemp)"
  /usr/bin/python3 - "$tmp_store" "$GEO_IP_CC" "$GEO_IP_ADDR" "$GEO_IP_CITY" "$GEO_IP_REGION" "$GEO_IP_LOC" <<'PY'
import plistlib
import sys

path, cc, ip, city, region, loc = sys.argv[1:7]
payload = {
    "DeviceCountryCodeSourced": {
        "cc": cc,
        "metadata": {
            "sourceNote": "set from current public IP geolocation",
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

  echo "Detected public IP country: ${GEO_IP_CC} (${GEO_IP_ADDR}, ${GEO_IP_CITY}, ${GEO_IP_REGION}, ${GEO_IP_LOC})"
  echo "-- GeoServices DirectReadConfigStore --"
  run_root plutil -p "$GEOSERVICES_DIRECT_STORE" 2>/dev/null || true

  killall Maps Weather 2>/dev/null || true
  killall CoreLocationAgent 2>/dev/null || true
  run_root killall locationd geod routined 2>/dev/null || true
  echo "Set location country cache from public IP. Reopen Maps/Weather and test current location."
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
    echo "Location Services clients plist not present yet: $clients_plist"
    return 0
  fi

  cat > "$cleaner" <<'PY'
import os
import plistlib
import shutil
import sys
import time

plist_path = sys.argv[1]

with open(plist_path, "rb") as f:
    data = plistlib.load(f)

def is_siri_location_row(key, value):
    text = f"{key}\n{value}".lower()
    return (
        "assistantd" in text
        or "assistantservices.framework" in text
        or "com.apple.siri" in text
        or "coreservices/siri.app" in text
    )

remove_keys = [key for key, value in data.items() if is_siri_location_row(key, value)]
backup = f"{plist_path}.backup-codex-siri-icon-{time.strftime('%Y%m%d-%H%M%S')}"
shutil.copy2(plist_path, backup)

for key in remove_keys:
    data.pop(key, None)

tmp = f"{plist_path}.codex-tmp"
with open(tmp, "wb") as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)

stat = os.stat(plist_path)
os.chown(tmp, stat.st_uid, stat.st_gid)
os.chmod(tmp, stat.st_mode & 0o7777)
os.replace(tmp, plist_path)

print(f"backup={backup}")
print(f"removed={len(remove_keys)}")
for key in remove_keys:
    print(f"  {key}")
PY

  run_root /usr/bin/python3 "$cleaner" "$clients_plist"
  rm -f "$cleaner"
}

apply_siri_location_icon_runtime_fix_now() {
  section "Apply Location Services Siri icon runtime fix now"

  local assistant_patch="$SIRI_LOCATION_FIX_DIR/patch_assistant_effective_siri_location_lldb.py"
  local locationd_patch="$SIRI_LOCATION_FIX_DIR/patch_locationd_skip_assistantd_association_lldb.py"
  local assistantd_label="gui/$(id -u)/com.apple.assistantd"
  local assistantd_plist="/System/Library/LaunchAgents/com.apple.assistantd.plist"
  local lldb_cmds="/tmp/codex_fix_siri_location_icon_assistantd.lldb"
  local lldb_log="/tmp/codex_fix_siri_location_icon_assistantd.log"
  local locationd_lldb_log="/tmp/codex_fix_siri_location_icon_locationd.log"
  local clients_dump="/tmp/codex_fix_siri_location_clients.txt"
  local locationd_pid
  local spe_pid

  if [[ ! -f "$assistant_patch" || ! -f "$locationd_patch" ]]; then
    echo "Missing Location Services Siri icon patch scripts; skipping immediate runtime fix."
    return 0
  fi

  echo "== 1. Stop assistantd and remove stale Siri/assistantd Location Services rows =="
  run_root /usr/bin/killall lldb debugserver 2>/dev/null || true
  launchctl bootout "$assistantd_label" 2>/dev/null || true
  killall assistantd 2>/dev/null || true
  clean_siri_location_rows_now || true

  echo
  echo "== 2. Restart and patch locationd so it does not associate back to com.apple.assistantd =="
  run_root /usr/bin/killall locationd 2>/dev/null || true
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
  echo "== 3. Patch assistantd effective Siri location bundle early =="
  pkill -f "codex_fix_siri_location_icon_assistantd|lldb.*assistantd" 2>/dev/null || true

  cat > "$lldb_cmds" <<EOF
process attach -w -n assistantd
command script import "$assistant_patch"
expr -l objc++ -O -- (id)AFEffectiveSiriBundleForLocation()
expr -l objc++ -O -- (id)AFEffectiveSiriBundlePathForLocation()
process continue
EOF

  rm -f "$lldb_log"
  (/usr/bin/lldb -s "$lldb_cmds" > "$lldb_log" 2>&1) &
  sleep 1

  launchctl bootstrap "gui/$(id -u)" "$assistantd_plist" 2>/dev/null || true
  launchctl kickstart -k "$assistantd_label" 2>/dev/null || true

  for _ in {1..30}; do
    if grep -q "/System/Library/CoreServices/Siri.app" "$lldb_log" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  tail -35 "$lldb_log" || true

  echo
  echo "== 4. Restart UI and trigger new Siri registration =="
  killall "System Settings" SecurityPrivacyExtension cfprefsd iconservicesagent IconServicesAgent 2>/dev/null || true
  sleep 2
  open -a Siri 2>/dev/null || true

  echo
  echo "== 5. Verify CoreLocation identities =="
  spe_pid="$(pgrep -f 'SecurityPrivacyExtension.appex.*SecurityPrivacyExtension' | head -1 || true)"
  if [[ -n "$spe_pid" ]]; then
    /usr/bin/lldb --batch -p "$spe_pid" \
      -o 'expr -l objc++ -O -- [NSClassFromString(@"CLLocationManager") userLocationClientsWithInfo]' \
      -o 'process detach' -o quit > "$clients_dump" 2>&1 || true
    grep -Ei 'AssistantServices.framework|CoreServices/Siri.app|assistantd|assistant_service|com.apple.Siri' "$clients_dump" || true
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

find_system_volume_device() {
  local root_dev sys_dev
  root_dev="$(mount | awk '$3 == "/" {print $1; exit}')"
  if [[ -z "$root_dev" ]]; then
    echo "$SIRI_ICON_DEVICE"
    return 0
  fi
  sys_dev="${root_dev%s[0-9]*}"
  if [[ "$sys_dev" == "$root_dev" ]]; then
    sys_dev="$root_dev"
  fi
  echo "$sys_dev"
}

patch_siri_launchpad_icon_source() {
  section "Patch Siri Launchpad icon source"
  local backup_dir="$HOME/Documents/Codex/siri-launchpad-icon-backups/$(date +%Y%m%d-%H%M%S)"
  local sys_dev

  if ! csrutil authenticated-root status 2>/dev/null | grep -qi 'disabled'; then
    cat >&2 <<'MSG'
Authenticated Root is enabled, so the sealed System volume cannot be changed.
For the one-time Siri Launchpad icon source fix, boot Recovery and run:

  csrutil authenticated-root disable

Then boot macOS and rerun this script with --fix-siri-icon or --all.
MSG
    exit 1
  fi

  sys_dev="$(find_system_volume_device)"

  mkdir -p "$SIRI_ICON_MNT"
  if ! mount | grep -q " on ${SIRI_ICON_MNT} "; then
    run_root mount -t apfs -o nobrowse,rw "$sys_dev" "$SIRI_ICON_MNT"
  fi

  if [[ ! -f "$SIRI_ICON_INFO" ]]; then
    echo "Missing Siri Info.plist at $SIRI_ICON_INFO" >&2
    exit 1
  fi

  mkdir -p "$backup_dir"
  cp "$SIRI_ICON_INFO" "$backup_dir/Siri.Info.plist.before"

  echo "-- Launchpad source before --"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$SIRI_ICON_INFO" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$SIRI_ICON_INFO" 2>/dev/null || true

  echo "Removing CFBundleIconName so Launchpad falls back to CFBundleIconFile/AppIcon.icns..."
  run_root /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$SIRI_ICON_INFO" 2>/dev/null || true
  plutil -lint "$SIRI_ICON_INFO"
  cp "$SIRI_ICON_INFO" "$backup_dir/Siri.Info.plist.after"

  echo "-- Launchpad source after --"
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

if [[ "$DO_VERIFY_ONLY" == "0" && ( "$DO_LOAD_KEXT" == "1" || "$DO_INSTALL_LAUNCHDAEMON" == "1" || "$DO_ELIGIBILITY" == "1" || "$DO_LOCATION_IP_FIX" == "1" || "$DO_ICON_FIX" == "1" ) ]]; then
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
[[ "$DO_LOCATION_IP_FIX" == "1" ]] && pin_geoservices_location_country_from_ip
[[ "$DO_SIRI_LOCATION_ICON_RUNTIME_FIX" == "1" ]] && install_siri_location_icon_runtime_fix

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
  echo "Because --fix-siri-icon/--all was used, reboot before judging the Siri icon in Launchpad."
fi
