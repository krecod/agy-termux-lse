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
