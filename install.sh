#!/bin/bash

# Exit on error, unset variable, or pipe failure
set -euo pipefail

# --- Configuration ---
GITHUB_REPO="anoopkcn/zenv"
INSTALL_DIR="${ZENV_INSTALL_DIR:-${HOME}/.local/bin}"
EXE_NAME="zenv"
NO_MODIFY_PATH="${ZENV_NO_MODIFY_PATH:-0}"

# --- Helper Functions ---
ohai() { printf '\033[0;34m==>\033[0;39m %s\033[0m\n' "$@"; }
success() { printf '\033[1;32m==>\033[1;39m %s\033[0m\n' "$@"; }
info() { printf '\033[1;33m==>\033[0m %s\n' "$@"; }
warn() { printf '\033[1;31mWarning\033[0m: %s\n' "$@" >&2; }
abort() { printf '\033[1;31mError\033[0m: %s\n' "$@" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# Clean up temporary files on exit
cleanup() { rm -f "${api_response_file:-}" "${TMP_DOWNLOAD_PATH:-}"; rm -rf "${TMP_EXTRACT_DIR:-}"; }
trap cleanup EXIT ERR INT TERM

# --- Check Requirements ---
for cmd in curl grep sed uname mkdir chmod mktemp mv tar; do
  command_exists "$cmd" || abort "'$cmd' is required but not found."
done

# --- Detect OS and Architecture ---
# Determine OS
OS_TYPE="$(uname -s)"
if [ "$OS_TYPE" = "Linux" ]; then
  OS="linux"
elif [ "$OS_TYPE" = "Darwin" ]; then
  OS="macos"
else
  abort "Unsupported OS: $OS_TYPE"
fi

# Determine architecture
ARCH_TYPE="$(uname -m)"
if [ "$ARCH_TYPE" = "x86_64" ] || [ "$ARCH_TYPE" = "amd64" ]; then
  ARCH="x86_64"
elif [ "$ARCH_TYPE" = "aarch64" ] || [ "$ARCH_TYPE" = "arm64" ]; then
  ARCH="aarch64"
else
  abort "Unsupported architecture: $ARCH_TYPE"
fi

OPT_BUILD='-small'
# Correctly construct asset name based on OS
if [ "$OS" = "linux" ]; then
  ASSET_NAME="${EXE_NAME}-${ARCH}-${OS}-musl${OPT_BUILD}.tar.gz"
else
  ASSET_NAME="${EXE_NAME}-${ARCH}-${OS}${OPT_BUILD}.tar.gz"
fi

ohai "Detected: ${OS} (${ARCH})"
ohai "Installing to: ${INSTALL_DIR}/${EXE_NAME}"

# --- Download Latest Release ---
api_response_file=$(mktemp)
curl -sSL --fail -o "$api_response_file" "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" ||
  abort "Failed to fetch release info. GitHub API Error: $(grep -o '"message": *"[^"]*"' "$api_response_file" | sed 's/"message": *"//; s/"$//' || echo "Unknown error")"

DOWNLOAD_URL=$(grep '"browser_download_url":' "$api_response_file" | grep -F "${ASSET_NAME}" | sed -E 's/.*"browser_download_url": ?"([^"]+)".*/\1/')
rm -f "$api_response_file"; unset api_response_file

[ -z "$DOWNLOAD_URL" ] && abort "Could not find download URL for ${ASSET_NAME} in the latest release."
ohai "Found download URL: ${DOWNLOAD_URL}"

# --- Install Binary ---
mkdir -p "${INSTALL_DIR}" || abort "Failed to create directory: ${INSTALL_DIR}."
TMP_DOWNLOAD_PATH=$(mktemp "${TMPDIR:-/tmp}/zenv-download-XXXXXX")
TMP_EXTRACT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/zenv-extract-XXXXXX")

ohai "Downloading..."
curl -SL --progress-bar --fail -o "${TMP_DOWNLOAD_PATH}" "${DOWNLOAD_URL}" || abort "Download failed"

ohai "Extracting and installing..."
tar -xzf "${TMP_DOWNLOAD_PATH}" -C "${TMP_EXTRACT_DIR}" || abort "Failed to extract archive"
chmod +x "${TMP_EXTRACT_DIR}/${EXE_NAME}" || abort "Failed to make executable"
mv "${TMP_EXTRACT_DIR}/${EXE_NAME}" "${INSTALL_DIR}/${EXE_NAME}" || abort "Failed to install"

success "Installation successful!"

# --- Setup PATH ---
if [ "$NO_MODIFY_PATH" = "1" ]; then
  info "Skipping PATH modification (ZENV_NO_MODIFY_PATH=1)"
elif echo "$PATH" | grep -q "${INSTALL_DIR}"; then
  info "${INSTALL_DIR} is already in your PATH."
else
  info "Adding ${INSTALL_DIR} to your PATH..."

  # For display in messages
  INSTALL_DIR_DISPLAY="${INSTALL_DIR}"
  if [ "${INSTALL_DIR#$HOME}" != "${INSTALL_DIR}" ]; then
    INSTALL_DIR_DISPLAY="~${INSTALL_DIR#$HOME}"
  fi

  # For shell config files
  INSTALL_DIR_EXPR="\$HOME${INSTALL_DIR#$HOME}"
  if [ "${INSTALL_DIR#$HOME}" = "${INSTALL_DIR}" ]; then
    INSTALL_DIR_EXPR="${INSTALL_DIR}"
  fi

  # Update shell config based on detected shell
  SHELL_NAME="${SHELL##*/}"
  UPDATED_FILES=()

  update_config() {
    local config_file="$1"
    local path_line="$2"

    if [ ! -f "$config_file" ]; then
      mkdir -p "$(dirname "$config_file")" 2>/dev/null || true
      touch "$config_file"
    fi

    if ! grep -q "${INSTALL_DIR_EXPR}" "$config_file"; then
      printf '\n# Added by zenv installer\n%s\n' "$path_line" >> "$config_file"
      UPDATED_FILES+=("$config_file")
    fi
  }

  if [ "$SHELL_NAME" = "bash" ]; then
    update_config "${HOME}/.bashrc" "export PATH=\"${INSTALL_DIR_EXPR}:\$PATH\""
    if [ -f "${HOME}/.bash_profile" ]; then
      if ! grep -q '\.bashrc' "${HOME}/.bash_profile"; then
        update_config "${HOME}/.bash_profile" "export PATH=\"${INSTALL_DIR_EXPR}:\$PATH\""
      fi
    fi
  elif [ "$SHELL_NAME" = "zsh" ]; then
    update_config "${HOME}/.zshrc" "export PATH=\"${INSTALL_DIR_EXPR}:\$PATH\""
  elif [ "$SHELL_NAME" = "fish" ]; then
    update_config "${HOME}/.config/fish/config.fish" "set -gx PATH ${INSTALL_DIR_EXPR} \$PATH"
  else
    update_config "${HOME}/.profile" "export PATH=\"${INSTALL_DIR_EXPR}:\$PATH\""
  fi

  if [ ${#UPDATED_FILES[@]} -gt 0 ]; then
    echo
    info "Updated shell configuration files:"
    for file in "${UPDATED_FILES[@]}"; do
      echo "  - $file"
    done

    # Apply the changes immediately
    info "Applying PATH changes to current shell..."
    export PATH="$INSTALL_DIR:$PATH"

    if [ "$SHELL_NAME" = "fish" ]; then
      # For fish shell, we need a different approach for future sessions
      if command_exists fish; then
        fish -c "set -gx PATH \"$INSTALL_DIR\" \$PATH"
      fi
      info "PATH updated for current session (fish shell configuration will apply on next login)"
    else
      success "PATH updated for current session"
    fi
  else
    info "Add this to your shell config: export PATH=\"${INSTALL_DIR_DISPLAY}:\$PATH\""
    # Also update the current session
    export PATH="$INSTALL_DIR:$PATH"
    info "PATH updated for current session only"
  fi
fi

success "Run 'zenv help' to get started."
exit 0
