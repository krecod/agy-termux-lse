#!/usr/bin/env python3
import sys
from pathlib import Path

def patch_engine(engine_path):
    p = Path(engine_path)
    data = bytearray(p.read_bytes())

    # Redirect resolver access to an inherited file descriptor.
    old_resolv = b"/etc/resolv.conf"
    new_resolv = b"/proc/self/fd/10"

    dns_offsets = []
    start = 0
    while True:
        idx = data.find(old_resolv, start)
        if idx < 0:
            break
        dns_offsets.append(idx)
        start = idx + 1

    print(f"Found {len(dns_offsets)} resolv path string occurrences to replace.")
    for offset in dns_offsets:
        data[offset:offset+16] = new_resolv
        print(f"Patched resolv path at offset {hex(offset)}")

    # Replace an early LSE-dependent bootstrap instruction.
    bootstrap_offset = 0x742c15c
    old_bootstrap = bytes.fromhex("0801e9f8")  # ldaddal x9, x8, [x8]
    new_bootstrap = bytes.fromhex("080140f9")  # ldr x8, [x8]

    if bootstrap_offset + 4 <= len(data) and data[bootstrap_offset:bootstrap_offset+4] == old_bootstrap:
        data[bootstrap_offset:bootstrap_offset+4] = new_bootstrap
        print(f"Patched early bootstrap at offset {hex(bootstrap_offset)}")
    else:
        # Search nearby in case the binary shifted slightly.
        found = False
        start_scan = max(0, bootstrap_offset - 0x1000)
        end_scan = min(len(data), bootstrap_offset + 0x1000)

        for scan_off in range(start_scan, end_scan, 4):
            if data[scan_off:scan_off+4] == old_bootstrap:
                data[scan_off:scan_off+4] = new_bootstrap
                print(f"Patched early bootstrap at dynamically located offset {hex(scan_off)}")
                found = True
                break

        if not found:
            print("Warning: could not locate early bootstrap check (ldaddal) in the binary. Skipping bootstrap patch...")

    # Convert LDAPR-family instructions to baseline ARMv8 LDAR equivalents.
    patches = {
        0x38bfc000: 0x08dffc00,  # LDAPRB -> LDARB
        0x78bfc000: 0x48dffc00,  # LDAPRH -> LDARH
        0xb8bfc000: 0x88dffc00,  # LDAPR W -> LDAR W
        0xf8bfc000: 0xc8dffc00,  # LDAPR X -> LDAR X
    }

    counts = {k: 0 for k in patches}

    for off in range(0, len(data) - 4, 4):
        insn = int.from_bytes(data[off:off+4], "little")
        base = insn & 0xfffffc00

        if base in patches:
            rn_rt = insn & 0x3ff
            new_insn = patches[base] | rn_rt
            data[off:off+4] = new_insn.to_bytes(4, "little")
            counts[base] += 1

    for base, cnt in counts.items():
        print(f"Patched base {hex(base)} to {hex(patches[base])}: {cnt} instruction occurrences")

    p.write_bytes(data)
    print("Engine patching completed successfully!")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: patch_engine.py <engine_path>")
        sys.exit(1)

    patch_engine(sys.argv[1])
