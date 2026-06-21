#!/usr/bin/env bash

# Setup & Patch script for Antigravity CLI for Non-LSE device
# Compile a userspace SIGILL trap library
# Patching outline atomic instructions in-place

set -e

AGY_HOME="$HOME/.antigravity-termux" 
TERMUX_PREFIX="/data/data/com.termux/files/usr" 
GLIBC_DIR="$TERMUX_PREFIX/glibc" CONTAINER="debian"

echo "Antigravity CLI Non-LSE Patcher & Setup"

# Environment Checks

echo "[1/7] Verifying environment..."

if [ ! -d "$GLIBC_DIR" ]; then
  echo "Warning: Glibc environment not found at $GLIBC_DIR"
  echo "Installing glibc packages in Termux..."
  pkg install -y glibc-repo || true
  pkg update -y || true
  pkg install -y glibc || true
fi

if [ ! -d "$GLIBC_DIR" ]; then
  echo "Error: Glibc installation failed or not found at $GLIBC_DIR."
  echo "Run: pkg install glibc"
  exit 1
fi

if ! command -v llvm-objdump >/dev/null 2>&1; then
  echo "Warning: llvm-objdump not found. Installing LLVM..."
  pkg install -y llvm
fi

if ! command -v proot-distro >/dev/null 2>&1; then
  echo "Warning: proot-distro not found. Installing..."
  pkg install -y proot-distro
fi

if ! proot-distro list 2>&1 | grep -F -q '* debian'; then
  echo "Debian container not found. Installing Debian..."
  proot-distro install debian
fi

echo "Using PRoot container: $CONTAINER"

echo "Checking compiler inside $CONTAINER container..."
if ! proot-distro login "$CONTAINER" -- gcc --version >/dev/null 2>&1; then
  echo "GCC not found inside $CONTAINER. Installing GCC..."
  proot-distro login "$CONTAINER" -- apt update
  proot-distro login "$CONTAINER" -- apt install -y gcc libc6-dev
fi

echo "Environment verified successfully!"

# Library Directories

echo "[2/7] Preparing library directory shims"

mkdir -p "$AGY_HOME/bin"
mkdir -p "$AGY_HOME/lib"
mkdir -p "$AGY_HOME/lib-nolse"

# Set up original glibc links in $AGY_HOME/lib

echo "Linking original glibc system libraries..."

ln -sf "$GLIBC_DIR/lib/"* "$AGY_HOME/lib/"
rm -f "$AGY_HOME/lib/libc.so"
ln -sf "$GLIBC_DIR/lib/libc.so.6" "$AGY_HOME/lib/libc.so"

# Copy dynamic loader and libc to lib-nolse as real files

echo "Creating writable copies of loader and libc in lib-nolse..."

rm -f "$AGY_HOME/lib-nolse/ld-linux-aarch64.so.1" "$AGY_HOME/lib-nolse/libc.so.6"
cp -L "$AGY_HOME/lib/ld-linux-aarch64.so.1" "$AGY_HOME/lib-nolse/ld-linux-aarch64.so.1"
cp -L "$AGY_HOME/lib/libc.so.6" "$AGY_HOME/lib-nolse/libc.so.6"
chmod +w "$AGY_HOME/lib-nolse/ld-linux-aarch64.so.1" "$AGY_HOME/lib-nolse/libc.so.6"

# Create symlinks for other required libraries inside lib-nolse

for f in "$AGY_HOME"/lib/*; do
  name=$(basename "$f")
  if [ "$name" != "ld-linux-aarch64.so.1" ] && [ "$name" != "libc.so.6" ] && [ "$name" != "libc.so" ]; then
    ln -sf "$f" "$AGY_HOME/lib-nolse/$name"
  fi
done

echo "Writable library files copied to lib-nolse!"

# Patch Glibc Outline Atomics

echo "[3/7] Patching glibc outline atomic checks..."

# Embed patch_lse_guards.py inside script

cat << 'EOF' > "$AGY_HOME/patch_lse_guards.py"
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
EOF

python3 "$AGY_HOME/patch_lse_guards.py" \
  "$AGY_HOME/lib-nolse/ld-linux-aarch64.so.1" \
  "$AGY_HOME/lib-nolse/libc.so.6"

# Save current system glibc dynamic loader modification time

stat -c %Y "$GLIBC_DIR/lib/ld-linux-aarch64.so.1" > "$AGY_HOME/lib-nolse/.glibc_mtime"

echo "Dynamic loader and libc outline atomic checks patched successfully!"

# Patch Engine Binary

echo "[4/7] Applying binary patches to agy engine..."

# Locate input engine

ENGINE_STAGE="$AGY_HOME/bin/agy.engine"
ENGINE_PATCH="$AGY_HOME/bin/agy.engine.patch"
ENGINE_URL="https://github.com/wallentx/antigravity-cli-termux/releases/download/v1.0.10/antigravity-termux-standalone.tar.gz"

resolve_engine() {
  if [ -n "${1:-}" ] && [ -f "$1" ]; then
    printf '%s\n' "$1"
    return 0
  fi

  if [ -f "./engine/agy.va39" ]; then
    printf '%s\n' "./engine/agy.va39"
    return 0
  fi

  echo "Engine missing. Downloading patched release package by wallentx..." >&2

  mkdir -p "./engine"

  curl -fL "$ENGINE_URL" -o "./engine/wallentx.tar.gz"
  tar -xzf "./engine/wallentx.tar.gz" \
      -C "./engine" \
      agy.va39
  rm -f "./engine/wallentx.tar.gz"

  printf '%s\n' "./engine/agy.va39"
}

INPUT_ENGINE="$(resolve_engine "${1:-}")"

if [ ! -f "$INPUT_ENGINE" ]; then
    echo "Failed to locate or download engine."
    exit 1
fi

echo "Using input engine for patching: $INPUT_ENGINE"

cp -f "$INPUT_ENGINE" "$ENGINE_STAGE"
chmod +x "$ENGINE_STAGE"

# Embed patch_engine.py inside script

cat << 'EOF' > "$AGY_HOME/patch_engine.py"
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
EOF

python3 "$AGY_HOME/patch_engine.py" "$ENGINE_STAGE"

mv -f "$ENGINE_STAGE" "$ENGINE_PATCH"
chmod +x "$ENGINE_PATCH"

echo "Engine binary patches applied successfully!"

# Generate and Compile userspace Signal Emulator

echo "[5/7] Generating and compiling userspace SIGILL LSE emulator..."

cat << 'EOF' > "$AGY_HOME/lse_emu_all.c"
#define _GNU_SOURCE
#include <signal.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <ucontext.h>
#include <stdlib.h>

static int logfd = -1;

static void write_hex64(uint64_t v) {
    char buf[18];
    const char *h = "0123456789abcdef";
    buf[0] = '0';
    buf[1] = 'x';
    for (int i = 0; i < 16; i++) buf[2 + i] = h[(v >> ((15 - i) * 4)) & 0xf];
    write(logfd, buf, 18);
}

static void write_hex32(uint32_t v) {
    char buf[10];
    const char *h = "0123456789abcdef";
    buf[0] = '0';
    buf[1] = 'x';
    for (int i = 0; i < 8; i++) buf[2 + i] = h[(v >> ((7 - i) * 4)) & 0xf];
    write(logfd, buf, 10);
}

static uint64_t mask_bits(int bits) {
    if (bits == 64) return UINT64_MAX;
    return (1ULL << bits) - 1;
}

static int64_t sign_extend(uint64_t v, int bits) {
    uint64_t m = 1ULL << (bits - 1);
    v &= mask_bits(bits);
    return (int64_t)((v ^ m) - m);
}

static uint64_t calc_rmw(uint64_t old, uint64_t val, int op, int bits) {
    uint64_t mask = mask_bits(bits);
    old &= mask;
    val &= mask;

    switch (op) {
        case 0: return (old + val) & mask;                /* LDADD */
        case 1: return (old & ~val) & mask;               /* LDCLR */
        case 2: return (old ^ val) & mask;                /* LDEOR */
        case 3: return (old | val) & mask;                /* LDSET */
        case 4: return (sign_extend(old, bits) > sign_extend(val, bits)) ? old : val; /* LDSMAX */
        case 5: return (sign_extend(old, bits) < sign_extend(val, bits)) ? old : val; /* LDSMIN */
        case 6: return (old > val) ? old : val;           /* LDUMAX */
        case 7: return (old < val) ? old : val;           /* LDUMIN */
        case 8: return val;                               /* SWP */
        default: return old;
    }
}

/* Fallback AArch64 exclusive load/store primitives for atomic emulation */
static uint8_t ldx8(uint8_t *addr) { uint32_t v; __asm__ volatile("ldaxrb %w[v], [%[addr]]" : [v] "=&r"(v) : [addr] "r"(addr) : "memory"); return (uint8_t)v; }
static uint32_t stx8(uint8_t *addr, uint8_t v) { uint32_t fail; __asm__ volatile("stlxrb %w[fail], %w[v], [%[addr]]" : [fail] "=&r"(fail) : [v] "r"((uint32_t)v), [addr] "r"(addr) : "memory"); return fail; }

static uint16_t ldx16(uint16_t *addr) { uint32_t v; __asm__ volatile("ldaxrh %w[v], [%[addr]]" : [v] "=&r"(v) : [addr] "r"(addr) : "memory"); return (uint16_t)v; }
static uint32_t stx16(uint16_t *addr, uint16_t v) { uint32_t fail; __asm__ volatile("stlxrh %w[fail], %w[v], [%[addr]]" : [fail] "=&r"(fail) : [v] "r"((uint32_t)v), [addr] "r"(addr) : "memory"); return fail; }

static uint32_t ldx32(uint32_t *addr) { uint32_t v; __asm__ volatile("ldaxr %w[v], [%[addr]]" : [v] "=&r"(v) : [addr] "r"(addr) : "memory"); return v; }
static uint32_t stx32(uint32_t *addr, uint32_t v) { uint32_t fail; __asm__ volatile("stlxr %w[fail], %w[v], [%[addr]]" : [fail] "=&r"(fail) : [v] "r"(v), [addr] "r"(addr) : "memory"); return fail; }

static uint64_t ldx64(uint64_t *addr) { uint64_t v; __asm__ volatile("ldaxr %[v], [%[addr]]" : [v] "=&r"(v) : [addr] "r"(addr) : "memory"); return v; }
static uint32_t stx64(uint64_t *addr, uint64_t v) { uint32_t fail; __asm__ volatile("stlxr %w[fail], %[v], [%[addr]]" : [fail] "=&r"(fail) : [v] "r"(v), [addr] "r"(addr) : "memory"); return fail; }

static uint64_t emu_rmw(void *addr, uint64_t val, int op, int size) {
    uint32_t fail;

    if (size == 0) {
        uint8_t old, newv;
        do {
            old = ldx8((uint8_t *)addr);
            newv = (uint8_t)calc_rmw(old, val, op, 8);
            fail = stx8((uint8_t *)addr, newv);
        } while (fail);
        return old;
    }

    if (size == 1) {
        uint16_t old, newv;
        do {
            old = ldx16((uint16_t *)addr);
            newv = (uint16_t)calc_rmw(old, val, op, 16);
            fail = stx16((uint16_t *)addr, newv);
        } while (fail);
        return old;
    }

    if (size == 2) {
        uint32_t old, newv;
        do {
            old = ldx32((uint32_t *)addr);
            newv = (uint32_t)calc_rmw(old, val, op, 32);
            fail = stx32((uint32_t *)addr, newv);
        } while (fail);
        return old;
    }

    uint64_t old, newv;
    do {
        old = ldx64((uint64_t *)addr);
        newv = calc_rmw(old, val, op, 64);
        fail = stx64((uint64_t *)addr, newv);
    } while (fail);
    return old;
}

static uint64_t emu_cas(void *addr, uint64_t expected, uint64_t desired, int size) {
    uint32_t fail;

    if (size == 0) {
        uint8_t old;
        uint8_t exp = (uint8_t)expected;
        uint8_t des = (uint8_t)desired;
        do {
            old = ldx8((uint8_t *)addr);
            if (old != exp) return old;
            fail = stx8((uint8_t *)addr, des);
        } while (fail);
        return old;
    }

    if (size == 1) {
        uint16_t old;
        uint16_t exp = (uint16_t)expected;
        uint16_t des = (uint16_t)desired;
        do {
            old = ldx16((uint16_t *)addr);
            if (old != exp) return old;
            fail = stx16((uint16_t *)addr, des);
        } while (fail);
        return old;
    }

    if (size == 2) {
        uint32_t old;
        uint32_t exp = (uint32_t)expected;
        uint32_t des = (uint32_t)desired;
        do {
            old = ldx32((uint32_t *)addr);
            if (old != exp) return old;
            fail = stx32((uint32_t *)addr, des);
        } while (fail);
        return old;
    }

    uint64_t old;
    do {
        old = ldx64((uint64_t *)addr);
        if (old != expected) return old;
        fail = stx64((uint64_t *)addr, desired);
    } while (fail);
    return old;
}

/* Emulate Compare and Swap Pair (32-bit) using exclusive instructions */
static void emu_casp32(uint32_t *addr, uint32_t exp1, uint32_t exp2, uint32_t des1, uint32_t des2, uint32_t *out1, uint32_t *out2) {
    uint32_t fail;
    uint32_t o1, o2;
    do {
        __asm__ volatile(
            "ldaxp %w[o1], %w[o2], [%[addr]]\n"
            "cmp %w[o1], %w[exp1]\n"
            "ccmp %w[o2], %w[exp2], #0, eq\n"
            "bne 1f\n"
            "stlxp %w[fail], %w[des1], %w[des2], [%[addr]]\n"
            "b 2f\n"
            "1:\n"
            "mov %w[fail], #0\n"
            "2:\n"
            : [o1] "=&r"(o1), [o2] "=&r"(o2), [fail] "=&r"(fail)
            : [addr] "r"(addr), [exp1] "r"(exp1), [exp2] "r"(exp2), [des1] "r"(des1), [des2] "r"(des2)
            : "cc", "memory"
        );
    } while (fail);
    *out1 = o1;
    *out2 = o2;
}

/* Emulate Compare and Swap Pair (64-bit) using exclusive instructions */
static void emu_casp64(uint64_t *addr, uint64_t exp1, uint64_t exp2, uint64_t des1, uint64_t des2, uint64_t *out1, uint64_t *out2) {
    uint32_t fail;
    uint64_t o1, o2;
    do {
        __asm__ volatile(
            "ldaxp %[o1], %[o2], [%[addr]]\n"
            "cmp %[o1], %[exp1]\n"
            "ccmp %[o2], %[exp2], #0, eq\n"
            "bne 1f\n"
            "stlxp %w[fail], %[des1], %[des2], [%[addr]]\n"
            "b 2f\n"
            "1:\n"
            "mov %w[fail], #0\n"
            "2:\n"
            : [o1] "=&r"(o1), [o2] "=&r"(o2), [fail] "=&r"(fail)
            : [addr] "r"(addr), [exp1] "r"(exp1), [exp2] "r"(exp2), [des1] "r"(des1), [des2] "r"(des2)
            : "cc", "memory"
        );
    } while (fail);
    *out1 = o1;
    *out2 = o2;
}

static uint64_t get_reg(ucontext_t *uc, uint32_t r) { if (r == 31) return 0; return uc->uc_mcontext.regs[r]; }

static void set_reg(ucontext_t *uc, uint32_t r, uint64_t v, int size) {
    if (r == 31) return;
    if (size == 3) {
        uc->uc_mcontext.regs[r] = v;
    } else {
        uc->uc_mcontext.regs[r] = (uint32_t)v;
    }
}

static uint64_t get_addr(ucontext_t *uc, uint32_t rn) { if (rn == 31) return uc->uc_mcontext.sp; return uc->uc_mcontext.regs[rn]; }

/* Opcodes matches for AArch64 Large System Extensions (LSE) atomics */
static int is_atomic_rmw(uint32_t insn) { if ((insn & 0x3f200000u) != 0x38200000u) return 0; uint32_t op = (insn >> 12) & 0xf; return op <= 8; }

static int is_cas(uint32_t insn) {
    switch (insn & 0xffe0fc00u) {
        case 0x08a07c00u:
        case 0x08e07c00u:
        case 0x08a0fc00u:
        case 0x08e0fc00u:
        case 0x48a07c00u:
        case 0x48e07c00u:
        case 0x48a0fc00u:
        case 0x48e0fc00u:
        case 0x88a07c00u:
        case 0x88e07c00u:
        case 0x88a0fc00u:
        case 0x88e0fc00u:
        case 0xc8a07c00u:
        case 0xc8e07c00u:
        case 0xc8a0fc00u:
        case 0xc8e0fc00u:
            return 1;
        default:
            return 0;
    }
}

static int is_casp(uint32_t insn) {
    switch (insn & 0x3fc0fc00u) {
        case 0x08007c00u: // casp
        case 0x08807c00u: // caspa
        case 0x08407c00u: // caspl
        case 0x08c07c00u: // caspal
            return 1;
        default:
            return 0;
    }
}

/* Traps unsupported LSE instructions via SIGILL and dispatches emulation */
static void sigill_handler(int sig, siginfo_t *si, void *uctx) {
    (void)sig;
    (void)si;
    ucontext_t *uc = (ucontext_t *)uctx;

#if defined(__aarch64__)
    uint64_t pc = uc->uc_mcontext.pc;
    uint32_t insn = *(uint32_t *)pc;

    if (is_casp(insn)) {
        /* Parse registers and size field for CASP */
        uint32_t size = (insn >> 30) & 1;
        uint32_t rs = (insn >> 16) & 31;
        uint32_t rn = (insn >> 5) & 31;
        uint32_t rt = insn & 31;

        uint64_t addr = get_addr(uc, rn);
        uint64_t exp1 = get_reg(uc, rs);
        uint64_t exp2 = get_reg(uc, rs + 1);
        uint64_t des1 = get_reg(uc, rt);
        uint64_t des2 = get_reg(uc, rt + 1);

        if (size == 0) {
            uint32_t o1, o2;
            emu_casp32((uint32_t *)addr, (uint32_t)exp1, (uint32_t)exp2, (uint32_t)des1, (uint32_t)des2, &o1, &o2);
            set_reg(uc, rs, o1, 2);
            set_reg(uc, rs + 1, o2, 2);
        } else {
            uint64_t o1, o2;
            emu_casp64((uint64_t *)addr, exp1, exp2, des1, des2, &o1, &o2);
            set_reg(uc, rs, o1, 3);
            set_reg(uc, rs + 1, o2, 3);
        }
        uc->uc_mcontext.pc = pc + 4; /* Advance past trapped instruction */
        return;
    }

    if (is_cas(insn)) {
        /* Parse registers and size field for CAS */
        uint32_t size = (insn >> 30) & 3;
        uint32_t rs = (insn >> 16) & 31;
        uint32_t rn = (insn >> 5) & 31;
        uint32_t rt = insn & 31;

        uint64_t addr = get_addr(uc, rn);
        uint64_t expected = get_reg(uc, rs);
        uint64_t desired = get_reg(uc, rt);

        uint64_t old = emu_cas((void *)addr, expected, desired, size);
        set_reg(uc, rs, old, size);
        uc->uc_mcontext.pc = pc + 4; /* Advance past trapped instruction */
        return;
    }

    if (is_atomic_rmw(insn)) {
        /* Parse registers, operation type, and size field for atomic RMW */
        uint32_t size = (insn >> 30) & 3;
        uint32_t rs = (insn >> 16) & 31;
        uint32_t rn = (insn >> 5) & 31;
        uint32_t rt = insn & 31;
        uint32_t op = (insn >> 12) & 0xf;

        uint64_t addr = get_addr(uc, rn);
        uint64_t src = get_reg(uc, rs);

        uint64_t old = emu_rmw((void *)addr, src, op, size);
        set_reg(uc, rt, old, size);
        uc->uc_mcontext.pc = pc + 4; /* Advance past trapped instruction */
        return;
    }

    write(logfd, "UNSUPPORTED SIGILL pc=", 22);
    write_hex64(pc);
    write(logfd, " insn=", 6);
    write_hex32(insn);
    write(logfd, "\n", 1);
#endif
    _exit(132);
}

/* Global initialization: hooks SIGILL signal automatically on library load */
__attribute__((constructor)) static void init_lse_emu(void) {
    const char *path = getenv("LSE_PROBE_LOG");
    if (!path) {
        path = "/data/data/com.termux/files/home/.antigravity-termux/lse_probe.log";
    }
    logfd = open(path, O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (logfd < 0) logfd = STDERR_FILENO;

    struct sigaction sa;
    sa.sa_sigaction = sigill_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigaction(SIGILL, &sa, 0);

    write(logfd, "lse_emu_all loaded\n", 19);
}
EOF

# Compile C emulator

echo "Compiling dynamic LSE emulator inside $CONTAINER container..."

proot-distro login "$CONTAINER" --shared-tmp -- gcc -shared -fPIC -O2 -march=armv8-a -mno-outline-atomics \
  -o "$AGY_HOME/liblse_emu_all.so" "$AGY_HOME/lse_emu_all.c"

# Clean up source files

# rm -f "$AGY_HOME/lse_emu_all.c" "$AGY_HOME/patch_engine.py"

echo "SIGILL trap library compiled successfully!"

# Setup Resolv Config

echo 
echo "[6/7] Preparing DNS resolv.conf Configuration..."

if [ -f "$TERMUX_PREFIX/etc/resolv.conf" ]; then
  cp -f "$TERMUX_PREFIX/etc/resolv.conf" "$AGY_HOME/resolv.conf"
else
  cat > "$AGY_HOME/resolv.conf" << 'DNS'
nameserver 1.1.1.1
nameserver 8.8.8.8
DNS
fi

echo "resolv.conf generated at $AGY_HOME/resolv.conf."

# Create Launcher and Symlinks

echo 
echo "[7/7] Creating agy Launcher..."

# Create agy launcher

cat << 'EOF' > "$AGY_HOME/agy.sh"
#!/data/data/com.termux/files/usr/bin/bash

# Antigravity CLI - Non-LSE Launcher

set -e

TERMUX_HOME="/data/data/com.termux/files/home"
TERMUX_PREFIX="/data/data/com.termux/files/usr"
AGY_HOME="$TERMUX_HOME/.antigravity-termux"
GLIBC_DIR="$TERMUX_PREFIX/glibc"
LIB_NOLSE="$AGY_HOME/lib-nolse"
LOADER_NOLSE="$LIB_NOLSE/ld-linux-aarch64.so.1"
ENGINE="$AGY_HOME/bin/agy.engine.patch"
EMU="$AGY_HOME/liblse_emu_all.so"

# Check for manual engine update request
if [ "${1:-}" = "--update" ]; then
  echo "Fetching and patching the latest engine from wallentx..."
  ENGINE_STAGE="$AGY_HOME/bin/agy.engine"
  ENGINE_PATCH="$AGY_HOME/bin/agy.engine.patch"
  ENGINE_URL="https://github.com/wallentx/antigravity-cli-termux/releases/download/v1.0.10/antigravity-termux-standalone.tar.gz"

  TEMP_TAR="$AGY_HOME/bin/wallentx.tar.gz"
  mkdir -p "$AGY_HOME/bin"
  curl -fL "$ENGINE_URL" -o "$TEMP_TAR"
  tar -xzf "$TEMP_TAR" -C "$AGY_HOME/bin" agy.va39
  mv -f "$AGY_HOME/bin/agy.va39" "$ENGINE_STAGE"
  rm -f "$TEMP_TAR"

  chmod +x "$ENGINE_STAGE"
  if [ -f "$AGY_HOME/patch_engine.py" ]; then
    python3 "$AGY_HOME/patch_engine.py" "$ENGINE_STAGE"
  else
    echo "Error: patch_engine.py not found in $AGY_HOME."
    exit 1
  fi
  mv -f "$ENGINE_STAGE" "$ENGINE_PATCH"
  chmod +x "$ENGINE_PATCH"
  echo "Engine updated and patched successfully!"
  exit 0
fi

# Auto-Update Check for Termux Glibc

SAVED_MTIME_FILE="$LIB_NOLSE/.glibc_mtime"
CURRENT_MTIME=$(stat -c %Y "$GLIBC_DIR/lib/ld-linux-aarch64.so.1" 2>/dev/null || echo "0")
SAVED_MTIME=$(cat "$SAVED_MTIME_FILE" 2>/dev/null || echo "1")

if [ "$CURRENT_MTIME" != "$SAVED_MTIME" ]; then

  # Refresh loader and libc
  cp -L "$GLIBC_DIR/lib/ld-linux-aarch64.so.1" "$LIB_NOLSE/ld-linux-aarch64.so.1"
  cp -L "$GLIBC_DIR/lib/libc.so.6" "$LIB_NOLSE/libc.so.6"
  chmod +w "$LIB_NOLSE/ld-linux-aarch64.so.1" "$LIB_NOLSE/libc.so.6"

  if [ -f "$AGY_HOME/patch_lse_guards.py" ]; then
    python3 "$AGY_HOME/patch_lse_guards.py" \
      "$LIB_NOLSE/ld-linux-aarch64.so.1" \
      "$LIB_NOLSE/libc.so.6" >/dev/null 2>&1
  fi

  # Ensure all other glibc dependencies are correctly linked
  for f in "$AGY_HOME"/lib/*; do
    name=$(basename "$f")
    if [ "$name" != "ld-linux-aarch64.so.1" ] && [ "$name" != "libc.so.6" ] && [ "$name" != "libc.so" ]; then
      if [ ! -e "$LIB_NOLSE/$name" ]; then
        ln -sf "$f" "$LIB_NOLSE/$name"
      fi
    fi
  done

  echo "$CURRENT_MTIME" > "$SAVED_MTIME_FILE"
fi

export AGY_HOME
export LD_PRELOAD=""
unset LD_LIBRARY_PATH

export SSL_CERT_FILE="$TERMUX_PREFIX/etc/tls/cert.pem"
export GODEBUG=netdns=go
export GOGC=200
export MALLOC_ARENA_MAX=2

export LSE_PROBE_LOG="$AGY_HOME/lse_probe.log"

# DNS workaround for patched /proc/self/fd/10 resolver path.

if [ ! -f "$AGY_HOME/resolv.conf" ]; then
  cp "$TERMUX_PREFIX/etc/resolv.conf" "$AGY_HOME/resolv.conf" 2>/dev/null || true
fi
exec 10<"$AGY_HOME/resolv.conf"

exec "$LOADER_NOLSE" \
  --library-path "$LIB_NOLSE" \
  --preload "$EMU" \
  "$ENGINE" "$@"
EOF

chmod +x "$AGY_HOME/agy.sh"

# Link launcher to $PREFIX/bin/agy

ln -sf "$AGY_HOME/agy.sh" "$TERMUX_PREFIX/bin/agy"
echo "Launcher script linked to $TERMUX_PREFIX/bin/agy!"

# Automated Self-Verification Test
echo
echo "Running automated verification tests..."

# Determine the correct binary path execution context
if command -v agy >/dev/null 2>&1; then
  EXE="agy"
else
  EXE="$AGY_HOME/agy.sh"
fi

if "$EXE" --version >/dev/null 2>&1; then
  echo "Test 1/3: '$EXE --version' PASSED"
else
  echo "Test 1/3: '$EXE --version' FAILED"
fi

if "$EXE" --help >/dev/null 2>&1; then
  echo "Test 2/3: '$EXE --help' PASSED"
else
  echo "Test 2/3: '$EXE --help' FAILED"
fi

# Functional string rendering and timeout handling

OUTPUT=$("$EXE" --print "Reply with exactly: Hello World" --print-timeout 30s 2>&1)
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ] && echo "$OUTPUT" | grep -q "Hello World"; then
  echo "Test 3/3: '$EXE --print' functional check PASSED"
else
  echo "Test 3/3: '$EXE --print' functional check FAILED"
  [ $EXIT_CODE -ne 0 ] && echo "    Reason: Command exited with non-zero status ($EXIT_CODE)"
  [[ ! "$OUTPUT" =~ "Hello World" ]] && echo "    Reason: Maybe Gemini Sucks"
fi

echo
echo "Done :/"
