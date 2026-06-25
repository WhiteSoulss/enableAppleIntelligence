#!/usr/bin/env python3

from __future__ import annotations

import argparse
import copy
import datetime as dt
import fcntl
import json
import os
import pathlib
import plistlib
import pwd
import shutil
import stat
import subprocess
import sys
import time
from dataclasses import dataclass


CF_ABSOLUTE_EPOCH = 978307200.0
AI_PLATFORM_PREFS_BASE = pathlib.Path("/private/var/db/AppleIntelligencePlatform")
CLOUDSUB_CACHE_REL = pathlib.Path("Library/Preferences/com.apple.CloudSubscriptionFeatures.cache.plist")
CLOUDSUB_WAITLIST_REL = pathlib.Path("Library/Preferences/com.apple.CloudSubscriptionFeatures.waitlist.plist")
GMS_AVAILABILITY_REL = pathlib.Path("Library/Preferences/com.apple.gms.availability.plist")
BYHOST_REL = pathlib.Path("Library/Preferences/ByHost")
BACKUP_REL = pathlib.Path("Library/Preferences/EnhancedSiriOverrideBackups")
LOCK_PATH = pathlib.Path("/private/tmp/codex-enhanced-siri-repair.lock")
NOTIFY_NAMES = (
    "com.apple.CloudSubscriptionFeature.Changed",
    "com.apple.siri.orchestration.capabilities.didChange",
)
GUI_LAUNCH_AGENTS = (
    ("com.apple.generativeexperiencesd", "/System/Library/LaunchAgents/com.apple.generativeexperiencesd.plist"),
    ("com.apple.assistantd", "/System/Library/LaunchAgents/com.apple.assistantd.plist"),
)
KILL_NAMES = (
    "assistantd",
    "generativeexperiencesd",
    "cfprefsd",
)


@dataclass(frozen=True)
class ConsoleContext:
    user: str
    uid: int
    gid: int
    home: pathlib.Path

    @property
    def cache_path(self) -> pathlib.Path:
        return self.home / CLOUDSUB_CACHE_REL

    @property
    def waitlist_path(self) -> pathlib.Path:
        return self.home / CLOUDSUB_WAITLIST_REL

    @property
    def user_gms_path(self) -> pathlib.Path:
        return self.home / GMS_AVAILABILITY_REL

    @property
    def platform_gms_path(self) -> pathlib.Path:
        return AI_PLATFORM_PREFS_BASE / str(self.uid) / "Library/Preferences/com.apple.gms.availability.plist"

    @property
    def byhost_dir(self) -> pathlib.Path:
        return self.home / BYHOST_REL

    @property
    def default_backup_root(self) -> pathlib.Path:
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        return self.home / BACKUP_REL / stamp

    @property
    def byhost_paths(self) -> list[pathlib.Path]:
        return sorted(self.byhost_dir.glob(".GlobalPreferences.*.plist"))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Repair macOS 27 Enhanced Siri cloud cache and GMS state."
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--status", action="store_true", help="Print current health and exit.")
    mode.add_argument("--repair-now", action="store_true", help="Force a repair run even if state looks healthy.")
    mode.add_argument(
        "--repair-if-needed",
        action="store_true",
        help="Repair only when ai.enhanced-siri or related GMS state regressed.",
    )
    parser.add_argument("--backup-root", help="Use this exact backup directory when a repair runs.")
    parser.add_argument("--dry-run", action="store_true", help="Show whether a repair would run without writing files.")
    parser.add_argument("--quiet", action="store_true", help="Suppress healthy/no-console chatter.")
    args = parser.parse_args()
    if not (args.status or args.repair_now or args.repair_if_needed):
        args.repair_if_needed = True
    return args


def log(message: str, quiet: bool = False) -> None:
    if not quiet:
        print(message)


def warn(message: str) -> None:
    print(message, file=sys.stderr)


def now_utc() -> dt.datetime:
    return dt.datetime.utcnow()


def now_cfabsolute() -> float:
    return time.time() - CF_ABSOLUTE_EPOCH


def decode_blob(raw):
    if isinstance(raw, (bytes, bytearray)):
        for parser in (plistlib.loads, lambda blob: json.loads(blob.decode("utf-8"))):
            try:
                return parser(raw)
            except Exception:
                pass
    return raw


def encode_plist_blob(value) -> bytes:
    return plistlib.dumps(value, fmt=plistlib.FMT_BINARY)


def encode_json_blob(value) -> bytes:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=True).encode("utf-8")


def load_plist(path: pathlib.Path):
    if not path.exists():
        return {}
    with path.open("rb") as fh:
        return plistlib.load(fh)


def write_plist(path: pathlib.Path, data, owner: tuple[int, int] | None = None, default_mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".codex-tmp")
    with tmp.open("wb") as fh:
        plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY, sort_keys=False)
    if path.exists():
        st = path.stat()
        os.chown(tmp, st.st_uid, st.st_gid)
        os.chmod(tmp, stat.S_IMODE(st.st_mode))
    else:
        target_uid, target_gid = owner if owner is not None else (0, 0)
        os.chown(tmp, target_uid, target_gid)
        os.chmod(tmp, default_mode)
    os.replace(tmp, path)


def backup_file(path: pathlib.Path, backup_root: pathlib.Path) -> None:
    if not path.exists():
        return
    target = backup_root / path.relative_to(pathlib.Path("/"))
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, target)


def donor_cache_entry(cache: dict) -> dict:
    if not isinstance(cache, dict):
        return {}
    preferred_keys = (
        "ai.enhanced-siri",
        "cloud.llm.v2",
        "cloud.llm",
        "ai.apps.image-playground",
    )
    for key in preferred_keys:
        entry = decode_blob(cache.get(key))
        if isinstance(entry, dict):
            return entry
    for raw in cache.values():
        entry = decode_blob(raw)
        if isinstance(entry, dict):
            return entry
    return {}


def console_context() -> ConsoleContext | None:
    try:
        uid = os.stat("/dev/console").st_uid
        pw = pwd.getpwuid(uid)
    except Exception:
        return None
    if uid == 0 or pw.pw_name in {"root", "loginwindow"}:
        return None
    return ConsoleContext(
        user=pw.pw_name,
        uid=uid,
        gid=pw.pw_gid,
        home=pathlib.Path(pw.pw_dir),
    )


def state_snapshot(ctx: ConsoleContext) -> dict:
    cache = load_plist(ctx.cache_path)
    waitlist = load_plist(ctx.waitlist_path)
    user_gms = load_plist(ctx.user_gms_path)
    platform_gms = load_plist(ctx.platform_gms_path)
    byhost_states = []
    for path in ctx.byhost_paths:
        try:
            data = load_plist(path)
        except Exception:
            data = {}
        byhost_states.append(
            {
                "path": path,
                "availability": data.get("com.apple.gms.enhancedSiri.availability") if isinstance(data, dict) else None,
                "reasons": data.get("com.apple.gms.enhancedSiri.reasons") if isinstance(data, dict) else None,
                "denied_use_cases": data.get("com.apple.gms.availability.accessNotGrantedUseCases") if isinstance(data, dict) else None,
                "unified_reasons": decode_blob(data.get("com.apple.gms.availability.unifiedReasons")) if isinstance(data, dict) else None,
            }
        )

    cache_entry = decode_blob(cache.get("ai.enhanced-siri")) if isinstance(cache, dict) else None
    cache_value = cache_entry.get("value", {}) if isinstance(cache_entry, dict) else {}
    waitlist_results = decode_blob(waitlist.get("waitlistResults", b"[]")) if isinstance(waitlist, dict) else []

    waitlist_status = None
    if isinstance(waitlist_results, list):
        for item in waitlist_results:
            value = item.get("value", {}) if isinstance(item, dict) else {}
            if "ai.enhanced-siri" in (value.get("featureIDs") or []):
                waitlist_status = value.get("status")
                break

    user_unified = decode_blob(user_gms.get("com.apple.gms.enhancedSiri.unifiedReasons")) if isinstance(user_gms, dict) else None
    platform_denied = platform_gms.get("com.apple.gms.availability.accessNotGrantedUseCases") if isinstance(platform_gms, dict) else None
    platform_unified = decode_blob(platform_gms.get("com.apple.gms.availability.unifiedReasons")) if isinstance(platform_gms, dict) else None

    problems = []
    if cache_value.get("canUse") is not True:
        problems.append("cloud cache denies ai.enhanced-siri")
    if waitlist_status != "active":
        problems.append(f"waitlist status is {waitlist_status!r}")
    if user_unified not in (None, []):
        problems.append(f"user unifiedReasons is {user_unified!r}")
    if platform_denied not in (None, []):
        problems.append(f"platform denied use cases is {platform_denied!r}")
    if platform_unified not in (None, {}):
        problems.append(f"platform unifiedReasons is {platform_unified!r}")
    for entry in byhost_states:
        if entry["availability"] is not True:
            problems.append(f"{entry['path'].name} availability is {entry['availability']!r}")
        if entry["reasons"] not in (None, []):
            problems.append(f"{entry['path'].name} reasons is {entry['reasons']!r}")
        if entry["denied_use_cases"] not in (None, []):
            problems.append(f"{entry['path'].name} denied use cases is {entry['denied_use_cases']!r}")
        if entry["unified_reasons"] not in (None, {}):
            problems.append(f"{entry['path'].name} unifiedReasons is {entry['unified_reasons']!r}")

    return {
        "cache": cache,
        "waitlist": waitlist,
        "user_gms": user_gms,
        "platform_gms": platform_gms,
        "cache_entry": cache_entry if isinstance(cache_entry, dict) else {},
        "cache_value": cache_value if isinstance(cache_value, dict) else {},
        "waitlist_results": waitlist_results if isinstance(waitlist_results, list) else [],
        "waitlist_status": waitlist_status,
        "user_unified": user_unified,
        "platform_denied": platform_denied,
        "platform_unified": platform_unified,
        "byhost_states": byhost_states,
        "problems": problems,
    }


def print_snapshot(ctx: ConsoleContext, snapshot: dict) -> None:
    print(f"console user: {ctx.user} ({ctx.uid})")
    print(f"cache ai.enhanced-siri canUse: {snapshot['cache_value'].get('canUse')!r}")
    print(f"waitlist status: {snapshot['waitlist_status']!r}")
    print(f"user unifiedReasons: {snapshot['user_unified']!r}")
    print(f"platform denied use cases: {snapshot['platform_denied']!r}")
    print(f"platform unifiedReasons: {snapshot['platform_unified']!r}")
    if snapshot["byhost_states"]:
        for entry in snapshot["byhost_states"]:
            print(
                f"{entry['path'].name}: availability={entry['availability']!r} "
                f"reasons={entry['reasons']!r} denied={entry['denied_use_cases']!r}"
            )
    else:
        print("ByHost GlobalPreferences: none found")
    if snapshot["problems"]:
        print("state: degraded")
        for problem in snapshot["problems"]:
            print(f"- {problem}")
    else:
        print("state: healthy")


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def restart_runtime(ctx: ConsoleContext) -> None:
    for name in KILL_NAMES:
        run(["/usr/bin/killall", name])
    for notification in NOTIFY_NAMES:
        run(["/bin/launchctl", "asuser", str(ctx.uid), "/usr/bin/notifyutil", "-p", notification])
    for label, plist in GUI_LAUNCH_AGENTS:
        run(["/bin/launchctl", "bootstrap", f"gui/{ctx.uid}", plist])
        run(["/bin/launchctl", "kickstart", "-k", f"gui/{ctx.uid}/{label}"])


def apply_repair(ctx: ConsoleContext, snapshot: dict, backup_root: pathlib.Path, dry_run: bool) -> dict:
    cache = snapshot["cache"] if isinstance(snapshot["cache"], dict) else {}
    waitlist = snapshot["waitlist"] if isinstance(snapshot["waitlist"], dict) else {}
    user_gms = snapshot["user_gms"] if isinstance(snapshot["user_gms"], dict) else {}
    platform_gms = snapshot["platform_gms"] if isinstance(snapshot["platform_gms"], dict) else {}

    donor = donor_cache_entry(cache)
    donor_value = donor.get("value", {}) if isinstance(donor.get("value"), dict) else {}
    cache_entry = snapshot["cache_entry"] if isinstance(snapshot["cache_entry"], dict) else {}
    cache_value = cache_entry.get("value", {})
    if not isinstance(cache_value, dict):
        cache_value = {}

    now = now_utc()
    cf_now = now_cfabsolute()
    cache_till = (
        cache_value.get("cacheTill")
        or donor_value.get("cacheTill")
        or cache_entry.get("expiration")
        or donor.get("expiration")
        or (now + dt.timedelta(days=1))
    )
    cache_value["featureKey"] = "ai.enhanced-siri"
    cache_value["canUse"] = True
    cache_value["cacheTill"] = cache_till
    cache_entry["value"] = cache_value
    cache_entry["expiration"] = cache_entry.get("expiration") or cache_till
    cache_entry["fetched"] = now
    session_id = cache_entry.get("sessionID") or donor.get("sessionID")
    alt_dsid = cache_entry.get("altDSID") or donor.get("altDSID")
    if session_id:
        cache_entry["sessionID"] = session_id
    if alt_dsid:
        cache_entry["altDSID"] = alt_dsid
    cache["ai.enhanced-siri"] = encode_plist_blob(cache_entry)

    waitlist_results = snapshot["waitlist_results"] if isinstance(snapshot["waitlist_results"], list) else []
    matched_item = None
    for item in waitlist_results:
        value = item.get("value", {}) if isinstance(item, dict) else {}
        if "ai.enhanced-siri" in (value.get("featureIDs") or []):
            matched_item = item
            break
    if matched_item is None:
        matched_item = {}
        waitlist_results.append(matched_item)
    matched_value = matched_item.get("value", {})
    if not isinstance(matched_value, dict):
        matched_value = {}
    matched_value["featureIDs"] = ["ai.enhanced-siri"]
    matched_value["status"] = "active"
    matched_item["value"] = matched_value
    matched_item["dirty"] = False
    boot_uuid = (
        matched_item.get("bootSessionID")
        or session_id
        or user_gms.get("com.apple.gms.availability.updatedSinceBootUUID")
        or user_gms.get("com.apple.gms.enhancedSiri.bootUUID")
    )
    if boot_uuid:
        matched_item["bootSessionID"] = boot_uuid
    if alt_dsid:
        matched_item["altDSID"] = alt_dsid
    matched_item["fetched"] = cf_now
    waitlist["waitlistResults"] = encode_json_blob(waitlist_results)

    user_gms["com.apple.gms.availability.reasons"] = []
    user_gms["com.apple.gms.availability.wasAvailable"] = True
    user_gms["com.apple.gms.availability.lastCheckedReadiness"] = now
    user_gms["com.apple.gms.availability.lastReadinessChange"] = now
    user_gms["com.apple.gms.availability.lastUpdateStarted"] = now
    user_gms["com.apple.gms.availability.lastUpdateEnded"] = now
    user_gms["com.apple.gms.availability.lastUpdateChanged"] = True
    latest_notifications = decode_blob(user_gms.get("com.apple.gms.availability.latestNotifications"))
    if isinstance(latest_notifications, dict):
        latest_notifications[".force"] = now
        latest_notifications[".notification(com.apple.siri.orchestration.capabilities.didChange, type: .normal)"] = now
        user_gms["com.apple.gms.availability.latestNotifications"] = encode_plist_blob(latest_notifications)
    if boot_uuid:
        user_gms["com.apple.gms.availability.updatedSinceBootUUID"] = boot_uuid
        user_gms["com.apple.gms.enhancedSiri.bootUUID"] = boot_uuid
    user_gms["com.apple.gms.availability.accessNotGrantedUseCases"] = []
    user_gms["com.apple.gms.enhancedSiri.unifiedReasons"] = b"[]"
    user_gms["com.apple.gms.enhancedSiri.wasEverAvailable"] = True

    platform_gms["com.apple.gms.availability.accessNotGrantedUseCases"] = []
    platform_gms["com.apple.gms.availability.reasons"] = []
    platform_gms["com.apple.gms.availability.unifiedReasons"] = b"{}"

    patched_byhost = 0
    byhost_payloads: list[tuple[pathlib.Path, dict]] = []
    for entry in snapshot["byhost_states"]:
        path = entry["path"]
        byhost = load_plist(path)
        if not isinstance(byhost, dict):
            byhost = {}
        byhost["com.apple.gms.availability.accessNotGrantedUseCases"] = []
        byhost["com.apple.gms.availability.unifiedReasons"] = b"{}"
        byhost["com.apple.gms.enhancedSiri.availability"] = True
        byhost["com.apple.gms.enhancedSiri.reasons"] = []
        byhost["com.apple.gms.enhancedSiri.lastUpdated"] = now
        byhost_payloads.append((path, byhost))
        patched_byhost += 1

    if dry_run:
        return {
            "backup_root": backup_root,
            "patched_byhost": patched_byhost,
            "session_id": session_id,
            "alt_dsid": alt_dsid,
        }

    backup_root.mkdir(parents=True, exist_ok=True)
    for path in (ctx.cache_path, ctx.waitlist_path, ctx.user_gms_path, ctx.platform_gms_path):
        backup_file(path, backup_root)
    for path, _payload in byhost_payloads:
        backup_file(path, backup_root)

    write_plist(ctx.cache_path, cache, owner=(ctx.uid, ctx.gid))
    write_plist(ctx.waitlist_path, waitlist, owner=(ctx.uid, ctx.gid))
    write_plist(ctx.user_gms_path, user_gms, owner=(ctx.uid, ctx.gid))
    write_plist(ctx.platform_gms_path, platform_gms)
    for path, payload in byhost_payloads:
        write_plist(path, payload, owner=(ctx.uid, ctx.gid))

    restart_runtime(ctx)
    return {
        "backup_root": backup_root,
        "patched_byhost": patched_byhost,
        "session_id": session_id,
        "alt_dsid": alt_dsid,
    }


def ensure_root_for_write(dry_run: bool) -> None:
    if dry_run:
        return
    if os.geteuid() != 0:
        raise PermissionError("repair mode must run as root; use sudo or the installed LaunchDaemon")


def main() -> int:
    args = parse_args()
    ctx = console_context()
    if ctx is None:
        log("No console user; skipping Enhanced Siri repair.", quiet=args.quiet)
        return 0

    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOCK_PATH.open("a+") as lock_fh:
        try:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("Enhanced Siri repair is already running; skipping.", quiet=args.quiet)
            return 0

        snapshot = state_snapshot(ctx)
        if args.status:
            print_snapshot(ctx, snapshot)
            return 0 if not snapshot["problems"] else 1

        try:
            ensure_root_for_write(args.dry_run)
        except PermissionError as exc:
            warn(str(exc))
            return 2

        needs_repair = args.repair_now or bool(snapshot["problems"])
        if not needs_repair:
            log("Enhanced Siri state already healthy; no repair needed.", quiet=args.quiet)
            return 0

        backup_root = pathlib.Path(args.backup_root).expanduser() if args.backup_root else ctx.default_backup_root
        repair_snapshot = copy.deepcopy(snapshot) if args.dry_run else snapshot
        result = apply_repair(ctx, repair_snapshot, backup_root, dry_run=args.dry_run)

        if args.dry_run:
            print_snapshot(ctx, snapshot)
            print("repairNeeded: True")
            print(f"backup root: {result['backup_root']}")
            print(f"patchedByHost: {result['patched_byhost']}")
            return 0

        repaired = state_snapshot(ctx)
        print(f"repairApplied: True")
        print(f"backup root: {result['backup_root']}")
        print(f"patchedByHost: {result['patched_byhost']}")
        print(f"sessionID: {result['session_id']!r}")
        print(f"altDSID: {result['alt_dsid']!r}")
        print_snapshot(ctx, repaired)
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
