#!/usr/bin/env bash

# Setup & Patch script for Antigravity CLI for Non-LSE device
# Compile a userspace SIGILL trap library
# Patching outline atomic instructions in-place

set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
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

echo "[2/7] Preparing library directory shims..."

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

# Copy patch_lse_guards.py from repository
cp "$SCRIPT_DIR/patch_lse_guards.py" "$AGY_HOME/patch_lse_guards.py"
chmod +x "$AGY_HOME/patch_lse_guards.py"

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

INPUT_ENGINE=""

if [ -n "${1:-}" ] && [ -f "$1" ]; then
  INPUT_ENGINE="$1"
elif [ -f "$SCRIPT_DIR/engine/agy.va39" ]; then
  INPUT_ENGINE="$SCRIPT_DIR/engine/agy.va39"
else
  echo "Engine missing. Downloading patched release package by wallentx..." >&2
  mkdir -p "$SCRIPT_DIR/engine"
  curl -fL "$ENGINE_URL" -o "$SCRIPT_DIR/engine/wallentx.tar.gz"
  tar -xzf "$SCRIPT_DIR/engine/wallentx.tar.gz" -C "$SCRIPT_DIR/engine" agy.va39
  rm -f "$SCRIPT_DIR/engine/wallentx.tar.gz"
  INPUT_ENGINE="$SCRIPT_DIR/engine/agy.va39"
fi

if [ ! -f "$INPUT_ENGINE" ]; then
  echo "Error: Failed to locate or download engine."
  exit 1
fi

echo "Using input engine for patching: $INPUT_ENGINE"

cp -f "$INPUT_ENGINE" "$ENGINE_STAGE"
chmod +x "$ENGINE_STAGE"


cp "$SCRIPT_DIR/patch_engine.py" "$AGY_HOME/patch_engine.py"
chmod +x "$AGY_HOME/patch_engine.py"

python3 "$AGY_HOME/patch_engine.py" "$ENGINE_STAGE"

mv -f "$ENGINE_STAGE" "$ENGINE_PATCH"
chmod +x "$ENGINE_PATCH"

echo "Engine binary patches applied successfully!"

# Generate and Compile userspace Signal Emulator

echo "[5/7] Generating and compiling userspace SIGILL LSE emulator..."

# Copy lse_emu_all.c from repository
cp "$SCRIPT_DIR/lse_emu_all.c" "$AGY_HOME/lse_emu_all.c"

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

# Copy agy launcher from repository
cp "$SCRIPT_DIR/agy.sh" "$AGY_HOME/agy.sh"
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
  echo "Test 1/2: '$EXE --version' PASSED"
else
  echo "Test 1/2: '$EXE --version' FAILED"
fi

if "$EXE" --help >/dev/null 2>&1; then
  echo "Test 2/2: '$EXE --help' PASSED"
else
  echo "Test 2/2: '$EXE --help' FAILED"
fi

echo
echo "Done :/"
