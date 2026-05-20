"""
Patch assistantd's AssistantServices effective Siri location bundle helpers.

This is a runtime-only probe.  It changes:

  AFEffectiveSiriBundleForLocation()
  AFEffectiveSiriBundlePathForLocation()

to return /System/Library/CoreServices/Siri.app instead of
/System/Library/PrivateFrameworks/AssistantServices.framework.

Why this matters:
SecurityPrivacyExtension asks CoreLocation for userLocationClientsWithInfo().
assistantd registers location usage through these AssistantServices helpers,
so Location Services may show the AssistantServices icon unless these helpers
resolve to the Siri app bundle.
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
    insns = []
    # movz x0, #chunk0
    insns.append(0xD2800000 | (chunks[0] << 5))
    # movk x0, #chunkN, lsl #(16*N)
    for hw in range(1, 4):
        insns.append(0xF2800000 | (hw << 21) | (chunks[hw] << 5))
    return b"".join(struct.pack("<I", i) for i in insns)


def _patch_return_constant(process, func_addr, value, epilogue):
    # Keep original pacibsp/prologue (+0..+15). Patch from +16 onward:
    #   movz/movk x0, retained_obj
    #   original epilogue from AFEffectiveSiriBundlePathForLocation
    #   ret
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
        # ldp x29,x30,[sp,#0x10]; ldp x20,x19,[sp],#0x20; autibsp
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
