#!/usr/bin/env bash
# =============================================================================
# PasarGuard WARP Manager - Bootstrap Installer
# -----------------------------------------------------------------------------
# Downloads warp-manager.sh, installs it system-wide and optionally opens the
# interactive menu. All output is in English.
#
# Quick start:
#   curl -fsSL https://raw.githubusercontent.com/XiliService/Warp-Pasarguard/main/install.sh | sudo bash
#
# From a different branch:
#   curl -fsSL <install.sh url> | sudo bash -s -- --branch my-branch
# =============================================================================

set -Eeuo pipefail
umask 022

readonly REPO_OWNER="XiliService"
readonly REPO_NAME="Warp-Pasarguard"
readonly BRANCH_DEFAULT="main"
readonly BRANCH_FALLBACK="arena/01417195-warp-pasarguard"
readonly VERSION="1.0.1"

# When this file is streamed with `curl | bash -s`, BASH_SOURCE[0] is unset.
# Keep a safe, empty default so `set -u` never aborts the installer.
SELF_PATH="${BASH_SOURCE[0]:-}"
BRANCH="${WARP_BRANCH:-$BRANCH_DEFAULT}"
APP_DIR="${WARP_APP_DIR:-/opt/pasarguard-warp}"
BIN_LINK="${WARP_BIN_LINK:-/usr/local/bin/warp-manager}"
NO_MENU=0
LOCAL_FILE=""
INSECURE=0
SOURCE_URL=""

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""
fi

info() { printf '%s %s\n' "${C_GREEN}==>${C_RESET}" "$*"; }
warn() { printf '%s %s\n' "${C_YELLOW}WARN${C_RESET}" "$*" >&2; }
die()  { printf '%s %s\n' "${C_RED}ERROR${C_RESET}" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
PasarGuard WARP Manager - bootstrap installer

Usage:
  curl -fsSL <install.sh> | sudo bash
  ./install.sh [OPTIONS]

Options:
  --branch BRANCH     Git branch to download from (default: main)
  --local PATH        Install from a local warp-manager.sh file (offline)
  --url URL           Direct URL of warp-manager.sh
  --app-dir PATH      Installation directory (default: /opt/pasarguard-warp)
  --bin-link PATH     Symlink path (default: /usr/local/bin/warp-manager)
  --no-menu           Do not open the interactive menu after installing
  --insecure          Skip TLS certificate verification
  --help, -h          Show this help
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --branch)    BRANCH="$2"; shift 2 ;;
    --local)     LOCAL_FILE="$2"; shift 2 ;;
    --url)       SOURCE_URL="$2"; shift 2 ;;
    --app-dir)   APP_DIR="$2"; shift 2 ;;
    --bin-link)  BIN_LINK="$2"; shift 2 ;;
    --no-menu)   NO_MENU=1; shift ;;
    --insecure)  INSECURE=1; shift ;;
    --help|-h)   usage; exit 0 ;;
    *)           die "Unknown option: $1 (use --help)" ;;
  esac
done

[[ "$(id -u)" == "0" ]] || die "Root privileges are required. Run with sudo or as root."
command -v bash >/dev/null 2>&1 || die "bash is required."

HAVE_TOOL=""
for tool in curl wget; do
  if command -v "$tool" >/dev/null 2>&1; then HAVE_TOOL="$tool"; break; fi
done
[[ -n "${HAVE_TOOL:-}" || -n "$LOCAL_FILE" ]] || die "curl or wget is required to download the manager."

download() {
  local url="$1" out="$2"
  if [[ "$HAVE_TOOL" == "curl" ]]; then
    local -a opts=(-fsSL --retry 2 --connect-timeout 12 --max-time 60 \
                   -H 'User-Agent: Warp-Pasarguard' \
                   -H 'Accept: application/vnd.github.raw')
    [[ "$INSECURE" == "1" ]] && opts+=(-k)
    curl "${opts[@]}" -o "$out" "$url"
  else
    local -a opts=(-q --header='User-Agent: Warp-Pasarguard' \
                       --header='Accept: application/vnd.github.raw')
    [[ "$INSECURE" == "1" ]] && opts+=(--no-check-certificate)
    wget "${opts[@]}" -O "$out" "$url"
  fi
}

printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "=======================================================================" "$C_RESET"
printf '%s  PasarGuard WARP Manager - Bootstrap Installer v%s%s\n' "$C_BOLD$C_CYAN" "$VERSION" "$C_RESET"
printf '%s%s%s\n' "$C_BOLD$C_CYAN" "=======================================================================" "$C_RESET"

TMP_FILE="$(mktemp)"
trap 'rm -f -- "$TMP_FILE"' EXIT

SOURCE_USED=""
if [[ -n "$LOCAL_FILE" ]]; then
  [[ -f "$LOCAL_FILE" ]] || die "Local file not found: ${LOCAL_FILE}"
  cp -f -- "$LOCAL_FILE" "$TMP_FILE"
  SOURCE_USED="local:${LOCAL_FILE}"
else
  local_dir="."
  if [[ -n "$SELF_PATH" && -f "$SELF_PATH" ]]; then
    local_dir="$(cd "$(dirname "$SELF_PATH")" 2>/dev/null && pwd || printf '.')"
  fi
  local_candidate="$local_dir/warp-manager.sh"
  invoked_from_file=0
  [[ -n "$SELF_PATH" && "$SELF_PATH" == *install.sh && -f "$SELF_PATH" ]] && invoked_from_file=1
  if [[ "$invoked_from_file" == "1" && -f "$local_candidate" ]]; then
    cp -f -- "$local_candidate" "$TMP_FILE"
    SOURCE_USED="local:${local_candidate}"
  else
    urls=()
    if [[ -n "$SOURCE_URL" ]]; then
      urls+=("$SOURCE_URL")
    else
      branches=("$BRANCH")
      [[ "$BRANCH" != "$BRANCH_FALLBACK" ]] && branches+=("$BRANCH_FALLBACK")
      cache_bust="$(date +%s)"
      for b in "${branches[@]}"; do
        # api.github.com is not CDN-cached, so a just-pushed fix is visible
        # immediately. raw CDN mirrors stay as fallbacks.
        urls+=("https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/warp-manager.sh?ref=${b}&v=${cache_bust}")
        urls+=("https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${b}/warp-manager.sh?v=${cache_bust}")
        urls+=("https://github.com/${REPO_OWNER}/${REPO_NAME}/raw/refs/heads/${b}/warp-manager.sh?v=${cache_bust}")
      done
    fi
    for u in "${urls[@]}"; do
      info "Trying ${u}"
      if download "$u" "$TMP_FILE" 2>/dev/null; then SOURCE_USED="$u"; break; fi
    done
  fi
fi

[[ -n "$SOURCE_USED" ]] || die "Could not obtain warp-manager.sh. Use --local PATH or check network access."
[[ -s "$TMP_FILE" ]] || die "Downloaded file is empty."
head -n1 "$TMP_FILE" | grep -q '^#!.*bash' || die "Downloaded file is not a bash script."
bash -n "$TMP_FILE" || die "Downloaded script has syntax errors. Aborting."
info "Source: ${SOURCE_USED}"

mkdir -p "$APP_DIR" "$APP_DIR/profiles" "$APP_DIR/outbound" "$APP_DIR/backups" "$APP_DIR/logs" "$APP_DIR/bin"
chmod 700 "$APP_DIR" "$APP_DIR/profiles" 2>/dev/null || true
install -m 0755 "$TMP_FILE" "$APP_DIR/warp-manager.sh"
mkdir -p "$(dirname "$BIN_LINK")"
ln -sfn "$APP_DIR/warp-manager.sh" "$BIN_LINK"

printf '\n'
info "Installed: ${APP_DIR}/warp-manager.sh"
info "Command  : ${BIN_LINK}"
printf '\n'
printf '  Run the interactive menu : %ssudo warp-manager%s\n' "$C_BOLD" "$C_RESET"
printf '  Direct commands         : %ssudo warp-manager install | remove | update | logs | status%s\n' "$C_BOLD" "$C_RESET"
printf '\n'

if [[ "$NO_MENU" == "0" && -r /dev/tty && -w /dev/tty ]] && [[ -t 1 ]]; then
  info "Opening the interactive menu..."
  exec "$BIN_LINK" menu
fi

info "Done."
