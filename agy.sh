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
