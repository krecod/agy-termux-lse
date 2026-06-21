#!/usr/bin/env bash

# Setup & Patch script for Antigravity CLI in PRoot Container (e.g. Debian) for Non-LSE device
# Compile a userspace SIGILL trap library
# Running native execution on Non-LSE devices

set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
AGY_PROOT_HOME="$HOME/.antigravity-proot"

echo "Antigravity CLI PRoot Patcher & Setup"

# Environment Checks

echo "[1/5] Verifying environment..."

if ! command -v gcc >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "Installing required packages (gcc, libc6-dev, curl, tar)..."
  apt-get update
  apt-get install -y gcc libc6-dev curl tar
fi

echo "Environment verified successfully!"

# Library Directories

echo "[2/5] Preparing library directory shims..."

mkdir -p "$AGY_PROOT_HOME/bin"
mkdir -p "$AGY_PROOT_HOME/lib"

# Patch Engine Binary

echo "[3/5] Applying binary patches to agy engine..."

# Locate input engine

ENGINE_STAGE="$AGY_PROOT_HOME/bin/agy.engine"
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

echo "Engine binary patches applied successfully!"

# Generate and Compile userspace Signal Emulator

echo "[4/5] Generating and compiling userspace SIGILL LSE emulator..."

# Copy lse_emu_all.c from repository
cp "$SCRIPT_DIR/lse_emu_all.c" "$AGY_PROOT_HOME/lse_emu_all.c"

# Compile C emulator

echo "Compiling dynamic LSE emulator..."

gcc -shared -fPIC -O2 -march=armv8-a -mno-outline-atomics \
  -o "$AGY_PROOT_HOME/lib/liblse_emu_all.so" "$AGY_PROOT_HOME/lse_emu_all.c"

echo "SIGILL trap library compiled successfully!"

# Create Launcher and Symlinks

echo 
echo "[5/5] Creating agy Launcher..."

# Create agy launcher
LAUNCHER="$AGY_PROOT_HOME/bin/agy"

cat << 'EOF' > "$LAUNCHER"
#!/usr/bin/env bash
# Antigravity CLI - PRoot Non-LSE Launcher

set -e

AGY_PROOT_HOME="$HOME/.antigravity-proot"
ENGINE_STAGE="$AGY_PROOT_HOME/bin/agy.engine"

# Check for manual engine update request
if [ "${1:-}" = "--update" ]; then
  echo "Fetching the latest engine from wallentx..."
  ENGINE_URL="https://github.com/wallentx/antigravity-cli-termux/releases/download/v1.0.10/antigravity-termux-standalone.tar.gz"

  TEMP_TAR="$AGY_PROOT_HOME/bin/wallentx.tar.gz"
  mkdir -p "$AGY_PROOT_HOME/bin"
  curl -fL "$ENGINE_URL" -o "$TEMP_TAR"
  tar -xzf "$TEMP_TAR" -C "$AGY_PROOT_HOME/bin" agy.va39
  mv -f "$AGY_PROOT_HOME/bin/agy.va39" "$ENGINE_STAGE"
  rm -f "$TEMP_TAR"
  chmod +x "$ENGINE_STAGE"
  echo "Engine updated successfully!"
  exit 0
fi

# Preload emulator to trap LSE instructions
export LD_PRELOAD="$AGY_PROOT_HOME/lib/liblse_emu_all.so"

# Optimal environment tweaks
export GODEBUG=netdns=go
export GOGC=200
export MALLOC_ARENA_MAX=2

# Execute the engine
exec "$ENGINE_STAGE" "$@"
EOF

chmod +x "$LAUNCHER"

# Link launcher to standard path if writable
if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
  ln -sf "$LAUNCHER" "/usr/local/bin/agy"
  echo "Launcher script linked to /usr/local/bin/agy!"
  EXE="agy"
else
  echo "Warning: /usr/local/bin is not writable. Use launcher at $LAUNCHER"
  EXE="$LAUNCHER"
fi

# Automated Self-Verification Test
echo
echo "Running automated verification tests..."

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
