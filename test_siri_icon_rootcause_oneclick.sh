#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-$ROOT_DIR/siri_icon_rootcause_test_$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT_DIR"

LOG="$OUT_DIR/report.txt"
: > "$LOG"

say() {
  print -r -- "$@" | tee -a "$LOG"
}

section() {
  say
  say "== $1 =="
}

run_capture() {
  local title="$1"
  shift
  section "$title"
  {
    "$@" 2>&1 || true
  } | tee -a "$LOG"
}

plist_get() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

decode_region_hex() {
  python3 - "$1" <<'PY'
import binascii, re, sys
s = sys.argv[1]
m = re.search(r'<([0-9a-fA-F]+)>', s)
if not m:
    print("")
    raise SystemExit
raw = binascii.unhexlify(m.group(1))
print(raw.split(b'\0', 1)[0].decode('ascii', 'replace'))
PY
}

bundle_report() {
  local app="$1"
  local label="$2"
  section "Bundle: $label"
  say "Path: $app"
  if [[ ! -d "$app" ]]; then
    say "missing"
    return
  fi

  local info="$app/Contents/Info.plist"
  say "CFBundleIdentifier: $(plist_get "$info" CFBundleIdentifier)"
  say "CFBundleName:       $(plist_get "$info" CFBundleName)"
  say "CFBundleDisplayName:$(plist_get "$info" CFBundleDisplayName)"
  say "CFBundleIconFile:   $(plist_get "$info" CFBundleIconFile)"
  say "CFBundleIconName:   $(plist_get "$info" CFBundleIconName)"
  say "Resources:"
  ls "$app/Contents/Resources" 2>/dev/null | grep -E '^(AppIcon|Assets\.car|InfoPlist)' | tee -a "$LOG" || true

  local car="$app/Contents/Resources/Assets.car"
  if [[ -f "$car" ]]; then
    say "Asset signal:"
    assetutil --info "$car" 2>/dev/null |
      grep -E '"Name" :|"RenditionName" :' |
      grep -Ei 'AppIcon|siri\.orb|solarium|SAENotificationIcon' |
      head -60 | tee -a "$LOG" || true
    if assetutil --info "$car" 2>/dev/null | grep -qi 'solarium'; then
      say "Asset verdict: contains solarium/new-style icon assets"
    else
      say "Asset verdict: no solarium string found, likely old Siri orb asset set"
    fi
  fi
}

render_icon() {
  local bundle_id="$1"
  local out_png="$2"
  local helper="$OUT_DIR/render_bundle_icon"

  if [[ ! -x "$helper" ]]; then
    clang -framework AppKit -framework Foundation \
      "$ROOT_DIR/tools/render_bundle_icon.m" -o "$helper" 2>>"$LOG" || return 1
  fi
  "$helper" "$bundle_id" "$out_png" 2>&1 | tee -a "$LOG" || return 1
}

section "Siri Icon Root Cause One-Click Test"
say "Output: $OUT_DIR"
say "Mode: observation only; no system files, caches, plist, Dock, or LaunchServices state will be modified."

run_capture "SIP / SSV" csrutil status
run_capture "Authenticated Root" csrutil authenticated-root status

section "IORegistry Root Identity"
IOREG_OUT="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null || true)"
print -r -- "$IOREG_OUT" |
  grep -Ei '"region-info"|"country-of-origin"|"model"|"model-number"|"regulatory-model-number"' |
  tee -a "$LOG" || true

REGION_LINE="$(print -r -- "$IOREG_OUT" | grep '"region-info"' | head -1 || true)"
COUNTRY_LINE="$(print -r -- "$IOREG_OUT" | grep '"country-of-origin"' | head -1 || true)"
REGION_VALUE="$(decode_region_hex "$REGION_LINE" 2>/dev/null || true)"
COUNTRY_VALUE="$(print -r -- "$COUNTRY_LINE" | sed -n 's/.*<"\([^"]*\)">.*/\1/p')"
say "Parsed region-info: ${REGION_VALUE:-unknown}"
say "Parsed country-of-origin: ${COUNTRY_VALUE:-unknown}"

section "Apple Intelligence Availability Signals"
say "com.apple.siri.generativeassistantsettings:"
defaults read com.apple.siri.generativeassistantsettings 2>/dev/null | tee -a "$LOG" || true
say
say "com.apple.gms.availability selected keys:"
defaults read com.apple.gms.availability 2>/dev/null |
  grep -E 'forcedAvailability|state|wasAvailable|unifiedReasons|updatedSinceBootUUID|gpEverInstalled' |
  tee -a "$LOG" || true
say
say "com.apple.assistant.backedup SiriAvailability:"
defaults read com.apple.assistant.backedup SiriAvailability 2>/dev/null | tee -a "$LOG" || true

section "Eligibility Domains"
for plist in /private/var/db/eligibilityd/eligibility.plist /private/var/db/os_eligibility/eligibility.plist; do
  say "-- $plist"
  if [[ ! -f "$plist" ]]; then
    say "missing"
    continue
  fi
  for domain in \
    OS_ELIGIBILITY_DOMAIN_GREYMATTER \
    OS_ELIGIBILITY_DOMAIN_FOUNDATION_MODELS \
    OS_ELIGIBILITY_DOMAIN_PERSONAL_QA \
    OS_ELIGIBILITY_DOMAIN_SIRI_WITH_APP_INTENTS \
    OS_ELIGIBILITY_DOMAIN_TERBIUM \
    OS_ELIGIBILITY_DOMAIN_IRON \
    OS_ELIGIBILITY_DOMAIN_STRONTIUM \
    OS_ELIGIBILITY_DOMAIN_SWIFT_ASSIST \
    OS_ELIGIBILITY_DOMAIN_XCODE_LLM; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$domain:os_eligibility_answer_t" "$plist" 2>/dev/null || true)"
    [[ -n "$value" ]] && say "$domain answer_t=$value"
  done
done

bundle_report "/System/Applications/Siri.app" "System Applications Siri launcher"
bundle_report "/System/Library/CoreServices/Siri.app" "CoreServices Siri"
bundle_report "/System/Library/CoreServices/Siri.bundle" "Siri menu extra bundle"

section "LaunchServices Siri Registrations"
LS_DUMP="$OUT_DIR/lsregister_siri.txt"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump 2>/dev/null > "$LS_DUMP" || true
grep -A26 -B6 -E 'identifier: +com\.apple\.siri\.launcher|identifier: +com\.apple\.Siri|path: +/System/.*/Siri\.app' "$LS_DUMP" |
  head -220 | tee -a "$LOG" || true
say "Full LaunchServices dump saved to: $LS_DUMP"

section "Launchpad Database Probe"
LP_FOUND=0
while IFS= read -r db; do
  LP_FOUND=1
  say "-- $db"
  sqlite3 "$db" "select apps.title, apps.bundleid, apps.path from apps where apps.title like '%Siri%' or apps.bundleid like '%siri%';" 2>/dev/null |
    tee -a "$LOG" || true
done < <(find "$HOME/Library" -maxdepth 6 -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) 2>/dev/null | grep -Ei 'Dock|Launchpad|launchpad|dock' || true)
[[ "$LP_FOUND" == "0" ]] && say "No readable Dock/Launchpad DB found under ~/Library. This can be normal on newer macOS builds."

section "Rendered Icons Via NSWorkspace"
render_icon "com.apple.siri.launcher" "$OUT_DIR/com.apple.siri.launcher.png" || say "render failed for com.apple.siri.launcher"
render_icon "com.apple.Siri" "$OUT_DIR/com.apple.Siri.png" || say "render failed for com.apple.Siri"
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$OUT_DIR"/*.png 2>/dev/null | tee -a "$LOG" || true
fi

section "Preliminary Verdict"
if [[ "$REGION_VALUE" == "LL/A" ]]; then
  say "[OK] region-info is LL/A."
else
  say "[WARN] region-info is not LL/A. This is still a root identity blocker."
fi

if [[ "$COUNTRY_VALUE" == "CHN" ]]; then
  say "[WARN] country-of-origin is still CHN. This is the remaining low-level China-origin identity signal."
else
  say "[OK] country-of-origin is not CHN or not exposed."
fi

if assetutil --info /System/Applications/Siri.app/Contents/Resources/Assets.car 2>/dev/null | grep -qi 'solarium'; then
  say "[OK] /System/Applications/Siri.app has solarium/new-style AppIcon assets."
else
  say "[WARN] /System/Applications/Siri.app does not show solarium assets."
fi

if assetutil --info /System/Library/CoreServices/Siri.app/Contents/Resources/Assets.car 2>/dev/null | grep -qi 'solarium'; then
  say "[OK] /System/Library/CoreServices/Siri.app has solarium assets."
else
  say "[INFO] /System/Library/CoreServices/Siri.app appears to keep old Siri orb assets."
fi

say
say "Report written to: $LOG"
say "Rendered icon PNGs, if generated, are in: $OUT_DIR"
