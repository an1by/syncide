#!/bin/sh
set -eu

REPO="an1by/syncide"
VERSION="${SYNCIDE_VERSION:-}"
INSTALL_DIR="${SYNCIDE_INSTALL_DIR:-$HOME/.local/bin}"

OS_RAW="$(uname -s)"
case "$OS_RAW" in
  Linux*)  OS="linux" ;;
  Darwin*) OS="macos" ;;
  *)
    echo "Error: Unsupported OS '$OS_RAW'. Use install.ps1 on Windows." >&2
    exit 1
    ;;
esac

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64)  ARCH="x86_64" ;;
  aarch64|arm64) ARCH="aarch64" ;;
  *)
    echo "Error: Unsupported CPU architecture '$ARCH_RAW'." >&2
    exit 1
    ;;
esac

ASSET="syncide-${OS}-${ARCH}.tar.gz"
if [ -n "$VERSION" ]; then
  case "$VERSION" in
    v*) TAG="$VERSION" ;;
    *)  TAG="v$VERSION" ;;
  esac
  BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"
else
  BASE_URL="https://github.com/${REPO}/releases/latest/download"
fi

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t syncide)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

fetch() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    echo "Error: curl or wget is required." >&2
    exit 1
  fi
}

echo "Downloading ${ASSET}..."
fetch "${BASE_URL}/${ASSET}" "${TMP_DIR}/${ASSET}"
fetch "${BASE_URL}/SHA256SUMS.txt" "${TMP_DIR}/SHA256SUMS.txt"

EXPECTED_HASH="$(awk -v f="$ASSET" '$2 == f || $2 == "*"f { print $1; exit }' "${TMP_DIR}/SHA256SUMS.txt")"
if [ -z "$EXPECTED_HASH" ]; then
  echo "Error: Checksum for ${ASSET} not found in SHA256SUMS.txt" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_HASH="$(sha256sum "${TMP_DIR}/${ASSET}" | awk '{ print $1 }')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_HASH="$(shasum -a 256 "${TMP_DIR}/${ASSET}" | awk '{ print $1 }')"
else
  echo "Error: sha256sum or shasum is required to verify download integrity." >&2
  exit 1
fi

if [ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]; then
  echo "Error: SHA256 mismatch (expected ${EXPECTED_HASH}, got ${ACTUAL_HASH})." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
tar -xzf "${TMP_DIR}/${ASSET}" -C "$TMP_DIR"
chmod +x "${TMP_DIR}/syncide"
mv -f "${TMP_DIR}/syncide" "${INSTALL_DIR}/syncide"

add_to_rc() {
  rc_file="$1"
  line="export PATH=\"${INSTALL_DIR}:\$PATH\""
  if [ -f "$rc_file" ]; then
    if ! grep -F "$INSTALL_DIR" "$rc_file" >/dev/null 2>&1; then
      printf '\n# syncide\n%s\n' "$line" >> "$rc_file"
      echo "Updated ${rc_file}"
    fi
  fi
}

case ":${PATH}:" in
  *":${INSTALL_DIR}:"*)
    ;;
  *)
    add_to_rc "$HOME/.bashrc"
    add_to_rc "$HOME/.zshrc"
    if [ ! -f "$HOME/.bashrc" ] && [ ! -f "$HOME/.zshrc" ]; then
      touch "$HOME/.profile"
      add_to_rc "$HOME/.profile"
    fi
    if [ -d "$HOME/.config/fish" ]; then
      mkdir -p "$HOME/.config/fish/conf.d"
      fish_cfg="$HOME/.config/fish/conf.d/syncide.fish"
      if [ ! -f "$fish_cfg" ]; then
        printf 'fish_add_path "%s"\n' "$INSTALL_DIR" > "$fish_cfg"
        echo "Updated ${fish_cfg}"
      fi
    fi
    echo "Restart your shell or run: export PATH=\"${INSTALL_DIR}:\$PATH\""
    ;;
esac

echo "Installed syncide -> ${INSTALL_DIR}/syncide"
echo "Run 'syncide status' or 'syncide init' to start."
