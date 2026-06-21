# Antigravity CLI in Termux- Non-LSE device Patch Architecture

## 1. Objective
Bypass the hardware requirement for ARMv8.1 + LSE (Large System Extension) atomics. Allows `agy.engine` to run natively on older Android devices in Termux without using QEMU emulation.

## 2. Components

### Debian PRoot (`proot-distro`)
*   **Work:** Provides an isolated (eg: Debian -tested) environment to run the `gcc` compiler.
*   **Need:** Termux's native `clang` compiles against Android's Bionic libc. We must compile our emulator against GNU `glibc` (specifically needing GNU `<ucontext.h>`) so it can be injected into the GNU-compiled `agy.engine`. PRoot provides this sysroot instantly. Once compiled, PRoot is not used at runtime.

### Glibc Outline Atomics Patch (`patch_lse_guards.py`)
*   **Work:** Script  reads the binary of `libc.so.6` and `ld-linux-aarch64.so.1` and overwrites specific `CBZ` (Compare and Branch on Zero) guard instructions with unconditional branches.
*   **Need:** Modern `glibc` detects CPU capabilities at runtime. It attempts to execute LSE instructions if it thinks they are supported. We must manually patch the branching logic in `glibc` itself to permanently disable LSE usage, otherwise `glibc` crashes the process before our emulator can catch it.

### SIGILL Fallback Emulator (`liblse_emu_all.so`)
*   **Work:** A custom C library injected into `agy.engine` via `LD_PRELOAD`. Registers a signal handler for `SIGILL` (Illegal Instruction).
*   **Need:** Without a full CPU emulator (like QEMU, which is very slow), unsupported LSE atomic instructions (`CASP`, `LDADD`, etc.) cause the kernel to throw a `SIGILL`. This component catches the signal, decodes the exact instruction, and *surgically emulates* only that specific memory operation using older, globally supported `ldaxr`/`stlxr` instructions. This avoids the massive performance penalty of full system emulation while fully satisfying the engine's atomic requirements.

### Engine Binary Patching (`patch_engine.py`)
*   **Work:** Script modifies raw bytes within the `agy.engine` executable. It redirects DNS paths (`/etc/resolv.conf` -> `/proc/self/fd/10`), replaces early LSE bootstrap checks (`ldaddal` -> `ldr`), and downgrades unsupported `LDAPR` variants to baseline `LDAR`.
*   **Need:**
    1. **DNS**: The engine hardcodes Linux DNS paths that's why you can't login even agy running. Native Termux cannot use `/etc/resolv.conf` normally. We patch the binary to read from an inherited file descriptor (`10`) that our launcher pipes Termux's DNS config into.
    2. **Static Atomics**: Some LSE instructions execute before the emulator can safely catch them, or have complex side-effects. By directly overwriting these specific instructions in the binary with standard ARMv8 baseline instructions, we proactively prevent uncatchable crashes.

### Base Engine Binary (`wallentx` Custom Build)
*   **Work:** The setup script resolves the `agy.va39` binary using a custom pre-built community release from the [wallentx/antigravity-cli-termux](https://github.com/wallentx/antigravity-cli-termux) repository.
*   **Need:** We do not use the official Google Antigravity engine binary directly. The official engine is built strictly for vanilla Linux and crashes on Android/Termux due to 39-bit virtual address space limitations (VA39) and Android-specific `seccomp` sandbox constraints (e.g. blocking `faccessat2`). The community build by `wallentx` provides initial compatibility layers for these Android environment constraints, upon which our scripts apply the surgical Non-LSE hardware compatibility patches.

### Partial Library Copying & Auto-Updating
*   **Work:** We physically copy and patch `libc.so.6` and `ld-linux-aarch64.so.1`, but we create **symlinks** for the rest of the Termux `glibc` suite (e.g., `libm.so`, `libnss_dns.so`). The launcher (`agy.sh`) checks the system `glibc` modification timestamp before every run.
*   **Need:** `glibc` libraries are strictly version-locked. If the user updates Termux (`pkg upgrade`), the symlinked helper libraries update, but our copied `libc` does not. A version mismatch between `libc.so.6` and dynamically loaded plugins (like `libnss_dns.so.2` for networking) causes immediate crashes. The auto-update check detects system updates and automatically rebuilds the patched `libc` copy.

### PRoot Distro Patch Environment (`patch-proot.sh`)
*   **Work:** Setup flow targeted for running within a virtualized Linux userland container (e.g., Debian). Rather than routing library paths, adjusting symlinks, or rewriting binary DNS paths, it compiles the emulator (`liblse_emu_all.so`) natively inside the guest OS and preloads it via `LD_PRELOAD`.
*   **Difference from native Termux:**
    1.  **Standard GNU C Library (glibc)**: Debian is a native glibc environment. Termux runs directly on Android which uses Bionic libc. Native Termux requires wrapping and isolating custom glibc library paths to avoid immediate linker conflict crashes.
    2.  **DNS & System Paths**: Standard Linux programs query `/etc/resolv.conf` for DNS configuration. Android sandboxes block apps from accessing `/etc/` root paths natively. PRoot automatically translates and maps `/etc/resolv.conf` requests to the host's actual DNS info, whereas native Termux requires us to patch the engine binary to route queries to an inherited file descriptor (`fd 10`).
    3.  **Android Syscall Filtering (Seccomp)**: Android blocks standard system calls like `faccessat2` on older systems. PRoot intercepts and emulates these calls in userspace via `ptrace`, bypassing seccomp limits that native Termux has to workaround directly in the custom engine binary.

## 4. Scripts

### `patch.sh`
The primary setup and installation script, executed step-by-step in the following chronological order:
1.  **Environment Checks & Dependencies:** Verifies or installs `glibc-repo` and `glibc` in Termux. Installs `llvm-objdump` for disassembly, `proot-distro` to establish a compiler environment, and installs a Debian container with `gcc` and `libc6-dev` if not present.
2.  **Library Directory Setup:** Creates working directories under `$AGY_HOME` (`bin`, `lib`, `lib-nolse`). Populates `$AGY_HOME/lib` with links to system `glibc` libraries, copies the dynamic loader (`ld-linux-aarch64.so.1`) and `libc.so.6` as real writeable files into `lib-nolse`, and symlinks other libraries to form a standalone run environment.
3.  **Glibc Outline Atomics Patching:** Copies and executes [patch_lse_guards.py](patch_lse_guards.py) to parse the disassembly of the copied loader and libc, finding and patching CBZ checks (which guard LSE instructions) to always branch past them. Saves the system glibc dynamic loader modification time (`mtime`).
4.  **Engine Binary Retrieval & Patching:** Resolves the `agy.engine` binary path (checks local CLI args, repository folder `./engine/agy.va39`, or downloads from wallentx repo). Copies the binary, and runs [patch_engine.py](patch_engine.py) to redirect DNS resolver paths to fd 10, patch the early boot `ldaddal` check, and convert LDAPR instructions to standard baseline LDAR instructions.
5.  **SIGILL Emulator Compilation:** Copies the custom C emulator [lse_emu_all.c](lse_emu_all.c) and runs `gcc` inside the Debian PRoot container (using `--shared-tmp`) to cross-compile it into `liblse_emu_all.so` with outline atomics disabled (`-mno-outline-atomics`).
6.  **DNS Resolv Configuration:** Reads the Termux host `/etc/resolv.conf` and creates a local copy at `$AGY_HOME/resolv.conf` (falling back to cloud DNS servers if missing) to feed to the engine via file descriptor redirect.
7.  **Launcher Installation:** Copies [agy.sh](agy.sh) to `$AGY_HOME/agy.sh` as the primary wrapper script and creates a symlink at `$TERMUX_PREFIX/bin/agy`.
8.  **Automated Verification Tests:** Runs automated version & help test.

### `patch-proot.sh`
The setup and installation script designed for execution **inside** a Debian/Ubuntu PRoot container:
1.  **Dependencies Installation:** Verifies and automatically installs system packages (`gcc`, `libc6-dev`, `curl`, and `tar`) inside the container via `apt-get` if missing.
2.  **Engine Retrieval & Cache**: Resolves and caches the `wallentx` patched engine binary inside the repository store (`$SCRIPT_DIR/engine/agy.va39`), then copies it to `$AGY_PROOT_HOME/bin/agy.engine`.
3.  **Emulator Native Compile**: Copies [lse_emu_all.c](lse_emu_all.c) and compiles it natively inside the container's environment using system `gcc` to produce `$AGY_PROOT_HOME/lib/liblse_emu_all.so`.
4.  **Launcher Installation**: Generates a launcher wrapper script at `$AGY_PROOT_HOME/bin/agy` that preloads the emulator (`LD_PRELOAD`) and executes the engine. Symlinks the launcher to `/usr/local/bin/agy` for global container-wide terminal access.
5.  **Automated Verification Tests**: Executes basic local verification tests (`--version` and `--help`) inside the container.

### `agy.sh` (Launcher)
The wrapper script executed whenever the user calls `agy`. It runs in the following order:
1.  **Manual Engine Update Hook (`--update`):** Intercepts the `--update` CLI flag early. If called, it downloads the latest compatible engine package from the `wallentx` releases via `curl`, extracts the new binary, runs the locally stored `patch_engine.py` to apply the DNS and static instruction fixes, and replaces the target engine binary without requiring full environment re-installation.
2.  **Auto-Update Sync Checks:** Compares the system `glibc` loader's modification timestamp against the saved timestamp. If updated, it automatically performs a hot-heal (copies system libraries, runs [patch_lse_guards.py](patch_lse_guards.py), and updates the symlinks) to prevent loader/libc version mismatch crashes.
3.  **Environment Sanitization:** Unsets `LD_LIBRARY_PATH` and clears `LD_PRELOAD` to prevent library contamination. Exports optimal environment variables (`SSL_CERT_FILE`, `GODEBUG=netdns=go` to enforce the pure-Go resolver path, garbage collection settings `GOGC=200`, allocator constraints `MALLOC_ARENA_MAX=2`, and the probe log path).
4.  **DNS File Descriptor Redirect:** Opens file descriptor `10` pointing to `$AGY_HOME/resolv.conf`, which allows the patched `agy.engine` to read standard host DNS resolvers.
5.  **Loader & Preload Execution:** Executes `exec` with the patched dynamic loader (`ld-linux-aarch64.so.1`), specifying the library search directory (`lib-nolse`) and preloading `liblse_emu_all.so` to run the patched engine binary with all CLI arguments passed to it.

## 3. Error Signatures

When running the Antigravity CLI on non LSE device without this patch applied, users will typically face one of the following error symptoms:


*   **LSE Hardware Incompatibility Crash**:
    ```
    [ERR] Binaries failed to execute locally.
    ```
    
*   **Android Seccomp Violation (Older Android versions)**:
    ```
    Bad system call
    ```

*   **Glibc Loader/Library Conflicts (Native Termux)**:
    ```
    Segmentation fault
    ```

*   **DNS Resolution Failure (while login)**:
    ```
    lookup oauth2.googleapis.com on [::1]:53: connection refused
    ```
