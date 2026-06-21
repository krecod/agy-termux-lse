# Antigravity CLI in Termux for Non-LSE device Patch

A surgical userspace patching utility and runtime wrapper designed to run the Antigravity engine natively on older ARMv8-A devices in Termux. This project bypasses the hardware requirement for ARMv8.1 Large System Extensions (LSE) atomics without the massive performance overhead of full QEMU system emulation.

> [WARNING]
> **Engine Binary Warning**:
> The `agy.va39` targeted by this setup is **not** an official Google Antigravity engine binary. It is built on top of a community-maintained fork by **wallentx** ([antigravity-cli-termux](https://github.com/wallentx/antigravity-cli-termux)). 

---

## Antigravity CLI Stable Version: 1.0.10
## Requirements

The patch scripts check for and automatically install these dependencies in Termux:
*   **glibc** (from Termux's `glibc-repo`): Native glibc runtime package.
*   **llvm**: Provides `llvm-objdump` used to disassemble and locate outline atomic instructions.
*   **proot-distro**: Establishes the isolated compiler sysroot.
*   **PRoot Distro Container**: We use **Debian** by default to compile the `SIGILL` signal-trapping emulator library (`gcc` and `libc6-dev` are automatically installed inside it).

---

## Installation & Setup

### Repository Clone & Modular Patcher

1. **Clone and enter the repository:**
   ```bash
   git clone https://github.com/krecod/agy-termux-lse
   cd cli
   ```
2. **Make the patch script executable:**
   ```bash
   chmod +x patch.sh
   ```
3. **Execute the modular installation:**
   ```bash
   ./patch.sh
   ```
**OR**
```bash
git clone https://github.com/krecod/agy-termux-lse && cd cli && chmod +x patch.sh && /patch.sh
   ```

### Monolithic One-Shot Install
If you just want a quick, clean install without checking out the code files, you can run the monolithic `patch-oneshot.sh` script directly via `curl`:
```bash
curl -sSL https://raw.githubusercontent.com/krecod/agy-termux-lse/patch-oneshot.sh | bash
```

### PRoot Distro Container Install
If you prefer to compile and run `agy` directly inside your PRoot distribution (such as Debian or Ubuntu):

1. **Log in to your PRoot container:**
   ```bash
   proot-distro login debian
   ```
2. **Clone and enter the repository inside the container:**
   ```bash
   git clone https://github.com/krecod/agy-termux-lse
   cd cli
   ```
3. **Make the script executable and run the installation:**
   ```bash
   chmod +x patch-proot.sh
   ./patch-proot.sh
   ```

---

## Running Antigravity

After a successful installation, you can run the engine anywhere in your terminal.

1. **Global Shell Command (Symlinked):**
   ```bash
   agy
   ```
2. **Direct Launcher Execution:**
   ```bash
   ~/.antigravity-termux/agy.sh
   ```
3. **Updating the Engine Binary:**
   ```bash
   agy --update
   ```
4. **Direct Launcher Execution for PRoot:**
   ```bash
   ~/.antigravity-proot/agy.sh
   ```

##  Repo Layout

All files are now modularized and organized directly in the root of the repository:

| File | Description |
| :--- | :--- |
| **`patch.sh`** | The modular setup and installation script (requires the other files in the repo). |
| **`patch-oneshot.sh`** | The preserved, monolithic setup script (self-contained, runs anywhere). |
| **`patch-proot.sh`** | Setup and installation script to configure and run agy inside a PRoot Debian/Ubuntu environment. |
| **`agy.sh`** | The runtime wrapper script (copied to `$AGY_HOME/agy.sh`) featuring glibc auto-healing. |
| **`lse_emu_all.c`** | C source code for the `SIGILL` instruction signals emulator. |
| **`patch_engine.py`** | Modifies the engine binary to bypass early bootstrap instructions and route resolv.conf to fd 10. |
| **`patch_lse_guards.py`** | Disables outline atomics branching pathways within Glibc loader/library binaries. |

---

##  Documentation

*   **[patch.md](patch.md)**: Deep-dive explanation of the patching architecture, glibc outline atomics, and signal-trapping userspace emulation.

---

##  License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

