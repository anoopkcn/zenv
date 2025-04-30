#!/bin/bash

# Exit on error, unset variable, or pipe failure
set -euo pipefail

# --- Configuration ---
GITHUB_REPO="anoopkcn/zenv"
INSTALL_DIR_DEFAULT="${HOME}/.local/bin"
INSTALL_DIR="${ZENV_INSTALL_DIR:-$INSTALL_DIR_DEFAULT}" # Allow override
EXE_NAME="zenv"

# --- Helper Functions ---

# Print message in blue
ohai() {
  printf '\033[1;34m==>\033[1;39m %s\033[0m\n' "$@"
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

ohai "Detected OS: ${OS}"
ohai "Detected Arch: ${ARCH}"
ohai "Installation target: ${INSTALL_DIR}/${EXE_NAME}"

# --- Fetch Latest Release Information ---

API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
ohai "Fetching latest release information from GitHub..."

# Use curl to get the JSON response, handle potential errors
# -s: silent, -S: show error, -L: follow redirects
# Use a temporary file for the response to handle potential large outputs
api_response_file=$(mktemp) # Define here so cleanup trap works
if ! curl -sSL --fail -o "$api_response_file" "$API_URL"; then
  # Attempt to read error from GitHub API response if possible
  api_error=$(grep -o '"message": *"[^"]*"' "$api_response_file" | sed 's/"message": *"//; s/"$//' || echo "Unknown error")
  abort "Failed to fetch release info from ${API_URL}. GitHub API Error: ${api_error}"
fi

# Construct the expected asset filename based on the detected platform and naming convention
# Example: zenv-x86_64-linux-musl-small.tar.gz
# Example: zenv-aarch64-macos-small.tar.gz
ASSET_NAME_BASE="${EXE_NAME}-${ARCH}-${OS}"
if [ "$OS" == "linux" ]; then
  # Append '-musl' for Linux builds as per the naming convention
  ASSET_NAME="${ASSET_NAME_BASE}-musl-small.tar.gz"
else
  # Assume non-Linux builds don't have '-musl'
  ASSET_NAME="${ASSET_NAME_BASE}-small.tar.gz"
fi

ohai "Constructed expected asset name: ${ASSET_NAME}"

# Extract the download URL for the specific asset
# This uses grep and sed to parse the JSON. It's less robust than jq but avoids a dependency.
# 1. Find lines containing "browser_download_url"
# 2. Filter those lines for the specific ASSET_NAME using fixed string matching (-F)
# 3. Extract the URL part using sed
DOWNLOAD_URL=$(grep '"browser_download_url":' "$api_response_file" | grep -F "${ASSET_NAME}" | sed -E 's/.*"browser_download_url": ?"([^"]+)".*/\1/')

# Clean up the API response file now that we're done with it
rm -f "$api_response_file"; unset api_response_file

if [ -z "$DOWNLOAD_URL" ]; then
  abort "Could not find download URL for asset '${ASSET_NAME}' for the latest release. Check releases page: https://github.com/${GITHUB_REPO}/releases"
fi

ohai "Found download URL: ${DOWNLOAD_URL}"

# --- Download and Install ---

# Create the installation directory if it doesn't exist
if ! mkdir -p "${INSTALL_DIR}"; then
  abort "Failed to create installation directory: ${INSTALL_DIR}. Check permissions."
fi
ohai "Ensured installation directory exists: ${INSTALL_DIR}"

# Define the final path for the executable
INSTALL_PATH="${INSTALL_DIR}/${EXE_NAME}"

# Download archive to a temporary file first
# Use a template compatible with both BSD and GNU mktemp
TMP_DOWNLOAD_PATH=$(mktemp "${TMPDIR:-/tmp}/zenv-download-XXXXXX") # Define here so cleanup trap works
ohai "Downloading ${ASSET_NAME} to temporary file: ${TMP_DOWNLOAD_PATH}"

if ! curl -SL --progress-bar --fail -o "${TMP_DOWNLOAD_PATH}" "${DOWNLOAD_URL}"; then
  abort "Failed to download archive ${ASSET_NAME} from ${DOWNLOAD_URL}"
fi
ohai "Download complete."

# Create a temporary directory for extraction
TMP_EXTRACT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/zenv-extract-XXXXXX") # Define here so cleanup trap works
ohai "Extracting archive to temporary directory: ${TMP_EXTRACT_DIR}"

# Extract the archive
# -x: extract, -z: gzip, -f: file, -C: change to directory
if ! tar -xzf "${TMP_DOWNLOAD_PATH}" -C "${TMP_EXTRACT_DIR}"; then
   abort "Failed to extract archive: ${TMP_DOWNLOAD_PATH}"
fi

# Assume the executable is directly inside the extracted archive
EXTRACTED_EXE_PATH="${TMP_EXTRACT_DIR}/${EXE_NAME}"

if [ ! -f "${EXTRACTED_EXE_PATH}" ]; then
    abort "Executable '${EXE_NAME}' not found within the extracted archive at ${TMP_EXTRACT_DIR}."
fi
ohai "Found executable: ${EXTRACTED_EXE_PATH}"

# Make the extracted file executable
if ! chmod +x "${EXTRACTED_EXE_PATH}"; then
  abort "Failed to make the extracted file executable: ${EXTRACTED_EXE_PATH}"
fi
ohai "Made extracted file executable."

# Move the temporary file to the final installation path
# This is an atomic operation on most filesystems, ensuring we don't have a partial file
if ! mv "${EXTRACTED_EXE_PATH}" "${INSTALL_PATH}"; then
  abort "Failed to move executable to final location: ${INSTALL_PATH}"
fi
ohai "Installed ${EXE_NAME} to ${INSTALL_PATH}"

# Clean up temporary files (downloaded archive, extraction dir) - handled by trap

# --- Post-Installation ---

ohai "Installation successful!"

# Check if the installation directory is in the PATH
if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
  warn "${INSTALL_DIR} is not currently in your PATH."
  ohai "Next steps:"
  echo "- Add the installation directory to your PATH:"
  echo
  # Provide specific instructions based on common shells
  case "${SHELL}" in
    */bash*)
      PROFILE_FILE=~/.bashrc
      if [[ "$(uname -s)" == "Darwin" ]] && [[ -f ~/.bash_profile ]]; then
          # macOS prefers .bash_profile for login shells if it exists
          PROFILE_FILE=~/.bash_profile
      fi
      echo "  # For Bash, add the following line to your ${PROFILE_FILE}:"
      echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
      echo
      echo "  # Then, run this command to update your current session:"
      echo "  source \"${PROFILE_FILE}\" || export PATH=\"${INSTALL_DIR}:\$PATH\""
      ;;
    */zsh*)
      PROFILE_FILE=~/.zshrc
      echo "  # For Zsh, add the following line to your ${PROFILE_FILE}:"
      echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
      echo
      echo "  # Then, run this command to update your current session:"
      echo "  source \"${PROFILE_FILE}\" || export PATH=\"${INSTALL_DIR}:\$PATH\""
      ;;
    */fish*)
      PROFILE_FILE=~/.config/fish/config.fish
      echo "  # For Fish, add the following line to your ${PROFILE_FILE} (if not already present):"
      echo "  if not string match -q -- \"${INSTALL_DIR}\" \$fish_user_paths"
      echo "      set -U fish_user_paths ${INSTALL_DIR} \$fish_user_paths"
      echo "  end"
      echo
      echo "  # Then, run this command to update your current session:"
      echo "  source \"${PROFILE_FILE}\""
      ;;
    *)
      echo "  # Add ${INSTALL_DIR} to your PATH environment variable."
      echo "  # The method depends on your shell. For many shells, you can add"
      echo "  # the following line to your shell's profile file (e.g., ~/.profile):"
      echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
      echo "  # Remember to restart your shell or source the profile file."
      ;;
  esac
else
  ohai "Next steps:"
  echo "- ${INSTALL_DIR} is already in your PATH."
fi

# Updated help command based on zenv's usage
echo "- Run '${EXE_NAME} help' to get started."

exit 0
