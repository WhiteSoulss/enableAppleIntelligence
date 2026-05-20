"""
patch_locationd_skip_assistantd_association_lldb.py

Runtime patch for the Location Services duplicate Siri row.

Root cause observed in locationd:

  assistantd registers an effective CoreLocation identity such as:
    p/System/Library/PrivateFrameworks/AssistantServices.framework

  locationd then runs:
    CLClientManagerAdapter syncgetAssociateRegistrationIdentity:withName:

  That association path calls GetIdentifyingInfo on the natural audit identity:
    icom.apple.assistantd

  Location Services then shows a second Siri row using the old assistantd icon.

This patch makes syncgetAssociateRegistrationIdentity:withName: return false.
It does not patch icon assets. It stops the natural assistantd identity from
being associated into the auth database after the effective Siri identity is
used.
"""

import lldb
import struct


METHOD = "syncgetAssociateRegistrationIdentity:withName:"
CLASS = "CLClientManagerAdapter"

# mov w0, #0 ; ret
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
