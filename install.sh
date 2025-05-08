#!/bin/bash

# Exit on error, unset variable, or pipe failure
set -euo pipefail

# --- Configuration ---
GITHUB_REPO="anoopkcn/zenv"
INSTALL_DIR_DEFAULT="${HOME}/.local/bin"
INSTALL_DIR="${ZENV_INSTALL_DIR:-$INSTALL_DIR_DEFAULT}" # Allow override
EXE_NAME="zenv"
NO_MODIFY_PATH="${ZENV_NO_MODIFY_PATH:-0}" # Set to 1 to skip PATH modification

# --- Helper Functions ---

# Print message in blue
ohai() {
  printf '\033[0;34m==>\033[0;39m %s\033[0m\n' "$@"
}

# Print message in green
success() {
  printf '\033[1;32m==>\033[1;39m %s\033[0m\n' "$@"
}

# Print message in yellow
info() {
  printf '\033[1;33m==>\033[0m %s\n' "$@"
}

# Print warning message in red
warn() {
  printf '\033[1;31mWarning\033[0m: %s\n' "$@" >&2
}

# Print error message and exit
abort() {
  printf '\033[1;31mError\033[0m: %s\n' "$@" >&2
  exit 1
}

# Check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Ensure a command executes successfully
ensure() {
    if ! "$@"; then abort "Command failed: $*"; fi
}

# Clean up temporary files/directories on exit or error
cleanup() {
  # Use parameter expansion with :- to avoid errors if variables are unset
  rm -f "${api_response_file:-}" "${TMP_DOWNLOAD_PATH:-}"
  rm -rf "${TMP_EXTRACT_DIR:-}"
}
trap cleanup EXIT ERR INT TERM # Run cleanup on exit, error, interrupt, termination

# --- Pre-flight Checks ---

# Check if running in Bash
if [ -z "${BASH_VERSION:-}" ]; then
  abort "Bash is required to interpret this script."
fi

# Check for required commands
required_commands=("curl" "grep" "sed" "uname" "mkdir" "chmod" "mktemp" "mv" "tar")
for cmd in "${required_commands[@]}"; do
  if ! command_exists "$cmd"; then
    abort "'$cmd' is required but not found. Please install '$cmd'."
  fi
done

# --- Detect OS and Architecture ---

get_os() {
  case "$(uname -s)" in
    Linux*)  echo "linux" ;;
    Darwin*) echo "macos" ;;
    *)       abort "Unsupported operating system: $(uname -s)" ;;
  esac
}

get_arch() {
  case "$(uname -m)" in
    x86_64)  echo "x86_64" ;;
    amd64)   echo "x86_64" ;; # Some systems report amd64
    aarch64) echo "aarch64" ;;
    arm64)   echo "aarch64" ;; # macOS ARM reports arm64
    *)       abort "Unsupported architecture: $(uname -m)" ;;
  esac
}

OS=$(get_os)
ARCH=$(get_arch)
OPT_BUILD='-small'

ohai "Detected OS: ${OS}"
ohai "Detected Arch: ${ARCH}"
ohai "Installation target: ${INSTALL_DIR}/${EXE_NAME}"

# --- Fetch Latest Release Information ---

API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
ohai "Fetching latest release information from GitHub..."

api_response_file=$(mktemp)
if ! curl -sSL --fail -o "$api_response_file" "$API_URL"; then
  api_error=$(grep -o '"message": *"[^"]*"' "$api_response_file" | sed 's/"message": *"//; s/"$//' || echo "Unknown error")
  abort "Failed to fetch release info from ${API_URL}. GitHub API Error: ${api_error}"
fi

ASSET_NAME_BASE="${EXE_NAME}-${ARCH}-${OS}"
if [ "$OS" == "linux" ]; then
  ASSET_NAME="${ASSET_NAME_BASE}-musl${OPT_BUILD}.tar.gz"
else
  ASSET_NAME="${ASSET_NAME_BASE}${OPT_BUILD}.tar.gz"
fi

ohai "Constructed expected asset name: ${ASSET_NAME}"

DOWNLOAD_URL=$(grep '"browser_download_url":' "$api_response_file" | grep -F "${ASSET_NAME}" | sed -E 's/.*"browser_download_url": ?"([^"]+)".*/\1/')

rm -f "$api_response_file"; unset api_response_file

if [ -z "$DOWNLOAD_URL" ]; then
  abort "Could not find download URL for asset '${ASSET_NAME}' for the latest release. Check releases page: https://github.com/${GITHUB_REPO}/releases"
fi

ohai "Found download URL: ${DOWNLOAD_URL}"

# --- Download and Install ---

if ! mkdir -p "${INSTALL_DIR}"; then
  abort "Failed to create installation directory: ${INSTALL_DIR}. Check permissions."
fi
ohai "Ensured installation directory exists: ${INSTALL_DIR}"

INSTALL_PATH="${INSTALL_DIR}/${EXE_NAME}"

TMP_DOWNLOAD_PATH=$(mktemp "${TMPDIR:-/tmp}/zenv-download-XXXXXX")
ohai "Downloading ${ASSET_NAME} to temporary file: ${TMP_DOWNLOAD_PATH}"

if ! curl -SL --progress-bar --fail -o "${TMP_DOWNLOAD_PATH}" "${DOWNLOAD_URL}"; then
  abort "Failed to download archive ${ASSET_NAME} from ${DOWNLOAD_URL}"
fi
ohai "Download complete."

TMP_EXTRACT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/zenv-extract-XXXXXX")
ohai "Extracting archive to temporary directory: ${TMP_EXTRACT_DIR}"

if ! tar -xzf "${TMP_DOWNLOAD_PATH}" -C "${TMP_EXTRACT_DIR}"; then
   abort "Failed to extract archive: ${TMP_DOWNLOAD_PATH}"
fi

EXTRACTED_EXE_PATH="${TMP_EXTRACT_DIR}/${EXE_NAME}"

if [ ! -f "${EXTRACTED_EXE_PATH}" ]; then
    abort "Executable '${EXE_NAME}' not found within the extracted archive at ${TMP_EXTRACT_DIR}."
fi
ohai "Found executable: ${EXTRACTED_EXE_PATH}"

if ! chmod +x "${EXTRACTED_EXE_PATH}"; then
  abort "Failed to make the extracted file executable: ${EXTRACTED_EXE_PATH}"
fi
ohai "Made extracted file executable."

if ! mv "${EXTRACTED_EXE_PATH}" "${INSTALL_PATH}"; then
  abort "Failed to move executable to final location: ${INSTALL_PATH}"
fi
ohai "Installed ${EXE_NAME} to ${INSTALL_PATH}"

# --- Post-Installation ---

success "Installation successful!"

# Replace $HOME with ~ for display purposes if INSTALL_DIR starts with HOME
INSTALL_DIR_DISPLAY_NAME="${INSTALL_DIR}"
if [[ "${INSTALL_DIR}" == "${HOME}"* ]]; then
    INSTALL_DIR_DISPLAY_NAME="~${INSTALL_DIR#"$HOME"}"
fi
# Late-bound expression for shell config files
INSTALL_DIR_EXPR="\$HOME${INSTALL_DIR#"$HOME"}"
if [[ "${INSTALL_DIR_DEFAULT}" != "${HOME}"* ]]; then # If default is not under HOME, use absolute path
    INSTALL_DIR_EXPR="${INSTALL_DIR}"
fi


ENV_SCRIPT_BASENAME="${EXE_NAME}-env"
ENV_SCRIPT_PATH_SH="${INSTALL_DIR}/${ENV_SCRIPT_BASENAME}.sh"
ENV_SCRIPT_PATH_FISH="${INSTALL_DIR}/${ENV_SCRIPT_BASENAME}.fish"
ENV_SCRIPT_PATH_EXPR_SH="${INSTALL_DIR_EXPR}/${ENV_SCRIPT_BASENAME}.sh"
ENV_SCRIPT_PATH_EXPR_FISH="${INSTALL_DIR_EXPR}/${ENV_SCRIPT_BASENAME}.fish"

_write_env_script_sh() {
    local _install_dir_expr="$1"
    local _env_script_path="$2"
    ensure cat <<EOF > "$_env_script_path"
#!/bin/sh
# Add ${EXE_NAME} to PATH if it isn't already there
case ":\${PATH}:" in
    *:"$_install_dir_expr":*)
        ;;
    *)
        export PATH="$_install_dir_expr:\$PATH"
        ;;
esac
EOF
    chmod +x "$_env_script_path"
}

_write_env_script_fish() {
    local _install_dir_expr="$1"
    local _env_script_path="$2"
    ensure cat <<EOF > "$_env_script_path"
# Add ${EXE_NAME} to PATH if it isn't already there
if not string match -q -- "$_install_dir_expr" \$PATH
    set -gx PATH "$_install_dir_expr" \$PATH
end
EOF
    chmod +x "$_env_script_path"
}

_add_to_shell_config() {
    local _env_script_path_expr="$1"
    local _profile_file="$2"
    local _sourcing_line_pretty="source \"${_env_script_path_expr}\""
    # Use . for sh/bash/zsh for better POSIX compatibility in the rc file itself
    local _sourcing_line_robust=". \"${_env_script_path_expr}\""
    local _actual_sourcing_line="${_sourcing_line_robust}"

    # For fish, 'source' is preferred
    if [[ "${_profile_file}" == *".fish" ]]; then
        _actual_sourcing_line="${_sourcing_line_pretty}"
    fi

    if [ ! -f "$_profile_file" ]; then
        info "Profile file ${_profile_file} does not exist. Creating it."
        # Ensure directory exists if it's a nested path like .config/fish/config.fish
        if [[ "${_profile_file}" == *"/"* ]]; then
            ensure mkdir -p "$(dirname "$_profile_file")"
        fi
        ensure touch "$_profile_file"
    fi

    # Check if the sourcing line or its robust variant already exists
    if ! grep -q -e "$_sourcing_line_pretty" -e "$_sourcing_line_robust" "$_profile_file"; then
        info "Adding ${EXE_NAME} to PATH in ${_profile_file}"
        ensure printf '\n# Added by %s installer\n%s\n' "${EXE_NAME}" "${_actual_sourcing_line}" >> "$_profile_file"
        UPDATED_PROFILE_FILES+=("${_profile_file}")
    else
        info "${EXE_NAME} PATH configuration already exists in ${_profile_file}."
    fi
}

UPDATED_PROFILE_FILES=()

if [ "$NO_MODIFY_PATH" = "1" ]; then
    info "Skipping automatic PATH modification because ZENV_NO_MODIFY_PATH is set."
    info "Please add ${INSTALL_DIR_DISPLAY_NAME} to your PATH manually if it's not already there."
elif [[ ":${PATH}:" == *":${INSTALL_DIR}:"* ]]; then
    success "Next steps:"
    info "${INSTALL_DIR_DISPLAY_NAME} is already in your PATH."
else
    success "Next steps:"
    info "${INSTALL_DIR_DISPLAY_NAME} is not currently in your PATH."
    info "Attempting to add it to your shell configuration..."

    # Create the sh/bash/zsh env script
    _write_env_script_sh "${INSTALL_DIR_EXPR}" "${ENV_SCRIPT_PATH_SH}"
    # Create the fish env script
    _write_env_script_fish "${INSTALL_DIR_EXPR}" "${ENV_SCRIPT_PATH_FISH}"

    detected_shell="${SHELL##*/}"

    case "$detected_shell" in
        bash)
            PROFILE_FILE_PRIMARY=~/.bashrc
            PROFILE_FILE_LOGIN=~/.bash_profile # For login shells, often sources .bashrc
            _add_to_shell_config "${ENV_SCRIPT_PATH_EXPR_SH}" "${PROFILE_FILE_PRIMARY}"
            # If .bash_profile exists and doesn't source .bashrc, it might be the one to edit for login shells
            if [ -f "${PROFILE_FILE_LOGIN}" ]; then
                 if ! grep -q '\.bashrc' "${PROFILE_FILE_LOGIN}"; then
                    _add_to_shell_config "${ENV_SCRIPT_PATH_EXPR_SH}" "${PROFILE_FILE_LOGIN}"
                 fi
            else # If .bash_profile doesn't exist, .profile is a common fallback for login shells
                _add_to_shell_config "${ENV_SCRIPT_PATH_EXPR_SH}" ~/.profile
            fi
            ;;
        zsh)
            PROFILE_FILE=~/.zshrc
            _add_to_shell_config "${ENV_SCRIPT_PATH_EXPR_SH}" "${PROFILE_FILE}"
            ;;
        fish)
            PROFILE_FILE=~/.config/fish/config.fish
            _add_to_shell_config "${ENV_SCRIPT_PATH_EXPR_FISH}" "${PROFILE_FILE}"
            ;;
        *)
            # Generic fallback to .profile for other sh-compatible shells
            info "Unsupported shell: ${detected_shell}. Attempting to update ~/.profile."
            PROFILE_FILE=~/.profile
            _add_to_shell_config "${ENV_SCRIPT_PATH_EXPR_SH}" "${PROFILE_FILE}"
            ;;
    esac

    if [ ${#UPDATED_PROFILE_FILES[@]} -gt 0 ]; then
        echo
        info "Successfully updated:"
        for updated_file in "${UPDATED_PROFILE_FILES[@]}"; do
            echo "  - ${updated_file}"
        done
        echo
        info "Please restart your shell or source your profile file(s) for the changes to take effect:"
        for updated_file in "${UPDATED_PROFILE_FILES[@]}"; do
            if [[ "${updated_file}" == *".fish" ]]; then
                 echo "  source \"${updated_file}\"  (for fish shell)"
            else
                 echo "  source \"${updated_file}\"  (for sh/bash/zsh shells)"
            fi
        done
    else
        info "No standard shell configuration files were modified automatically."
        info "Please add the following line to your shell's configuration file (e.g., ~/.bashrc, ~/.zshrc, ~/.profile):"
        echo
        echo "  export PATH=\"${INSTALL_DIR_EXPR}:\$PATH\""
        echo
        info "Then, restart your shell or source the configuration file."
    fi
fi

success "Run '${EXE_NAME} help' to get started."

exit 0
