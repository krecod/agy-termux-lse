#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess
import sys

# LSE atomic instruction mnemonics emitted by glibc outline atomics.
LSE_RE = re.compile(
    r'\b(cas|casp|ldadd|ldclr|ldeor|ldset|ldsmax|ldsmin|ldumax|ldumin|swp|stadd|stclr|steor|stset)[a-z0-9]*\b',
    re.I
)

def read_u32_le(data, off):
    return int.from_bytes(data[off:off+4], "little")

def write_u32_le(data, off, val):
    data[off:off+4] = int(val).to_bytes(4, "little")

def is_cbz(insn):
    # Match CBZ/CBNZ immediate branch instructions.
    return (insn & 0x7e000000) == 0x34000000

def cbz_to_b(insn):
    # Convert a conditional guard branch into an unconditional branch.
    imm19 = (insn >> 5) & 0x7ffff
    if imm19 & (1 << 18):
        signed = imm19 - (1 << 19)
    else:
        signed = imm19
    imm26 = signed & 0x03ffffff
    return 0x14000000 | imm26

def objdump_lse_addrs(path):
    # Find addresses of LSE instructions from disassembly output.
    out = subprocess.check_output(
        ["llvm-objdump", "-d", str(path)],
        text=True,
        stderr=subprocess.DEVNULL,
    )
    addrs = []
    for line in out.splitlines():
        if not LSE_RE.search(line):
            continue
        m = re.search(r'^\s*([0-9a-fA-F]+):\s+[0-9a-fA-F]{8}\s+(\S+)', line)
        if not m:
            continue
        addr = int(m.group(1), 16)
        mnemonic = m.group(2)
        addrs.append((addr, mnemonic, line.strip()))
    return addrs

def patch_file(path):
    path = Path(path)
    data = bytearray(path.read_bytes())

    # Keep a one-time backup before patching.
    backup = path.with_suffix(path.suffix + ".bak-before-lse-guard-patch")
    if not backup.exists():
        backup.write_bytes(data)

    addrs = objdump_lse_addrs(path)
    print(f"\n== {path}")
    print(f"LSE instructions: {len(addrs)}")

    patched = 0
    skipped = 0

    for addr, mnemonic, line in addrs:
        off = addr
        guard_off = off - 4
        if guard_off < 0 or off + 4 > len(data):
            skipped += 1
            continue

        guard = read_u32_le(data, guard_off)

        # Patch only LSE sites guarded by a CBZ/CBNZ check.
        if not is_cbz(guard):
            skipped += 1
            continue

        new_guard = cbz_to_b(guard)
        print(
            f"patch guard @0x{guard_off:x} before "
            f"{mnemonic} @0x{off:x}: {guard:08x} -> {new_guard:08x}"
        )

        write_u32_le(data, guard_off, new_guard)
        patched += 1

    if patched:
        path.write_bytes(data)

    print(f"patched guards: {patched}")
    print(f"skipped LSE sites: {skipped}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: patch_lse_guards.py file...")
        sys.exit(2)
    for arg in sys.argv[1:]:
        patch_file(arg)
