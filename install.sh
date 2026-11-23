#!/usr/bin/env sh
set -eu

# ==============================================================================
# pak — One-Line Shell-Aware Bootstrap Installer (macOS & Linux: zsh, bash, fish)
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/zahei/project-awareness-kit/main/install.sh | sh
# ==============================================================================

REPO_URL="${PAK_REPO_URL:-https://github.com/zahei/project-awareness-kit.git}"
INSTALL_DIR="${PAK_INSTALL_DIR:-$HOME/.local/share/project-awareness-kit}"

if ! command -v git >/dev/null 2>&1; then
    echo "[pak] Error: git is required to install pak." >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "[pak] Error: python3 (3.9+) is required to run pak." >&2
    exit 1
fi

mkdir -p "$(dirname "$INSTALL_DIR")"
if [ -d "$INSTALL_DIR/.git" ]; then
    echo "==> Updating existing pak installation in $INSTALL_DIR..."
    git -C "$INSTALL_DIR" pull --ff-only
else
    echo "==> Cloning project-awareness-kit into $INSTALL_DIR..."
    git clone "$REPO_URL" "$INSTALL_DIR"
fi

python3 "$INSTALL_DIR/pak" install-cli
