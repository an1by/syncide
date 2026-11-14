#!/bin/sh
set -eu

INSTALL_DIR="${SYNCIDE_INSTALL_DIR:-$HOME/.local/bin}"
BIN_PATH="${INSTALL_DIR}/syncide"

OS_RAW="$(uname -s)"
case "$OS_RAW" in
  Darwin*)
    DEFAULT_STORE_DIR="$HOME/Library/Application Support/syncide"
    ;;
  *)
    if [ -n "${XDG_CONFIG_HOME:-}" ]; then
      DEFAULT_STORE_DIR="${XDG_CONFIG_HOME}/syncide"
    else
      DEFAULT_STORE_DIR="$HOME/.config/syncide"
    fi
    ;;
esac

BOOTSTRAP_STATE="${DEFAULT_STORE_DIR}/state.json"
CAN_REMOVE_STORE="1"
CUSTOM_STORE_DIR=""

if [ -f "$BOOTSTRAP_STATE" ]; then
  CUSTOM_STORE_DIR="$(sed -n 's/.*"storeDir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$BOOTSTRAP_STATE" | head -n 1)"

  if ! grep -Eq '"managedIdeIds"[[:space:]]*:[[:space:]]*\[\]' "$BOOTSTRAP_STATE"; then
    RUNNER=""
    if [ -x "$BIN_PATH" ]; then
      RUNNER="$BIN_PATH"
    elif command -v syncide >/dev/null 2>&1; then
      RUNNER="$(command -v syncide)"
    fi

    if [ -n "$RUNNER" ]; then
      echo "Detaching linked IDEs back into standalone copies ('syncide unlink all')..."
      if ! "$RUNNER" unlink all; then
        CAN_REMOVE_STORE="0"
        echo "Warning: Could not detach all IDEs. Keeping store directory intact to prevent broken symlinks." >&2
      fi
    else
      CAN_REMOVE_STORE="0"
      echo "Warning: syncide binary not found to detach links; keeping ${DEFAULT_STORE_DIR} intact." >&2
    fi
  fi
fi

if [ -f "$BIN_PATH" ]; then
  rm -f "$BIN_PATH"
  echo "Removed binary ${BIN_PATH}"
fi

remove_rc_block() {
  rc_file="$1"
  if [ -f "$rc_file" ] && grep -F "# syncide" "$rc_file" >/dev/null 2>&1; then
    tmp_rc="$(mktemp 2>/dev/null || mktemp -t syncide-rc)"
    awk '
      /^# syncide$/ { skip = 1; next }
      skip == 1 { skip = 0; next }
      { print }
    ' "$rc_file" > "$tmp_rc"
    mv -f "$tmp_rc" "$rc_file"
    echo "Cleaned PATH entry in ${rc_file}"
  fi
}

# Clean shell rc PATH snippet only if install dir is now empty (avoids breaking shared ~/.local/bin tools)
if [ ! -d "$INSTALL_DIR" ] || [ -z "$(ls -A "$INSTALL_DIR" 2>/dev/null || true)" ]; then
  rmdir "$INSTALL_DIR" 2>/dev/null || true
  remove_rc_block "$HOME/.bashrc"
  remove_rc_block "$HOME/.zshrc"
  remove_rc_block "$HOME/.profile"
  if [ -f "$HOME/.config/fish/conf.d/syncide.fish" ]; then
    rm -f "$HOME/.config/fish/conf.d/syncide.fish"
    echo "Removed $HOME/.config/fish/conf.d/syncide.fish"
  fi
fi

if [ "$CAN_REMOVE_STORE" = "1" ] && [ -z "${SYNCIDE_KEEP_DATA:-}" ]; then
  if [ -n "$CUSTOM_STORE_DIR" ] && [ -d "$CUSTOM_STORE_DIR" ]; then
    rm -rf "$CUSTOM_STORE_DIR"
    echo "Removed store directory ${CUSTOM_STORE_DIR}"
  fi
  if [ -d "$DEFAULT_STORE_DIR" ]; then
    rm -rf "$DEFAULT_STORE_DIR"
    echo "Removed config directory ${DEFAULT_STORE_DIR}"
  fi
fi

echo "syncide uninstalled."
