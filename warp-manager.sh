#!/usr/bin/env bash
# =============================================================================
# PasarGuard WARP Manager
# -----------------------------------------------------------------------------
# Install, remove, update, inspect and troubleshoot Cloudflare WARP on a
# PasarGuard panel / node infrastructure.
#
# All runtime messages, menus, logs and generated files are in English.
# Repository: https://github.com/XiliService/Warp-Pasarguard
# =============================================================================

set -Eeuo pipefail
umask 022

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly APP_NAME="PasarGuard WARP Manager"
readonly SCRIPT_VERSION="1.0.3"
readonly REPO_OWNER="XiliService"
readonly REPO_NAME="Warp-Pasarguard"
readonly REPO_BRANCH_DEFAULT="main"
readonly REPO_BRANCH_FALLBACK="arena/01417195-warp-pasarguard"
readonly WGCF_REPO="ViRb3/wgcf"
readonly WGCF_VERSION_DEFAULT="v2.2.22"
readonly MIN_XRAY_VERSION="1.8.3"
readonly TAG_PREFIX="warp"
readonly BALANCER_TAG="warp-pool"
readonly DEFAULT_DOMAINS="geosite:google,openai.com,ai.com,ipinfo.io,iplocation.net,spotify.com"
readonly DEFAULT_ENDPOINT="engage.cloudflareclient.com:2408"

readonly APP_DIR="${WARP_APP_DIR:-/opt/pasarguard-warp}"
readonly BIN_LINK="${WARP_BIN_LINK:-/usr/local/bin/warp-manager}"
readonly STATE_FILE="$APP_DIR/state.env"
readonly PROFILE_DIR="$APP_DIR/profiles"
readonly OUTPUT_DIR="$APP_DIR/outbound"
readonly BACKUP_DIR="$APP_DIR/backups"
readonly LOG_DIR="$APP_DIR/logs"
readonly LOG_FILE="$LOG_DIR/warp-manager.log"
readonly BIN_DIR="$APP_DIR/bin"
readonly WGCF_BIN="$BIN_DIR/wgcf"
readonly WG_DIR="/etc/wireguard"
readonly COMPOSE_HINTS="/opt/pg-node /opt/pasarguard-node /opt/pasarguard /etc/opt/pasarguard"

# Cloudflare WARP WireGuard endpoints. Used only for per-IP kernel bindings
# where each tunnel must leave from a different source address.
readonly WARP_ENDPOINTS=(
  "162.159.192.1:2408"
  "162.159.192.2:2408"
  "162.159.193.1:2408"
  "162.159.195.1:2408"
  "188.114.96.1:2408"
  "188.114.97.1:2408"
  "188.114.98.1:2408"
  "188.114.99.1:2408"
)

# -----------------------------------------------------------------------------
# Runtime options (overridable from the command line / environment)
# -----------------------------------------------------------------------------
COMMAND=""
MODE="${WARP_MODE:-}"
TARGET="${WARP_TARGET:-}"
BINDING="${WARP_BINDING:-single}"
SRC_IP="${WARP_SRC_IP:-}"
LABEL="${WARP_LABEL:-}"
ENDPOINT="${WARP_ENDPOINT:-$DEFAULT_ENDPOINT}"
ROUTING="${WARP_ROUTING:-domains}"
DOMAINS_CSV="${WARP_DOMAINS:-$DEFAULT_DOMAINS}"
LICENSE_KEY="${WARP_LICENSE_KEY:-}"
PANEL_URL="${PANEL_URL:-}"
PANEL_USER="${PANEL_USER:-}"
PANEL_PASS="${PANEL_PASS:-}"
PANEL_TOKEN="${PANEL_TOKEN:-}"
PANEL_CORE_ID="${PANEL_CORE_ID:-}"
APPLY_PANEL="${WARP_APPLY_PANEL:-auto}"
WGCF_VERSION="${WGCF_VERSION:-$WGCF_VERSION_DEFAULT}"
REPO_BRANCH="${WARP_BRANCH:-$REPO_BRANCH_DEFAULT}"
UPDATE_URL="${WARP_UPDATE_URL:-}"
ASSUME_YES="${WARP_YES:-0}"
DRY_RUN="${WARP_DRY_RUN:-0}"
FORCE="${WARP_FORCE:-0}"
INSECURE="${WARP_INSECURE:-0}"
UPDATE_CHECK_ONLY=0
LOG_LINES=80
LOG_FOLLOW=0
MODERN_XRAY=0
REMOVE_ALL=0
BINDING_PRESET="${WARP_BINDING:+1}"
BINDING_PRESET="${BINDING_PRESET:-0}"

# Per-IP settings populated by the wizard or by the non-interactive defaults.
declare -a PERIP_IPS=()
declare -a PERIP_LABELS=()
PERIP_LABELS_CSV="${WARP_LABELS:-}"

# Internal state (detection globals are always defined, even when sourced)
declare -a DETECTED_IPS=() DETECTED_IFACES=()
OS_ID="unknown"; OS_VER="unknown"; ARCH="unknown"; KERNEL="unknown"
WGCF_ARCH="amd64"; DETECTED_ROLE="unknown"
PRIMARY_IP=""; DEFAULT_ROUTE=""; DEFAULT_GW=""; DEFAULT_DEV=""
XRAY_VERSION="unknown"; COMPOSE_SERVICES=""
COMPOSE_CONTAINER=""; COMPOSE_SERVICE_HINT=""
ROUTE_GUARD=0
ROUTE_BEFORE=""
COMPOSE_FILE=""
COMPOSE_SERVICES=""
PANEL_ACCESS_TOKEN=""
RULE_PREPEND=1

# -----------------------------------------------------------------------------
# Colours (only when attached to a terminal)
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

# -----------------------------------------------------------------------------
# Output + logging
# -----------------------------------------------------------------------------
log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo 'unknown')"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  if [[ -w "$LOG_DIR" ]]; then
    printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >>"$LOG_FILE" 2>/dev/null || true
  fi
  case "$level" in
    INFO)  printf '%s %s\n' "${C_GREEN}==>${C_RESET}" "$msg" ;;
    WARN)  printf '%s %s\n' "${C_YELLOW}WARN${C_RESET}" "$msg" >&2 ;;
    ERROR) printf '%s %s\n' "${C_RED}ERROR${C_RESET}" "$msg" >&2 ;;
    DEBUG) [[ "${WARP_DEBUG:-0}" == "1" ]] && printf '%s %s\n' "${C_DIM}debug${C_RESET}" "$msg" >&2 || true ;;
    *)     printf '    %s\n' "$msg" ;;
  esac
}

info()  { log INFO "$@"; }
warn()  { log WARN "$@"; }
error() { log ERROR "$@"; }
die()   { error "$*"; exit 1; }
ok()    { printf '%s %s\n' "${C_GREEN}OK${C_RESET}" "$*"; }
bad()   { printf '%s %s\n' "${C_RED}FAIL${C_RESET}" "$*"; }

header() {
  printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"
  printf '%s\n' "------------------------------------------------------------------------"
}

line() { printf '%s\n' "------------------------------------------------------------------------"; }

# -----------------------------------------------------------------------------
# Small helpers
# -----------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

now_tag() { date -u '+%Y%m%d-%H%M%S'; }

ui_read() {
  local prompt="$1" value=""
  printf '%s' "$prompt" >&2
  if [[ -r /dev/tty && -w /dev/tty ]] && IFS= read -r value </dev/tty; then
    printf '%s' "$value"
    return 0
  fi
  if IFS= read -r value; then
    printf '%s' "$value"
    return 0
  fi
  return 1
}

ui_read_secret() {
  local prompt="$1" value=""
  printf '%s' "$prompt" >&2
  if [[ -r /dev/tty && -w /dev/tty ]] && IFS= read -r -s value </dev/tty; then
    printf '\n' >&2
    printf '%s' "$value"
    return 0
  fi
  if IFS= read -r -s value; then
    printf '\n' >&2
    printf '%s' "$value"
    return 0
  fi
  return 1
}

confirm() {
  local question="$1" default="${2:-n}" answer
  if [[ "$ASSUME_YES" == "1" ]]; then
    log DEBUG "Auto-confirmed: $question"
    return 0
  fi
  answer="$(ui_read "$question [y/N]: ")" || return 1
  answer="${answer,,}"
  [[ -z "$answer" && "$default" == "y" ]] && return 0
  [[ "$answer" == "y" || "$answer" == "yes" ]]
}

choose() {
  local title="$1"; shift
  local -a options=("$@")
  local i choice
  printf '\n%s%s%s\n' "$C_BOLD" "$title" "$C_RESET" >&2
  for i in "${!options[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${options[$i]}" >&2
  done
  while true; do
    choice="$(ui_read "Select [1-${#options[@]}]: ")" || return 1
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      printf '%s' "$choice"
      return 0
    fi
    warn "Invalid selection. Enter a number between 1 and ${#options[@]}."
  done
}

safe_name() {
  local s="$1"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-' | sed 's/^-*//; s/-*$//')"
  [[ -n "$s" ]] || s="profile"
  printf '%s' "${s:0:12}"
}

is_valid_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a _pg_parts <<<"$ip"
  for o in "${_pg_parts[@]}"; do (( o >= 0 && o <= 255 )) || return 1; done
  return 0
}

version_ge() {
  # version_ge A B -> true when A >= B (numeric dotted versions)
  [[ "$1" == "$2" ]] && return 0
  local IFS=.
  local -a a=($1) b=($2)
  local i
  for i in 0 1 2 3; do
    local x="${a[$i]:-0}" y="${b[$i]:-0}"
    x="${x//[^0-9]/}"; y="${y//[^0-9]/}"
    x="${x:-0}"; y="${y:-0}"
    if (( 10#$x > 10#$y )); then return 0; fi
    if (( 10#$x < 10#$y )); then return 1; fi
  done
  return 0
}

fetch() {
  local url="$1" out="$2"
  local -a opts=(-fsSL --retry 3 --retry-delay 2 --connect-timeout 12 --max-time 90 \
                 -H 'User-Agent: Warp-Pasarguard' \
                 -H 'Accept: application/vnd.github.raw')
  [[ "$INSECURE" == "1" ]] && opts+=(-k)
  curl "${opts[@]}" -o "$out" "$url"
}

fetch_stdout() {
  local url="$1"
  local -a opts=(-fsSL --retry 2 --retry-delay 2 --connect-timeout 12 --max-time 60)
  [[ "$INSECURE" == "1" ]] && opts+=(-k)
  curl "${opts[@]}" "$url"
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  mkdir -p "$BACKUP_DIR"
  local b="$BACKUP_DIR/$(basename "$f").$(now_tag).bak"
  cp -a -- "$f" "$b"
  chmod 600 "$b" 2>/dev/null || true
  echo "$b"
}

atomic_write() {
  local path="$1" content="$2" mode="${3:-0644}" tmp
  mkdir -p "$(dirname "$path")"
  tmp="$(mktemp "$(dirname "$path")/.tmp.XXXXXX")"
  printf '%s' "$content" >"$tmp"
  chmod "$mode" "$tmp"
  mv -f -- "$tmp" "$path"
}

run_system() {
  # Wrapper for mutating system commands, honouring dry-run mode.
  if [[ "$DRY_RUN" == "1" ]]; then
    log INFO "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

# -----------------------------------------------------------------------------
# State
# -----------------------------------------------------------------------------
state_init() {
  mkdir -p "$APP_DIR" "$PROFILE_DIR" "$OUTPUT_DIR" "$BACKUP_DIR" "$LOG_DIR" "$BIN_DIR" 2>/dev/null || true
  chmod 700 "$APP_DIR" "$PROFILE_DIR" 2>/dev/null || true
  if [[ -w "$APP_DIR" && ! -f "$STATE_FILE" ]]; then
    atomic_write "$STATE_FILE" "# PasarGuard WARP Manager state\n" 0600 || true
  fi
}

state_get() {
  local key="$1" default="${2:-}"
  local value=""
  if [[ -f "$STATE_FILE" ]]; then
    value="$(sed -n "s/^${key}=//p" "$STATE_FILE" | tail -n1)"
    if [[ -n "$value" ]]; then
      eval "value=$value" 2>/dev/null || value="$default"
    else
      value="$default"
    fi
  fi
  printf '%s' "${value:-$default}"
}

state_set() {
  local key="$1" value="$2" tmp
  state_init
  tmp="$(mktemp "$APP_DIR/.state.XXXXXX")"
  if [[ -f "$STATE_FILE" ]]; then
    grep -v "^${key}=" "$STATE_FILE" >"$tmp" || true
  fi
  printf '%s=%q\n' "$key" "$value" >>"$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$STATE_FILE"
}

state_set_many() {
  local pair key value
  for pair in "$@"; do
    key="${pair%%=*}"; value="${pair#*=}"
    state_set "$key" "$value"
  done
}

is_installed() {
  [[ -f "$STATE_FILE" ]] && [[ "$(state_get INSTALLED 0)" == "1" ]]
}

profile_list() {
  state_get PROFILES ""
}

profile_meta() {
  local name="$1" key="$2" default="${3:-}"
  local f="$PROFILE_DIR/$name/meta.env"
  [[ -f "$f" ]] || { printf '%s' "$default"; return 0; }
  local v=""
  v="$(sed -n "s/^${key}=//p" "$f" | tail -n1)"
  if [[ -n "$v" ]]; then eval "v=$v" 2>/dev/null || v="$default"; else v="$default"; fi
  printf '%s' "${v:-$default}"
}

profile_meta_set() {
  local name="$1" key="$2" value="$3" tmp
  local f="$PROFILE_DIR/$name/meta.env"
  mkdir -p "$PROFILE_DIR/$name"
  tmp="$(mktemp "$PROFILE_DIR/$name/.meta.XXXXXX")"
  [[ -f "$f" ]] && grep -v "^${key}=" "$f" >"$tmp" || true
  printf '%s=%q\n' "$key" "$value" >>"$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$f"
}

# -----------------------------------------------------------------------------
# Environment detection
# -----------------------------------------------------------------------------
detect_os() {
  local id="" ver=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    id="$(. /etc/os-release; printf '%s' "${ID:-}")"
    ver="$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")"
  fi
  OS_ID="${id:-unknown}"
  OS_VER="${ver:-unknown}"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)  WGCF_ARCH="amd64" ;;
    aarch64) WGCF_ARCH="arm64" ;;
    i386|i686) WGCF_ARCH="386" ;;
    armv7l|armv6l) WGCF_ARCH="armv7" ;;
    *) WGCF_ARCH="amd64"; warn "Unknown architecture '$ARCH', falling back to amd64 binary." ;;
  esac
  KERNEL="$(uname -r)"
}

detect_role() {
  local role="unknown" panel=0 node=0 images="" line
  if have docker; then
    images="$(docker ps --format '{{.Image}}' 2>/dev/null || true)"
    while IFS= read -r line; do
      case "$line" in
        *pasarguard/panel*|*pasarguard-panel*) panel=1 ;;
        *pasarguard/node*|*pg-node*) node=1 ;;
      esac
    done <<<"$images"
  fi
  if [[ -f /opt/pasarguard/docker-compose.yml ]]; then panel=1; fi
  if [[ -f /var/lib/pasarguard/xray_config.json && "$node" -eq 0 ]]; then panel=1; fi
  if [[ -f /opt/pg-node/docker-compose.yml || -d /var/lib/pg-node ]]; then node=1; fi
  if (( panel == 1 && node == 1 )); then role="panel+node"
  elif (( node == 1 )); then role="node"
  elif (( panel == 1 )); then role="panel"
  fi
  DETECTED_ROLE="$role"
  return 0
}

detect_ips() {
  local -a ips=() ifaces=()
  local line ip iface
  while read -r line; do
    [[ -n "$line" ]] || continue
    iface="$(awk '{print $2}' <<<"$line")"
    ip="$(awk '{split($4,a,"/"); print a[1]}' <<<"$line")"
    case "$iface" in
      lo|docker*|br-*|veth*|wg*|tailscale*|virbr*|tun*) continue ;;
    esac
    is_valid_ipv4 "$ip" || continue
    [[ "$ip" == 169.254.* || "$ip" == 127.* ]] && continue
    ips+=("$ip"); ifaces+=("$iface")
  done < <(ip -4 -o addr show scope global 2>/dev/null || true)
  DETECTED_IPS=("${ips[@]+"${ips[@]}"}")
  DETECTED_IFACES=("${ifaces[@]+"${ifaces[@]}"}")
  PRIMARY_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
  [[ -n "$PRIMARY_IP" ]] || PRIMARY_IP="${DETECTED_IPS[0]:-unknown}"
  DEFAULT_ROUTE="$(ip -4 route show default 2>/dev/null | head -n1)"
  DEFAULT_GW="$(awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}' <<<"$DEFAULT_ROUTE")"
  DEFAULT_DEV="$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' <<<"$DEFAULT_ROUTE")"
}

print_environment() {
  printf '  %-22s %s\n' "Hostname" "$(hostname 2>/dev/null || echo unknown)"
  printf '  %-22s %s\n' "OS" "$OS_ID $OS_VER ($ARCH, kernel $KERNEL)"
  printf '  %-22s %s\n' "Detected role" "$DETECTED_ROLE"
  printf '  %-22s %s\n' "Primary egress IP" "$PRIMARY_IP"
  printf '  %-22s %s\n' "Default route" "${DEFAULT_ROUTE:-not found}"
  if (( ${#DETECTED_IPS[@]} > 0 )); then
    local i
    printf '  %-22s %s\n' "Global IPv4 addresses" "${#DETECTED_IPS[@]}"
    for i in "${!DETECTED_IPS[@]}"; do
      printf '    - %-18s via %s\n' "${DETECTED_IPS[$i]}" "${DETECTED_IFACES[$i]}"
    done
  fi
}

detect_compose() {
  local d f name cfg image hint
  COMPOSE_FILE=""
  COMPOSE_CONTAINER=""
  COMPOSE_SERVICE_HINT=""

  # Ask Docker Compose itself where each running container came from. This is
  # more reliable than path guessing, and lets us prefer the NODE container
  # (whose Xray process actually executes the WARP outbound).
  if have docker; then
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      cfg="$(docker inspect "$name" \
              --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' 2>/dev/null || true)"
      cfg="${cfg%%,*}"
      [[ -n "$cfg" && "$cfg" != "<no value>" && -f "$cfg" ]] || continue
      hint="$(docker inspect "$name" \
              --format '{{ index .Config.Labels "com.docker.compose.service" }}' 2>/dev/null || true)"
      [[ "$hint" == "<no value>" ]] && hint=""
      image="$(docker inspect "$name" --format '{{.Config.Image}}' 2>/dev/null || true)"
      if [[ "$name" == *node* || "$image" == *node* || "$cfg" == *pg-node* ]]; then
        COMPOSE_FILE="$cfg"; COMPOSE_CONTAINER="$name"; COMPOSE_SERVICE_HINT="$hint"
        return 0
      fi
      if [[ -z "$COMPOSE_FILE" ]]; then
        COMPOSE_FILE="$cfg"; COMPOSE_CONTAINER="$name"; COMPOSE_SERVICE_HINT="$hint"
      fi
    done < <(docker ps --format '{{.Names}}' 2>/dev/null || true)
    [[ -n "$COMPOSE_FILE" ]] && return 0
  fi

  for d in ${COMPOSE_HINTS} "${PG_COMPOSE_DIR:-}" "$(pwd)"; do
    [[ -n "$d" && -d "$d" ]] || continue
    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
      if [[ -f "$d/$f" ]]; then COMPOSE_FILE="$d/$f"; return 0; fi
    done
  done
  return 1
}

compose_services() {
  [[ -n "$COMPOSE_FILE" ]] || { COMPOSE_SERVICES=""; return 0; }
  COMPOSE_SERVICES="$(python3 - "$COMPOSE_FILE" <<'PY'
import re, sys
path = sys.argv[1]
lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
start = None
for i, l in enumerate(lines):
    if re.match(r'^services\s*:\s*(#.*)?$', l):
        start = i
        break
if start is None:
    sys.exit(0)
indent = None
out = []
for l in lines[start+1:]:
    if l.strip() == "" or l.lstrip().startswith("#"):
        continue
    n = len(l) - len(l.lstrip())
    if n == 0:
        break
    if indent is None:
        indent = n
    if n == indent:
        m = re.match(r'^\s*([A-Za-z0-9_.-]+)\s*:\s*(#.*)?$', l)
        if m:
            out.append(m.group(1))
print(",".join(out))
PY
)"
}

detect_xray_version() {
  local v="" name
  local -a containers=()
  if have docker; then
    while IFS= read -r name; do
      [[ -n "$name" ]] && containers+=("$name")
    done < <(docker ps --format '{{.Names}}' 2>/dev/null || true)
    for name in "${containers[@]}"; do
      v="$(docker exec "$name" xray version 2>/dev/null | grep -oiE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
      [[ -n "$v" ]] && break
    done
  fi
  [[ -z "$v" ]] && have xray && v="$(xray version 2>/dev/null | grep -oiE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  [[ -z "$v" ]] && v="$(find /var/lib/pg-node /var/lib/pasarguard /usr/local/bin -maxdepth 3 -name 'xray' -type f -perm -u+x 2>/dev/null | head -n1 | xargs -r -I{} {} version 2>/dev/null | grep -oiE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  XRAY_VERSION="${v:-unknown}"
  return 0
}

# -----------------------------------------------------------------------------
# Prerequisites / wgcf
# -----------------------------------------------------------------------------
install_packages() {
  local -a pkgs=(curl ca-certificates jq iproute2 coreutils sed gawk grep tar)
  [[ "$MODE" == "kernel" ]] && pkgs+=(wireguard-tools)
  local -a missing=()
  local p
  for p in "${pkgs[@]}"; do
    case "$p" in
      jq) have jq || missing+=("$p") ;;
      curl) have curl || missing+=("$p") ;;
      iproute2) have ip || missing+=("$p") ;;
      wireguard-tools) have wg || missing+=("$p") ;;
      *) ;;
    esac
  done
  if (( ${#missing[@]} == 0 )); then
    info "Required packages are already present."
    return 0
  fi
  have apt-get || die "apt-get not found. Install manually: ${missing[*]}"
  info "Installing packages: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  run_system apt-get update -qq
  run_system apt-get install -y -qq --no-install-recommends "${missing[@]}"
  have jq || die "jq is required but could not be installed."
}

ensure_tun_device() {
  if [[ -c /dev/net/tun ]]; then
    info "/dev/net/tun is available."
    return 0
  fi
  warn "/dev/net/tun is missing on the host; trying to create it."
  run_system modprobe tun || true
  if [[ ! -c /dev/net/tun ]]; then
    run_system mkdir -p /dev/net
    run_system mknod /dev/net/tun c 10 200 || true
    run_system chmod 600 /dev/net/tun || true
  fi
  [[ -c /dev/net/tun ]] && ok "TUN device created." || warn "TUN device still missing. Enable it in your virtualization panel."
}

resolve_wgcf_version() {
  if [[ "$WGCF_VERSION" == "latest" ]]; then
    local tag=""
    tag="$(fetch_stdout "https://api.github.com/repos/${WGCF_REPO}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)"
    [[ -n "$tag" ]] || tag="$WGCF_VERSION_DEFAULT"
    WGCF_VERSION="$tag"
  fi
  info "Using wgcf release ${WGCF_VERSION}."
}

install_wgcf() {
  resolve_wgcf_version
  local asset="wgcf_${WGCF_VERSION#v}_linux_${WGCF_ARCH}"
  local base="https://github.com/${WGCF_REPO}/releases/download/${WGCF_VERSION}"
  local tmp
  tmp="$(mktemp -d)"
  info "Downloading ${asset} ..."
  if ! fetch "${base}/${asset}" "$tmp/wgcf"; then
    warn "Direct download failed. Trying the latest release as a fallback."
    local latest
    latest="$(fetch_stdout "https://api.github.com/repos/${WGCF_REPO}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)"
    [[ -n "$latest" ]] || die "Could not download wgcf. Check outbound access to github.com."
    WGCF_VERSION="$latest"
    asset="wgcf_${WGCF_VERSION#v}_linux_${WGCF_ARCH}"
    base="https://github.com/${WGCF_REPO}/releases/download/${WGCF_VERSION}"
    fetch "${base}/${asset}" "$tmp/wgcf" || die "Could not download wgcf asset ${asset}."
  fi

  # Verify against the release checksums file when it is available.
  if fetch "${base}/checksums.txt" "$tmp/checksums.txt" 2>/dev/null; then
    local expected actual
    expected="$(awk -v a="$asset" '{ sub(/^\*/, "", $2); if ($2 == a) { print $1; exit } }' "$tmp/checksums.txt" 2>/dev/null || true)"
    actual="$(sha256sum "$tmp/wgcf" 2>/dev/null | awk '{print $1}' || true)"
    if [[ -n "$expected" && -n "$actual" ]]; then
      if [[ "$expected" == "$actual" ]]; then
        ok "SHA-256 checksum verified."
      else
        die "Checksum mismatch for ${asset}. Aborting for safety."
      fi
    else
      warn "Checksum entry not found; skipping checksum verification."
    fi
  else
    warn "checksums.txt unavailable; skipping checksum verification."
  fi

  run_system install -m 0755 "$tmp/wgcf" "$WGCF_BIN"
  rm -rf -- "$tmp"
  "$WGCF_BIN" --help >/dev/null 2>&1 || die "Downloaded wgcf binary is not executable on this host."
  state_set WGCF_VERSION "$WGCF_VERSION"
  ok "wgcf installed at ${WGCF_BIN}."
}

# -----------------------------------------------------------------------------
# WARP account profiles
# -----------------------------------------------------------------------------
conf_values() {
  local file="$1" key="$2"
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$file" 2>/dev/null | tr -d '\r'
}

conf_value() {
  local file="$1" key="$2"
  conf_values "$file" "$key" | head -n1
}

endpoint_ip() {
  local ep="$1" host ip
  host="${ep%%:*}"
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "$host"; return 0
  fi
  ip="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}' || true)"
  printf '%s' "${ip:-}"
}

create_profile() {
  local name="$1" src_ip="$2" endpoint="$3" license="$4"
  local dir="$PROFILE_DIR/$name"
  info "Creating WARP account profile '${name}' (source ${src_ip:-system default}, endpoint ${endpoint})."
  mkdir -p "$dir"; chmod 700 "$dir"
  rm -f "$dir/wgcf-account.toml" "$dir/wgcf-profile.conf"

  ( cd "$dir" && "$WGCF_BIN" register --accept-tos ) || die "wgcf register failed for profile '${name}'."
  if [[ -n "$license" ]]; then
    info "Binding WARP+ license key for profile '${name}'."
    local account="$dir/wgcf-account.toml" escaped tmp_account
    escaped="${license//\\/\\\\}"; escaped="${escaped//\"/\\\"}"
    if "$WGCF_BIN" update --help 2>&1 | grep -q -- '--license-key'; then
      ( cd "$dir" && "$WGCF_BIN" update --license-key "$license" ) \
        || warn "License key could not be applied; continuing with the free WARP tier."
    else
      # wgcf <= 2.2.22 has no --license-key flag: set license_key in the
      # account file and refresh the account as the official guide describes.
      tmp_account="$(mktemp "$dir/.account.XXXXXX")"
      WARP_LICENSE_VALUE="$escaped" awk '
        BEGIN { val = ENVIRON["WARP_LICENSE_VALUE"] }
        /^license_key[[:space:]]*=/ { print "license_key = \"" val "\""; found=1; next }
        { print }
        END { if (!found) print "license_key = \"" val "\"" }
      ' "$account" >"$tmp_account"
      chmod 600 "$tmp_account"
      mv -f -- "$tmp_account" "$account"
      ( cd "$dir" && "$WGCF_BIN" update ) \
        || warn "Account refresh failed; continuing with the free WARP tier."
    fi
  fi
  ( cd "$dir" && "$WGCF_BIN" generate --profile wgcf-profile.conf ) || die "wgcf generate failed for profile '${name}'."

  local conf="$dir/wgcf-profile.conf"
  local private_key addr4="" addr6="" public_key mtu ep line
  local -a addrs=()
  private_key="$(conf_value "$conf" PrivateKey)"
  while IFS= read -r line; do
    [[ -n "$line" ]] && addrs+=("$line")
  done < <(conf_values "$conf" Address)
  addr4="${addrs[0]:-}"
  addr6="${addrs[1]:-${addrs[0]:-}}"
  public_key="$(conf_value "$conf" PublicKey)"
  mtu="$(conf_value "$conf" MTU)"; mtu="${mtu:-1280}"
  ep="$(conf_value "$conf" Endpoint)"; ep="${ep:-$endpoint}"
  [[ -n "$private_key" && -n "$public_key" && -n "$addr4" ]] || die "Generated wgcf profile is incomplete."

  profile_meta_set "$name" PRIVATE_KEY "$private_key"
  profile_meta_set "$name" ADDRESS4 "$addr4"
  profile_meta_set "$name" ADDRESS6 "$addr6"
  profile_meta_set "$name" PUBLIC_KEY "$public_key"
  profile_meta_set "$name" MTU "$mtu"
  profile_meta_set "$name" SRC_IP "$src_ip"
  profile_meta_set "$name" ENDPOINT "$endpoint"
  local tag="$TAG_PREFIX" iface="warp"
  if [[ "$BINDING" == "per-ip" ]]; then
    tag="${TAG_PREFIX}-${name}"
    iface="warp-${name:0:10}"
  fi
  profile_meta_set "$name" TAG "$tag"
  profile_meta_set "$name" INTERFACE "$iface"
  profile_meta_set "$name" CREATED "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  chmod 600 "$dir"/* 2>/dev/null || true
  ok "Profile '${name}' ready (${addr4})."
}

# -----------------------------------------------------------------------------
# JSON snippet generation
# -----------------------------------------------------------------------------
domains_json_array() {
  local csv="${1:-$DOMAINS_CSV}"
  printf '%s' "$csv" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' \
    | jq -R . | jq -s .
}

build_outbound_json() {
  local name="$1"
  local tag iface key addr4 addr6 pub ep src
  tag="$(profile_meta "$name" TAG "$TAG_PREFIX")"
  iface="$(profile_meta "$name" INTERFACE "warp")"
  key="$(profile_meta "$name" PRIVATE_KEY)"
  addr4="$(profile_meta "$name" ADDRESS4)"
  addr6="$(profile_meta "$name" ADDRESS6)"
  pub="$(profile_meta "$name" PUBLIC_KEY)"
  ep="$(profile_meta "$name" ENDPOINT "$DEFAULT_ENDPOINT")"
  src="$(profile_meta "$name" SRC_IP "")"

  if [[ "$MODE" == "kernel" ]]; then
    jq -n --arg tag "$tag" --arg iface "$iface" '
      {
        tag: $tag,
        protocol: "freedom",
        settings: { domainStrategy: "UseIPv4" },
        streamSettings: { sockopt: { tcpFastOpen: true, interface: $iface } }
      }'
  else
    jq -n --arg tag "$tag" --arg key "$key" --arg a4 "$addr4" --arg a6 "$addr6" \
          --arg pub "$pub" --arg ep "$ep" --arg send "$src" --argjson modern "$MODERN_XRAY" '
      {
        tag: $tag,
        protocol: "wireguard",
        settings: {
          secretKey: $key,
          DNS: "1.1.1.1",
          address: ([$a4] + (if $a6 != "" and $a6 != $a4 then [$a6] else [] end)),
          peers: [ { publicKey: $pub, endpoint: $ep, allowedIPs: ["0.0.0.0/0", "::/0"] } ],
          kernelMode: false,
          mtu: 1280
        }
      }
      | if $send != "" then . + { sendThrough: $send } else . end
      | if $modern == 1 then
          .settings += { noKernelTun: true, remoteDNS: ["1.1.1.1", "1.0.0.1"] }
        else . end'
  fi
}

build_snippets() {
  local names=("$@")
  local outbounds="[]" rules="[]" balancers="[]"
  local n obj tag
  local domains
  domains="$(domains_json_array)"

  for n in "${names[@]}"; do
    obj="$(build_outbound_json "$n")"
    outbounds="$(jq --argjson o "$obj" '. + [$o]' <<<"$outbounds")"
  done

  if (( ${#names[@]} > 1 )); then
    local -a tags=()
    for n in "${names[@]}"; do tags+=("$(profile_meta "$n" TAG "$TAG_PREFIX")"); done
    balancers="$(jq -n --arg tag "$BALANCER_TAG" --args '{
        tag: $tag,
        selector: $ARGS.positional,
        strategy: { type: "random" }
      }' "${tags[@]}" | jq -s .)"
    if [[ "$ROUTING" == "all" ]]; then
      rules="$(jq -n --arg b "$BALANCER_TAG" '[ { type: "field", balancerTag: $b, domain: [] } ]')"
    else
      rules="$(jq -n --arg b "$BALANCER_TAG" --argjson d "$domains" \
        '[ { type: "field", balancerTag: $b, domain: $d } ]')"
    fi
  else
    tag="$(profile_meta "${names[0]}" TAG "$TAG_PREFIX")"
    if [[ "$ROUTING" == "all" ]]; then
      rules="[]"
    else
      rules="$(jq -n --arg t "$tag" --argjson d "$domains" \
        '[ { type: "field", outboundTag: $t, domain: $d } ]')"
    fi
  fi

  mkdir -p "$OUTPUT_DIR"
  printf '%s\n' "$outbounds" | jq . >"$OUTPUT_DIR/outbounds.json"
  printf '%s\n' "$rules" | jq . >"$OUTPUT_DIR/routing-rules.json"
  printf '%s\n' "$balancers" | jq . >"$OUTPUT_DIR/balancers.json"

  {
    printf 'PasarGuard WARP Manager - generated panel snippets\n'
    printf 'Generated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'Mode: %s | Target: %s | Binding: %s | Routing: %s\n\n' "$MODE" "$TARGET" "$BINDING" "$ROUTING"
    printf 'Panel path: Core Settings -> select the Core used by the EXIT NODE -> edit JSON.\n\n'
    printf '1) Paste every object from outbounds.json into the "outbounds" array.\n'
    if [[ "$ROUTING" == "all" ]]; then
      printf '   Put the WARP outbound first so it becomes the default outbound.\n'
    else
      printf '   Keep your existing first outbound first; WARP is used only by rules.\n\n'
      printf '2) Paste objects from routing-rules.json at the TOP of "routing.rules".\n'
    fi
    if (( ${#names[@]} > 1 )); then
      printf '3) Paste objects from balancers.json into "routing.balancers".\n'
    fi
    printf '\nWARNING: this script never edits the panel database directly unless\n'
    printf '"Apply to Panel (API)" is explicitly selected.\n'
  } >"$OUTPUT_DIR/README.txt"

  ok "Panel snippets written to ${OUTPUT_DIR}/"
}

# -----------------------------------------------------------------------------
# Kernel WireGuard (OS level) - used only on the machine where traffic exits
# -----------------------------------------------------------------------------
build_wg_conf() {
  local name="$1"
  local iface ep_ip key addr4 addr6 pub mtu src ep
  local postup="" predown=""
  iface="$(profile_meta "$name" INTERFACE "warp")"
  key="$(profile_meta "$name" PRIVATE_KEY)"
  addr4="$(profile_meta "$name" ADDRESS4)"
  addr6="$(profile_meta "$name" ADDRESS6)"
  pub="$(profile_meta "$name" PUBLIC_KEY)"
  mtu="$(profile_meta "$name" MTU 1280)"
  src="$(profile_meta "$name" SRC_IP "")"
  ep="$(profile_meta "$name" ENDPOINT "$DEFAULT_ENDPOINT")"

  # Bind the WARP UDP socket to a specific source IP by adding a reversible
  # host route with a preferred source address. The main routing table is
  # otherwise untouched (Table = off).
  if [[ -n "$src" && "$BINDING" == "per-ip" && -n "$DEFAULT_GW" && -n "$DEFAULT_DEV" ]]; then
    ep_ip="$(endpoint_ip "$ep")"
    if [[ -n "$ep_ip" ]]; then
      postup="ip route replace ${ep_ip}/32 via ${DEFAULT_GW} dev ${DEFAULT_DEV} src ${src}"
      predown="ip route del ${ep_ip}/32 via ${DEFAULT_GW} dev ${DEFAULT_DEV} src ${src} 2>/dev/null || true"
      profile_meta_set "$name" POSTUP "$postup"
      profile_meta_set "$name" PREDOWN "$predown"
    else
      warn "Could not resolve endpoint '${ep}' for source binding on '${name}'."
    fi
  fi

  local conf=""
  conf+="[Interface]"$'\n'
  conf+="PrivateKey = ${key}"$'\n'
  conf+="Address = ${addr4}"$'\n'
  [[ -n "$addr6" && "$addr6" != "$addr4" ]] && conf+="Address = ${addr6}"$'\n'
  conf+="MTU = ${mtu}"$'\n'
  conf+="# CRITICAL: never let wg-quick touch the main routing table."$'\n'
  conf+="Table = off"$'\n'
  [[ -n "$postup" ]] && conf+="PostUp = ${postup}"$'\n'
  [[ -n "$predown" ]] && conf+="PreDown = ${predown}"$'\n'
  conf+=""$'\n'
  conf+="[Peer]"$'\n'
  conf+="PublicKey = ${pub}"$'\n'
  conf+="AllowedIPs = 0.0.0.0/0"$'\n'
  conf+="AllowedIPs = ::/0"$'\n'
  conf+="Endpoint = ${ep}"$'\n'
  conf+="PersistentKeepalive = 25"$'\n'
  printf '%s' "$conf"
}

setup_kernel() {
  local names=("$@") n conf iface
  have systemctl || die "systemd/systemctl is required for kernel WireGuard mode."
  mkdir -p "$WG_DIR"; chmod 700 "$WG_DIR"
  ROUTE_BEFORE="$(ip -4 route show default 2>/dev/null | head -n1)"
  ROUTE_GUARD=1

  for n in "${names[@]}"; do
    iface="$(profile_meta "$n" INTERFACE "warp")"
    conf="$(build_wg_conf "$n")"
    [[ -f "$WG_DIR/$iface.conf" ]] && backup_file "$WG_DIR/$iface.conf" >/dev/null || true
    run_system bash -c "umask 077; printf '%s' \"\$1\" > \"\$2\"" _ "$conf" "$WG_DIR/$iface.conf"
    [[ "$DRY_RUN" == "1" ]] || chmod 600 "$WG_DIR/$iface.conf"
    info "Enabling wg-quick@${iface} ..."
    run_system systemctl enable "wg-quick@${iface}" >/dev/null 2>&1 || true
    run_system systemctl restart "wg-quick@${iface}"
  done

  local after
  after="$(ip -4 route show default 2>/dev/null | head -n1)"
  if [[ "$after" != "$ROUTE_BEFORE" ]]; then
    error "The default route changed during setup. Rolling back immediately to protect SSH access."
    rollback_kernel "${names[@]}"
    die "Aborted. Default route restored."
  fi
  ROUTE_GUARD=0
  ok "Kernel WireGuard interfaces are up. Default route is unchanged."
}

rollback_kernel() {
  local names=("$@") n iface
  for n in "${names[@]}"; do
    iface="$(profile_meta "$n" INTERFACE "warp")"
    systemctl stop "wg-quick@${iface}" >/dev/null 2>&1 || true
    systemctl disable "wg-quick@${iface}" >/dev/null 2>&1 || true
  done
  warn "All WARP interfaces created by this script were stopped."
}

# -----------------------------------------------------------------------------
# Docker Compose TUN permissions
# -----------------------------------------------------------------------------
patch_compose() {
  detect_compose || { warn "No docker-compose.yml found. Add the TUN settings manually if your node runs in Docker."; return 0; }
  compose_services
  local services="${COMPOSE_SERVICES:-}"
  [[ -n "$services" ]] || { warn "Could not detect services in ${COMPOSE_FILE}."; return 0; }

  local -a candidates=() svc
  IFS=',' read -r -a candidates <<<"$services"
  local selected="" hint="${COMPOSE_SERVICE_HINT:-}"
  if [[ -n "$hint" && ",$services," == *",$hint,"* ]]; then
    selected="$hint"
    info "Auto-selected compose service '${selected}' (container: ${COMPOSE_CONTAINER:-n/a})."
  elif (( ${#candidates[@]} == 1 )); then
    selected="${candidates[0]}"
  else
    for svc in "${candidates[@]}"; do
      if [[ "$svc" == *node* || "$svc" == *xray* ]]; then selected="$svc"; break; fi
    done
    if [[ -z "$selected" ]]; then
      local choice
      choice="$(choose "Select the service that runs Xray on this host:" "${candidates[@]}")" || return 1
      selected="${candidates[$((choice - 1))]}"
    else
      info "Auto-selected compose service '${selected}' (node-like name)."
    fi
  fi

  if [[ "$selected" != *node* && "$selected" != *xray* ]]; then
    warn "Service '${selected}' does not look like a node service."
    warn "The WARP outbound runs inside the NODE container; make sure that container"
    warn "also has /dev/net/tun. Check: docker ps --format '{{.Names}} {{.Image}}'"
  fi

  info "Patching ${COMPOSE_FILE} (service: ${selected}) with /dev/net/tun permissions."
  local backup
  backup="$(backup_file "$COMPOSE_FILE")"
  [[ -n "$backup" ]] && info "Backup saved: ${backup}"

  if ! python3 - "$COMPOSE_FILE" "$selected" <<'PY'
import re, sys

path, selected = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    lines = fh.read().splitlines()

start = None
for i, l in enumerate(lines):
    if re.match(r'^services\s*:\s*(#.*)?$', l):
        start = i
        break
if start is None:
    print("ERROR: no services: block", file=sys.stderr)
    sys.exit(1)

# Locate service blocks and their indentation.
svc_re = re.compile(r'^(\s*)([A-Za-z0-9_.-]+)\s*:\s*(#.*)?$')
svcs = []
for i in range(start + 1, len(lines)):
    l = lines[i]
    if l.strip() == "" or l.lstrip().startswith("#"):
        continue
    indent = len(l) - len(l.lstrip())
    if indent == 0:
        break
    m = svc_re.match(l)
    if m and (not svcs or indent == svcs[0][2]):
        svcs.append((i, m.group(2), indent))

target = next((s for s in svcs if s[1] == selected), None)
if target is None:
    print("ERROR: service not found", file=sys.stderr)
    sys.exit(1)

si, _, sindent = target
end = len(lines)
for i, _, ind in svcs:
    if i > si:
        end = i
        break
for i in range(si + 1, end):
    l = lines[i]
    if l.strip() and not l.lstrip().startswith("#") and (len(l) - len(l.lstrip())) == 0:
        end = i
        break

key_indent = " " * (sindent + 2)
item_indent = " " * (sindent + 4)
block = lines[si:end]

def has_key(name):
    return any(re.match(r'^' + key_indent + re.escape(name) + r'\s*:', l) for l in block)

def insert_after_key(name, items):
    for i, l in enumerate(block):
        if re.match(r'^' + key_indent + re.escape(name) + r'\s*:', l):
            j = i + 1
            while j < len(block) and (block[j].strip() == "" or
                                     (len(block[j]) - len(block[j].lstrip())) > sindent + 2):
                j += 1
            existing = "\n".join(block[i:j])
            add = [item_indent + "- " + x for x in items if x not in existing]
            block[j:j] = add
            return True
    return False

devices = ["/dev/net/tun:/dev/net/tun"]
secopts = ["seccomp=unconfined", "systempaths=unconfined", "apparmor=unconfined"]

if has_key("devices"):
    insert_after_key("devices", devices)
else:
    block.extend([key_indent + "devices:"] + [item_indent + "- " + d for d in devices])

if has_key("security_opt"):
    insert_after_key("security_opt", secopts)
else:
    block.extend([key_indent + "security_opt:"] + [item_indent + "- " + s for s in secopts])

lines[si:end] = block
with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
print("OK")
PY
  then
    warn "Compose patch failed; restoring the original file."
    [[ -n "$backup" ]] && cp -a -- "$backup" "$COMPOSE_FILE"
    return 1
  fi

  state_set COMPOSE_FILE "$COMPOSE_FILE"
  state_set COMPOSE_SERVICE "$selected"
  state_set COMPOSE_BACKUP "$backup"
  ok "Compose file patched."

  if have docker && [[ "$DRY_RUN" != "1" ]]; then
    if ( cd "$(dirname "$COMPOSE_FILE")" && docker compose -f "$(basename "$COMPOSE_FILE")" config >/dev/null 2>&1 ); then
      ok "docker compose config validation passed."
      if confirm "Restart the node container now to apply the new permissions?"; then
        ( cd "$(dirname "$COMPOSE_FILE")" && docker compose -f "$(basename "$COMPOSE_FILE")" up -d "$selected" )
      else
        warn "Remember to recreate the container later: docker compose up -d ${selected}"
      fi
    else
      warn "docker compose config validation failed. Review ${COMPOSE_FILE} manually."
    fi
  fi
}

restore_compose() {
  local f backup
  f="$(state_get COMPOSE_FILE "")"
  backup="$(state_get COMPOSE_BACKUP "")"
  [[ -n "$f" && -n "$backup" && -f "$backup" ]] || return 0
  if confirm "Restore the original docker-compose.yml from backup?"; then
    cp -a -- "$backup" "$f"
    ok "Restored ${f}."
    state_set COMPOSE_FILE ""
    state_set COMPOSE_BACKUP ""
  fi
}

# -----------------------------------------------------------------------------
# PasarGuard Panel API (optional)
# -----------------------------------------------------------------------------
panel_endpoint() {
  printf '%s' "${PANEL_URL%/}/api"
}

panel_login() {
  if [[ -n "$PANEL_TOKEN" ]]; then
    PANEL_ACCESS_TOKEN="$PANEL_TOKEN"
    return 0
  fi
  [[ -n "$PANEL_URL" ]] || return 1
  if [[ -z "$PANEL_USER" ]]; then
    PANEL_USER="$(ui_read "Panel admin username: ")" || return 1
  fi
  if [[ -z "$PANEL_PASS" ]]; then
    PANEL_PASS="$(ui_read_secret "Panel admin password: ")" || return 1
  fi
  local code body tmp
  tmp="$(mktemp)"
  local -a opts=(-sS -X POST --connect-timeout 10 --max-time 30 \
                 -H 'Accept: application/json' -o "$tmp" -w '%{http_code}')
  [[ "$INSECURE" == "1" ]] && opts+=(-k)
  code="$(curl "${opts[@]}" --data-urlencode "username=${PANEL_USER}" \
        --data-urlencode "password=${PANEL_PASS}" \
        "$(panel_endpoint)/admin/token" 2>/dev/null)" || {
    rm -f -- "$tmp"
    error "Could not reach the panel API at $(panel_endpoint)/admin/token"
    return 1
  }
  body="$(cat "$tmp")"; rm -f -- "$tmp"
  PANEL_ACCESS_TOKEN="$(jq -r '.access_token // empty' <<<"$body" 2>/dev/null || true)"
  if [[ -z "$PANEL_ACCESS_TOKEN" ]]; then
    error "Panel authentication failed (HTTP ${code})."
    printf '  Response: %.200s\n' "$body" >&2
    warn "Check the admin username/password. PANEL_URL must be the dashboard root (no /api suffix)."
    warn "Manual check: curl -i -X POST --data-urlencode 'username=USER' --data-urlencode 'password=PASS' $(panel_endpoint)/admin/token"
    return 1
  fi
  ok "Authenticated with the panel API."
}

panel_api() {
  local method="$1" path="$2" data="${3:-}"
  local bodyfile code
  bodyfile="$(mktemp)"
  local -a opts=(-sS -X "$method" --connect-timeout 10 --max-time 45 \
                 -H "Authorization: Bearer ${PANEL_ACCESS_TOKEN}" \
                 -H 'Accept: application/json' -o "$bodyfile" -w '%{http_code}')
  [[ "$INSECURE" == "1" ]] && opts+=(-k)
  if [[ -n "$data" ]]; then
    opts+=(-H 'Content-Type: application/json' --data-binary "$data")
  fi
  code="$(curl "${opts[@]}" "$(panel_endpoint)${path}" 2>/dev/null)" || {
    rm -f -- "$bodyfile"; return 1;
  }
  PANEL_API_BODY="$(cat "$bodyfile")"
  rm -f -- "$bodyfile"
  if [[ ! "$code" =~ ^2 ]]; then
    error "Panel API ${method} ${path} returned HTTP ${code}."
    printf '%s\n' "$PANEL_API_BODY" | head -c 400 >&2 || true
    return 1
  fi
  return 0
}

merge_core_config() {
  local core_file="$1" out_file="$2" action="${3:-apply}"
  local prepend="$RULE_PREPEND"
  jq --slurpfile obs "$OUTPUT_DIR/outbounds.json" \
     --slurpfile rules "$OUTPUT_DIR/routing-rules.json" \
     --slurpfile bals "$OUTPUT_DIR/balancers.json" \
     --argjson prepend "$prepend" \
     --argjson apply "$([[ "$action" == "apply" ]] && echo 1 || echo 0)" \
     '
     def ours: (.tag // "") | test("^warp(-|$)");
     def our_rule: ((.outboundTag // "") | test("^warp(-|$)")) or (.balancerTag == "warp-pool");
     .config
     | .outbounds = ([ (.outbounds // [])[] | select(ours | not) ])
     | .routing   = (.routing // {})
     | .routing.rules = ([ (.routing.rules // [])[] | select(our_rule | not) ])
     | .routing.balancers = ([ (.routing.balancers // [])[] | select(.tag != "warp-pool") ])
     | if $apply == 1 then
         .outbounds = (if $prepend == 1 then ($obs[0] + .outbounds) else (.outbounds + $obs[0]) end)
         | .routing.rules = ($rules[0] + .routing.rules)
         | .routing.balancers = (.routing.balancers + $bals[0])
         | if (.routing.balancers | length) == 0 then del(.routing.balancers) else . end
       else . end
     ' "$core_file" >"$out_file"
}

apply_to_panel() {
  local action="${1:-apply}"
  [[ -n "$PANEL_URL" ]] || { warn "Panel URL not configured; skipping API apply."; return 0; }
  have jq || die "jq is required for panel API integration."
  panel_login || { warn "Could not authenticate. Panel snippets are still available for manual paste."; return 0; }

  local core_id="$PANEL_CORE_ID"
  if [[ -z "$core_id" ]]; then
    panel_api GET "/cores" || { warn "Could not list core configs."; return 0; }
    local -a ids=() labels=() row
    while read -r row; do
      [[ -n "$row" ]] || continue
      ids+=("${row%%|*}"); labels+=("${row#*|}")
    done < <(jq -r '.cores[]? | "\(.id)|\(.name) [\(.type // "xray")]"' <<<"$PANEL_API_BODY" 2>/dev/null)
    if (( ${#ids[@]} == 0 )); then
      warn "No core configs returned by the panel API."
      return 0
    fi
    if (( ${#ids[@]} == 1 )); then
      core_id="${ids[0]}"
    else
      local c
      c="$(choose "Select the Core configuration used by the EXIT NODE:" "${labels[@]}")" || return 1
      core_id="${ids[$((c - 1))]}"
    fi
  fi
  info "Using core config ID ${core_id}."

  panel_api GET "/core/${core_id}" || { warn "Could not read core config ${core_id}."; return 0; }
  local snapshot="$BACKUP_DIR/panel-core-${core_id}-$(now_tag).json"
  mkdir -p "$BACKUP_DIR"
  printf '%s\n' "$PANEL_API_BODY" | jq . >"$snapshot"
  chmod 600 "$snapshot"
  info "Panel core backup saved: ${snapshot}"

  local merged
  merged="$(mktemp)"
  if ! merge_core_config "$snapshot" "$merged" "$action"; then
    error "Failed to build the merged core config. Nothing was sent to the panel."
    rm -f -- "$merged"; return 1
  fi

  header "Preview of changes for core ${core_id}"
  jq -n --slurpfile before "$snapshot" --slurpfile after "$merged" '
    { outbound_count: { before: ($before[0].config.outbounds | length), after: ($after[0] | .outbounds | length) },
      rule_count:     { before: ($before[0].config.routing.rules // [] | length), after: ($after[0].routing.rules | length) },
      first_outbound: ($after[0].outbounds[0].tag // "unchanged") }' || true
  if ! confirm "Apply this change to the panel now?"; then
    warn "Skipped. Preview saved at ${merged}."
    cp -f -- "$merged" "$OUTPUT_DIR/core-config-preview.json"
    return 0
  fi

  local body
  body="$(jq -n --slurpfile c "$snapshot" --slurpfile cfg "$merged" '{
      name: ($c[0].name),
      config: $cfg[0],
      type: ($c[0].type // null),
      exclude_inbound_tags: ($c[0].exclude_inbound_tags // []),
      fallbacks_inbound_tags: ($c[0].fallbacks_inbound_tags // [])
    }')"
  panel_api PUT "/core/${core_id}?restart_nodes=true" "$body" || {
    error "Panel update failed. Restore manually from ${snapshot}."
    return 1
  }
  ok "Core config ${core_id} updated and nodes notified."
  state_set_many "PANEL_CORE_ID=$core_id" "PANEL_LAST_APPLY=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "PANEL_LAST_BACKUP=$snapshot"
  cp -f -- "$merged" "$OUTPUT_DIR/core-config-preview.json"
  rm -f -- "$merged"
}

# -----------------------------------------------------------------------------
# Install wizard
# -----------------------------------------------------------------------------
print_target_guidance() {
  header "Deployment target - READ CAREFULLY"
  cat <<'TXT'
  WARP must run on the machine where the traffic actually LEAVES to the
  Internet (the egress / exit point), not necessarily on the machine that
  holds the users.

  Typical PasarGuard multi-node topology:

    [ Clients ] ---> [ Iran / MAIN PANEL ] ---node/tunnel---> [ NL / DE / PL EXIT NODE ]
                       users + configs                          egress to Internet
                                                                ^
                                                                |
                                              WARP outbound belongs HERE

  * tunnel configs : traffic exits from the FOREIGN node (NL/DE/PL).
                     => run this script on the FOREIGN node (or push the
                        Xray outbound to that node from the panel).
  * direct / cdn   : traffic exits from the IRAN server (or the CDN edge).
                     => WARP on the foreign node has NO effect on them.
                        Run the script on the IRAN server only if you really
                        want to cover those configs, and be aware it hosts
                        the main panel and all users.
  * Panel Core Settings live on the MAIN panel (Iran), but the generated
    Xray config is executed by the NODE. With the Xray WireGuard backend the
    panel pushes it automatically; with the kernel WireGuard backend the
    interface MUST also exist on the node.
TXT
  line
  return 0
}

choose_target() {
  local c
  c="$(choose "Where does the traffic you want to cover EXIT the Internet?" \
      "EXIT NODE - foreign server (NL / DE / PL), for tunnel configs  [RECOMMENDED]" \
      "MAIN PANEL - Iran server, for direct / CDN configs" \
      "I am only generating panel snippets here, the tunnel is elsewhere")" || return 1
  case "$c" in
    1) TARGET="exit" ;;
    2) TARGET="panel" ;;
    3) TARGET="generator" ;;
  esac
  if [[ "$TARGET" == "panel" && "$DETECTED_ROLE" == "node" ]]; then
    warn "This host looks like a NODE, but you selected MAIN PANEL. Double-check."
  fi
  if [[ "$TARGET" == "exit" && "$DETECTED_ROLE" == "panel" ]]; then
    warn "Detected role is 'panel' on this host, but you selected EXIT NODE."
    warn "Please confirm that THIS machine is where tunnelled traffic leaves to the Internet."
    warn "If this is only the Iran main panel, abort (Ctrl+C) and run the script on the foreign node."
  fi
  return 0
}

choose_mode() {
  local c
  header "WARP backend"
  cat <<'TXT'
  1) Xray native WireGuard outbound
     - Recommended by the PasarGuard docs (Xray >= 1.8.3).
     - Pure JSON config in Core Settings; the panel pushes it to nodes.
     - Needs /dev/net/tun exposed to the node container (patched by this tool).
     - No OS-level VPN, no routing table changes, safest for SSH.
  2) Kernel WireGuard (wg-quick) + Freedom outbound
     - Creates /etc/wireguard/warp.conf with Table = off.
     - MUST be installed on every egress node (docs: repeat step 3 on node).
     - Heavier, but works with older Xray builds and outside Docker.
TXT
  line
  c="$(choose "Select the WARP backend:" \
      "Xray native WireGuard outbound  [RECOMMENDED]" \
      "Kernel WireGuard (wg-quick) + Freedom outbound")" || return 1
  [[ "$c" == "1" ]] && MODE="xray" || MODE="kernel"
  if [[ "$MODE" == "xray" ]]; then
    detect_xray_version
    if [[ "$XRAY_VERSION" != "unknown" ]] && ! version_ge "$XRAY_VERSION" "$MIN_XRAY_VERSION"; then
      warn "Detected Xray ${XRAY_VERSION} is older than ${MIN_XRAY_VERSION}; memory leaks are possible."
    else
      info "Detected Xray version: ${XRAY_VERSION}"
    fi
  fi
  return 0
}

choose_binding() {
  local -a opts=()
  local i ans c ask_src=0
  header "Source IP / location binding"
  printf '  Detected %d global IPv4 address(es) on this host.\n' "${#DETECTED_IPS[@]}"
  cat <<'TXT'
  With several IPs (NL / DE / PL) you can either share one WARP tunnel or
  create one WARP account per source IP. Per-IP mode uses the Xray
  "sendThrough" field (Xray backend) or a scoped host route (kernel backend)
  so each tunnel leaves from its own address. Cloudflare then picks the
  nearest PoP for each source, which keeps the three locations distinct.
TXT
  line

  if [[ "$BINDING_PRESET" != "1" && "$ASSUME_YES" != "1" ]]; then
    c="$(choose "Select the binding strategy:" \
        "Single WARP account - system default egress IP  [SIMPLEST]" \
        "Single WARP account - bind to ONE chosen IP" \
        "Per-IP WARP accounts - one tunnel per detected IP (advanced)")" || return 1
    case "$c" in
      1) BINDING="single"; SRC_IP="" ;;
      2) BINDING="single"; ask_src=1 ;;
      3) BINDING="per-ip" ;;
    esac
  fi

  if [[ "$BINDING" == "per-ip" ]]; then
    if (( ${#DETECTED_IPS[@]} < 2 )); then
      die "Per-IP mode needs at least two detected global IPv4 addresses."
    fi
    if (( ${#PERIP_IPS[@]} == 0 )); then
      PERIP_IPS=("${DETECTED_IPS[@]}")
      PERIP_LABELS=()
      for i in "${!DETECTED_IPS[@]}"; do PERIP_LABELS+=("loc$((i + 1))"); done
    fi
    if [[ "$ASSUME_YES" != "1" ]]; then
      for i in "${!PERIP_IPS[@]}"; do
        ans="$(ui_read "Label for ${PERIP_IPS[$i]} (e.g. nl, de, pl) [${PERIP_LABELS[$i]}]: ")" || return 1
        [[ -n "$ans" ]] && PERIP_LABELS[$i]="$(safe_name "$ans")"
      done
    fi
    return 0
  fi

  if [[ -n "$SRC_IP" ]]; then
    is_valid_ipv4 "$SRC_IP" || die "Invalid source IPv4 address: ${SRC_IP}"
    return 0
  fi
  if [[ "$ask_src" == "0" && ( "$ASSUME_YES" == "1" || -z "${WARP_SRC_IP:-}" ) ]]; then
    SRC_IP=""
    return 0
  fi
  if (( ${#DETECTED_IPS[@]} == 0 )); then
    SRC_IP="$(ui_read "Enter the source IPv4 address: ")" || return 1
  else
    opts=()
    for i in "${!DETECTED_IPS[@]}"; do opts+=("${DETECTED_IPS[$i]}  (${DETECTED_IFACES[$i]})"); done
    local pick
    pick="$(choose "Select the source IP:" "${opts[@]}")" || return 1
    SRC_IP="${DETECTED_IPS[$((pick - 1))]}"
  fi
  is_valid_ipv4 "$SRC_IP" || die "Invalid IPv4 address: ${SRC_IP}"
  return 0
}

normalize_perip() {
  local i
  if [[ -n "$PERIP_LABELS_CSV" ]]; then
    local -a given=()
    IFS=',' read -r -a given <<<"$PERIP_LABELS_CSV"
    PERIP_LABELS=()
    for i in "${!given[@]}"; do
      PERIP_LABELS+=("$(safe_name "${given[$i]}")")
    done
  fi
  while (( ${#PERIP_LABELS[@]} < ${#PERIP_IPS[@]} )); do
    PERIP_LABELS+=("loc$(( ${#PERIP_LABELS[@]} + 1 ))")
  done
  if (( ${#PERIP_LABELS[@]} > ${#PERIP_IPS[@]} )); then
    PERIP_LABELS=("${PERIP_LABELS[@]:0:${#PERIP_IPS[@]}}")
  fi
  for i in "${!PERIP_LABELS[@]}"; do
    PERIP_LABELS[$i]="$(safe_name "${PERIP_LABELS[$i]}")"
  done
  return 0
}

apply_defaults() {
  [[ -n "$TARGET" ]]  || TARGET="exit"
  [[ -n "$MODE" ]]    || MODE="xray"
  [[ -n "$SRC_IP" ]]  || SRC_IP=""
  [[ -n "$LABEL" ]]   || LABEL="default"
  if [[ "$BINDING" == "per-ip" && ${#PERIP_IPS[@]} -eq 0 ]]; then
    PERIP_IPS=("${DETECTED_IPS[@]}")
    PERIP_LABELS=()
    local i
    for i in "${!DETECTED_IPS[@]}"; do PERIP_LABELS+=("loc$((i + 1))"); done
  fi
  [[ -n "$DOMAINS_CSV" ]] || DOMAINS_CSV="$DEFAULT_DOMAINS"
  return 0
}

choose_routing() {
  local c
  c="$(choose "Which traffic should use WARP?" \
      "Selected domains only (google / openai / spotify ...)  [RECOMMENDED]" \
      "ALL traffic (WARP becomes the default outbound)")" || return 1
  [[ "$c" == "1" ]] && ROUTING="domains" || ROUTING="all"
  if [[ "$ROUTING" == "domains" ]]; then
    local ans
    ans="$(ui_read "Domain list (comma separated) [Enter = default]: ")" || return 1
    [[ -n "$ans" ]] && DOMAINS_CSV="$ans"
  fi
  RULE_PREPEND=1
  if [[ "$ROUTING" == "all" ]]; then
    info "WARP outbound will be placed first in the outbounds array."
  fi
  return 0
}

choose_optional() {
  local ans
  ans="$(ui_read "WARP+ license key (optional, Enter to skip): ")" || return 1
  [[ -n "$ans" ]] && LICENSE_KEY="$ans"
  ans="$(ui_read "WARP endpoint [${ENDPOINT}]: ")" || return 1
  [[ -n "$ans" ]] && ENDPOINT="$ans"
  if [[ -z "$PANEL_URL" ]]; then
    ans="$(ui_read "Panel API base URL to auto-apply config (optional, e.g. https://panel.example.com): ")" || return 1
    if [[ -n "$ans" ]]; then PANEL_URL="$ans"; fi
  fi
  return 0
}

install_plan() {
  header "Installation plan"
  printf '  %-22s %s\n' "Target" "$TARGET"
  printf '  %-22s %s\n' "Backend" "$MODE"
  printf '  %-22s %s\n' "Binding" "$BINDING"
  printf '  %-22s %s\n' "Routing" "$ROUTING"
  printf '  %-22s %s\n' "Domains" "$DOMAINS_CSV"
  printf '  %-22s %s\n' "Endpoint" "$ENDPOINT"
  printf '  %-22s %s\n' "Panel API" "${PANEL_URL:-not configured (manual paste)}"
  if [[ "$BINDING" == "per-ip" ]]; then
    local i
    for i in "${!PERIP_IPS[@]}"; do
      printf '    profile %-12s src=%s\n' "${PERIP_LABELS[$i]}" "${PERIP_IPS[$i]}"
    done
  else
    printf '  %-22s %s\n' "Profile" "${LABEL:-default} / src=${SRC_IP:-system default}"
  fi
  line
  return 0
}

cmd_install() {
  state_init
  detect_os
  detect_role
  detect_ips
  header "$APP_NAME v$SCRIPT_VERSION - Install / Configure"
  print_environment

  if is_installed && [[ "$FORCE" != "1" ]]; then
    warn "WARP is already managed by this script. Use --force to reconfigure, or 'remove' first."
    return 0
  fi

  print_target_guidance

  if [[ "$ASSUME_YES" == "1" || "$DRY_RUN" == "1" || ! -r /dev/tty ]]; then
    apply_defaults
    if [[ -z "$TARGET" ]]; then choose_target >/dev/null 2>&1 || TARGET="exit"; fi
  else
    [[ -n "$TARGET" ]] || choose_target
    [[ -n "$MODE" ]]   || choose_mode
    choose_binding
    [[ -n "${WARP_ROUTING:-}" ]] || choose_routing
    choose_optional
  fi

  if [[ "$BINDING" == "per-ip" ]]; then
    normalize_perip
  fi

  local -a names=() srcs=() eps=()
  local i
  if [[ "$BINDING" == "per-ip" ]]; then
    if (( ${#PERIP_IPS[@]} < 2 )); then
      die "Per-IP mode needs at least two global IPv4 addresses; use --binding single."
    fi
    for i in "${!PERIP_IPS[@]}"; do
      names+=("$(safe_name "${PERIP_LABELS[$i]}")"); srcs+=("${PERIP_IPS[$i]}")
      if [[ "$MODE" == "kernel" && "$ENDPOINT" == "$DEFAULT_ENDPOINT" ]]; then
        eps+=("${WARP_ENDPOINTS[$((i % ${#WARP_ENDPOINTS[@]}))]}")
      else
        eps+=("$ENDPOINT")
      fi
    done
  else
    names+=("$(safe_name "${LABEL:-default}")")
    srcs+=("$SRC_IP")
    eps+=("$ENDPOINT")
  fi

  install_plan
  if ! confirm "Proceed with this plan?" "y"; then
    warn "Installation cancelled."
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    info "Dry-run complete. No changes were made."
    return 0
  fi

  install_packages
  have jq || die "jq is required."
  install_wgcf

  for i in "${!names[@]}"; do
    create_profile "${names[$i]}" "${srcs[$i]}" "${eps[$i]}" "$LICENSE_KEY"
  done
  # Persist the profile list early so error/rollback traps can find it.
  state_set PROFILES "${names[*]}"

  build_snippets "${names[@]}"

  if [[ "$MODE" == "kernel" && "$TARGET" != "generator" ]]; then
    setup_kernel "${names[@]}"
  fi
  if [[ "$MODE" == "xray" && "$TARGET" != "generator" ]]; then
    ensure_tun_device
    patch_compose
  fi

  state_set_many \
    "INSTALLED=1" "MODE=$MODE" "TARGET=$TARGET" "BINDING=$BINDING" \
    "ROUTING=$ROUTING" "ENDPOINT=$ENDPOINT" "DOMAINS=$DOMAINS_CSV" \
    "PROFILES=${names[*]}" "INSTALLED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "SCRIPT_VERSION=$SCRIPT_VERSION" "STATE_VERSION=1"

  if [[ "$APPLY_PANEL" != "no" && -n "$PANEL_URL" ]]; then
    apply_to_panel apply
  else
    header "Manual panel step"
    cat <<TXT
  Open the PasarGuard dashboard (main panel) -> Core Settings.
  Apply the generated files from:
      ${OUTPUT_DIR}/
  Use ${OUTPUT_DIR}/README.txt for the exact paste order.
TXT
    line
  fi

  header "Installation complete"
  info "Run 'warp-manager status' to verify the health of the deployment."
  info "Run 'warp-manager logs' to inspect service output."
}

cmd_apply() {
  local action="${1:-apply}"
  state_init
  header "$APP_NAME v$SCRIPT_VERSION - Apply Panel Config (${action})"
  have jq || die "jq is required for panel API integration."
  [[ -n "$PANEL_URL" ]] || die "Panel URL is required. Use --panel-url URL or PANEL_URL=... ."
  local f
  for f in outbounds.json routing-rules.json balancers.json; do
    [[ -f "$OUTPUT_DIR/$f" ]] || die "Missing ${OUTPUT_DIR}/${f}. Run 'warp-manager install' first."
  done
  if [[ "$action" == "apply" ]]; then
    info "Pushing the generated WARP outbound/rules into the panel Core Settings."
  else
    info "Removing the WARP outbound/rules from the panel Core Settings."
  fi
  apply_to_panel "$action"
  info "Done. Verify with: warp-manager status"
  return 0
}

# -----------------------------------------------------------------------------
# Remove
# -----------------------------------------------------------------------------
cmd_remove() {
  state_init
  detect_os; detect_role; detect_ips
  header "$APP_NAME v$SCRIPT_VERSION - Remove / Uninstall"
  if ! is_installed; then
    warn "No active installation recorded in ${STATE_FILE}."
    [[ "$FORCE" == "1" ]] || return 0
  fi

  local names
  names="$(profile_list)"
  local -a arr=()
  [[ -n "$names" ]] && read -r -a arr <<<"$names"
  local mode
  mode="$(state_get MODE xray)"

  header "Removal plan"
  printf '  %-22s %s\n' "Backend" "$mode"
  printf '  %-22s %s\n' "Profiles" "${names:-none}"
  printf '  %-22s %s\n' "Panel config" "must be cleaned from Core Settings"
  printf '  %-22s %s\n' "Generated files" "$OUTPUT_DIR"
  line
  cat <<'TXT'
  This stops WARP interfaces / removes config files created by this tool.
  It does NOT automatically delete outbound objects and routing rules that
  you pasted into the panel. Remove those from Core Settings afterwards, or
  use the optional panel API cleanup below.
TXT
  line
  if ! confirm "Continue with removal?"; then warn "Cancelled."; return 0; fi
  [[ "$DRY_RUN" == "1" ]] && { info "Dry-run complete. No changes were made."; return 0; }

  if [[ "$mode" == "kernel" && ${#arr[@]} -gt 0 ]]; then
    rollback_kernel "${arr[@]}"
    local n iface
    for n in "${arr[@]}"; do
      iface="$(profile_meta "$n" INTERFACE "warp")"
      [[ -f "$WG_DIR/$iface.conf" ]] && backup_file "$WG_DIR/$iface.conf" >/dev/null || true
      rm -f -- "$WG_DIR/$iface.conf"
      info "Removed ${WG_DIR}/${iface}.conf"
    done
  fi

  restore_compose

  if [[ "$APPLY_PANEL" != "no" && -n "$PANEL_URL" ]]; then
    [[ -d "$OUTPUT_DIR" ]] || mkdir -p "$OUTPUT_DIR"
    [[ -f "$OUTPUT_DIR/outbounds.json" ]] || printf '[]\n' >"$OUTPUT_DIR/outbounds.json"
    [[ -f "$OUTPUT_DIR/routing-rules.json" ]] || printf '[]\n' >"$OUTPUT_DIR/routing-rules.json"
    [[ -f "$OUTPUT_DIR/balancers.json" ]] || printf '[]\n' >"$OUTPUT_DIR/balancers.json"
    apply_to_panel remove
  fi

  if confirm "Delete locally stored WARP accounts and generated snippets?"; then
    rm -rf -- "$PROFILE_DIR" "$OUTPUT_DIR"
    mkdir -p "$PROFILE_DIR" "$OUTPUT_DIR"
    ok "Local profiles and snippets removed."
  else
    warn "Local profiles were kept under ${PROFILE_DIR}."
  fi

  rm -f -- "$WGCF_BIN"
  state_set_many "INSTALLED=0" "REMOVED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "PROFILES="
  ok "WARP removed."

  if confirm "Also uninstall the manager command and all logs/backups?"; then
    rm -f -- "$BIN_LINK"
    rm -rf -- "$APP_DIR"
    ok "Manager fully uninstalled."
  else
    info "Manager kept. Reinstall any time with 'warp-manager install'."
  fi
}

# -----------------------------------------------------------------------------
# Update
# -----------------------------------------------------------------------------
update_url_for() {
  local branch="$1" file="$2"
  if [[ -n "$UPDATE_URL" ]]; then printf '%s' "$UPDATE_URL"; return 0; fi
  printf 'https://raw.githubusercontent.com/%s/%s/%s/%s' "$REPO_OWNER" "$REPO_NAME" "$branch" "$file"
}

cmd_update() {
  state_init
  header "$APP_NAME v$SCRIPT_VERSION - Update Script"
  local self="${BASH_SOURCE[0]:-$0}"
  local tmp; tmp="$(mktemp)"
  local url branches=("$REPO_BRANCH")
  [[ "$REPO_BRANCH" != "$REPO_BRANCH_FALLBACK" ]] && branches+=("$REPO_BRANCH_FALLBACK")
  local b mirror fetched=0
  local -a urls=()
  if [[ -n "$UPDATE_URL" ]]; then
    urls+=("$UPDATE_URL")
  else
    local cache_bust
    cache_bust="$(date +%s)"
    for b in "${branches[@]}"; do
      urls+=("https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/warp-manager.sh?ref=${b}&v=${cache_bust}")
      urls+=("https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${b}/warp-manager.sh?v=${cache_bust}")
      urls+=("https://github.com/${REPO_OWNER}/${REPO_NAME}/raw/refs/heads/${b}/warp-manager.sh?v=${cache_bust}")
    done
  fi
  for url in "${urls[@]}"; do
    info "Checking ${url}"
    if fetch "$url" "$tmp" 2>/dev/null; then fetched=1; REPO_BRANCH="${REPO_BRANCH:-main}"; break; fi
  done
  if (( fetched == 0 )); then
    rm -f -- "$tmp"
    die "Could not download the latest script. Set WARP_BRANCH or WARP_UPDATE_URL, or copy the file manually."
  fi

  head -n1 "$tmp" | grep -q '^#!.*bash' || { rm -f -- "$tmp"; die "Downloaded file is not a bash script. Update aborted."; }
  bash -n "$tmp" || { rm -f -- "$tmp"; die "Downloaded script has syntax errors. Update aborted."; }
  local remote_version
  remote_version="$(grep -m1 '^readonly SCRIPT_VERSION=' "$tmp" | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  local old_hash new_hash
  old_hash="$(sha256sum "$self" 2>/dev/null | awk '{print $1}' || echo unknown)"
  new_hash="$(sha256sum "$tmp" | awk '{print $1}')"
  printf '  %-22s %s\n' "Installed version" "$SCRIPT_VERSION"
  printf '  %-22s %s\n' "Remote version" "${remote_version:-unknown}"
  printf '  %-22s %s\n' "Branch" "$REPO_BRANCH"

  if [[ "$UPDATE_CHECK_ONLY" == "1" ]]; then
    [[ "$old_hash" == "$new_hash" ]] && ok "You are up to date." || info "A newer/different script is available. Run 'warp-manager update' to install it."
    rm -f -- "$tmp"; return 0
  fi
  if [[ "$old_hash" == "$new_hash" && "$FORCE" != "1" ]]; then
    ok "Already up to date. Use --force to reinstall anyway."
    rm -f -- "$tmp"; return 0
  fi
  if ! confirm "Replace ${self} with the downloaded version?"; then
    rm -f -- "$tmp"; warn "Update cancelled."; return 0
  fi

  local backup
  backup="$(backup_file "$self")" || true
  [[ -n "$backup" ]] && info "Backup saved: ${backup}"
  install -m 0755 "$tmp" "$self"
  rm -f -- "$tmp"
  state_set SCRIPT_VERSION "${remote_version:-$SCRIPT_VERSION}"
  state_set LAST_UPDATE "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  ok "Script updated. Run 'warp-manager' again to use the new version."
}

# -----------------------------------------------------------------------------
# Logs
# -----------------------------------------------------------------------------
cmd_logs() {
  state_init
  local names mode choice
  names="$(profile_list)"
  mode="$(state_get MODE xray)"
  header "$APP_NAME - Logs"
  choice="$(choose "Select a log source:" \
      "Manager log - last ${LOG_LINES} lines" \
      "Manager log - follow live (Ctrl+C to stop)" \
      "WireGuard service logs (journalctl)" \
      "PasarGuard node / panel container logs" \
      "WARP account status (wgcf status)" \
      "Generated panel snippets" \
      "Back")" || return 0
  case "$choice" in
    1)
      if [[ -f "$LOG_FILE" ]]; then tail -n "$LOG_LINES" "$LOG_FILE"; else warn "No manager log yet: ${LOG_FILE}"; fi ;;
    2)
      if [[ -f "$LOG_FILE" ]]; then tail -n "$LOG_LINES" -F "$LOG_FILE"; else warn "No manager log yet: ${LOG_FILE}"; fi ;;
    3)
      if [[ "$mode" != "kernel" ]]; then warn "Kernel WireGuard is not active (current backend: ${mode})."; return 0; fi
      local -a arr=(); [[ -n "$names" ]] && read -r -a arr <<<"$names"
      if (( ${#arr[@]} == 0 )); then warn "No profiles found."; return 0; fi
      local n
      local -a jargs=()
      for n in "${arr[@]}"; do jargs+=(-u "wg-quick@$(profile_meta "$n" INTERFACE warp)"); done
      local -a tailargs=(-n "$LOG_LINES")
      [[ "$LOG_FOLLOW" == "1" ]] && tailargs=(-f "${tailargs[@]}")
      journalctl "${tailargs[@]}" --no-pager "${jargs[@]}" 2>/dev/null || warn "journalctl returned no entries." ;;
    4)
      if ! have docker; then warn "docker is not available on this host."; return 0; fi
      if ! detect_compose; then warn "No docker-compose.yml found."; return 0; fi
      compose_services
      local svc="${COMPOSE_SERVICES%%,*}"
      local -a args=(logs --tail="$LOG_LINES")
      [[ "$LOG_FOLLOW" == "1" ]] && args+=(-f)
      ( cd "$(dirname "$COMPOSE_FILE")" && docker compose -f "$(basename "$COMPOSE_FILE")" "${args[@]}" "$svc" ) ;;
    5)
      if [[ ! -x "$WGCF_BIN" ]]; then warn "wgcf is not installed."; return 0; fi
      local -a arr=(); [[ -n "$names" ]] && read -r -a arr <<<"$names"
      local n
      for n in "${arr[@]}"; do
        header "Profile: ${n}"
        ( cd "$PROFILE_DIR/$n" && "$WGCF_BIN" status ) || warn "Could not read status for ${n}."
      done ;;
    6)
      local f
      for f in "$OUTPUT_DIR/outbounds.json" "$OUTPUT_DIR/routing-rules.json" "$OUTPUT_DIR/balancers.json" "$OUTPUT_DIR/README.txt"; do
        if [[ -f "$f" ]]; then header "$(basename "$f")"; cat "$f"; fi
      done ;;
    *) return 0 ;;
  esac
  return 0
}

# -----------------------------------------------------------------------------
# Status
# -----------------------------------------------------------------------------
cmd_status() {
  state_init
  detect_os; detect_role; detect_ips; detect_xray_version
  local installed mode target binding routing names
  installed="$(state_get INSTALLED 0)"
  mode="$(state_get MODE none)"
  target="$(state_get TARGET none)"
  binding="$(state_get BINDING none)"
  routing="$(state_get ROUTING none)"
  names="$(profile_list)"

  header "$APP_NAME v$SCRIPT_VERSION - Status"
  print_environment
  printf '  %-22s %s\n' "Xray version" "$XRAY_VERSION (minimum ${MIN_XRAY_VERSION})"
  printf '  %-22s %s\n' "TUN device" "$([[ -c /dev/net/tun ]] && echo available || echo MISSING)"
  line

  header "Manager"
  printf '  %-22s %s\n' "Script" "${BASH_SOURCE[0]:-$0}"
  printf '  %-22s %s\n' "State file" "$STATE_FILE"
  printf '  %-22s %s\n' "Installed" "$([[ "$installed" == "1" ]] && echo yes || echo no)"
  printf '  %-22s %s\n' "Backend" "$mode"
  printf '  %-22s %s\n' "Target" "$target"
  printf '  %-22s %s\n' "Binding" "$binding"
  printf '  %-22s %s\n' "Routing" "$routing"
  printf '  %-22s %s\n' "Profiles" "${names:-none}"
  printf '  %-22s %s\n' "Last panel apply" "$(state_get PANEL_LAST_APPLY never)"
  line

  local -a arr=(); [[ -n "$names" ]] && read -r -a arr <<<"$names"
  local problems=0 n iface tag src ep
  header "WARP profiles"
  if (( ${#arr[@]} == 0 )); then
    warn "No WARP profiles registered."
    problems=$((problems + 1))
  fi
  for n in "${arr[@]}"; do
    iface="$(profile_meta "$n" INTERFACE warp)"
    tag="$(profile_meta "$n" TAG "$TAG_PREFIX")"
    src="$(profile_meta "$n" SRC_IP system-default)"
    ep="$(profile_meta "$n" ENDPOINT "$DEFAULT_ENDPOINT")"
    printf '  %-14s tag=%-14s iface=%-12s src=%-16s ep=%s\n' "$n" "$tag" "$iface" "$src" "$ep"
    [[ -f "$PROFILE_DIR/$n/wgcf-account.toml" ]] || { warn "  Account file missing for ${n}."; problems=$((problems + 1)); }
    if [[ "$mode" == "kernel" ]]; then
      if [[ -f "$WG_DIR/$iface.conf" ]]; then
        if grep -q '^Table = off' "$WG_DIR/$iface.conf"; then ok "  ${iface}.conf has Table = off (SSH safe)."
        else bad "  ${iface}.conf is MISSING 'Table = off'. High risk of losing server access!"; problems=$((problems + 1)); fi
      else
        bad "  ${WG_DIR}/${iface}.conf is missing."; problems=$((problems + 1))
      fi
      if have wg && ip link show "$iface" >/dev/null 2>&1; then
        local hs
        hs="$(wg show "$iface" latest-handshakes 2>/dev/null | awk '{print $2}' | head -n1 || true)"
        printf '    interface      : UP (last handshake epoch: %s)\n' "${hs:-none}"
        if [[ -n "${hs:-}" && "$hs" != "0" ]]; then
          local age=$(( $(date +%s) - hs ))
          if (( age < 180 )); then ok "    handshake      : recent (${age}s ago)"
          else warn "    handshake      : stale (${age}s ago)"; problems=$((problems + 1)); fi
        fi
      else
        bad "    interface      : DOWN"; problems=$((problems + 1))
      fi
    fi
  done
  line

  header "Panel configuration"
  local f
  for f in outbounds.json routing-rules.json balancers.json README.txt; do
    if [[ -f "$OUTPUT_DIR/$f" ]]; then ok "  ${OUTPUT_DIR}/$f"; else warn "  ${OUTPUT_DIR}/$f (missing)"; fi
  done
  if [[ -n "$(state_get COMPOSE_FILE "")" ]]; then
    ok "  Docker compose patched: $(state_get COMPOSE_FILE '')"
  else
    warn "  Docker compose TUN permissions: not patched by this tool"
  fi
  line

  header "Connectivity"
  if [[ "$mode" == "kernel" && ${#arr[@]} -gt 0 ]]; then
    iface="$(profile_meta "${arr[0]}" INTERFACE warp)"
    if ip link show "$iface" >/dev/null 2>&1 && have curl; then
      local trace
      trace="$(curl -4 -sS --max-time 12 --interface "$iface" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
      if [[ -n "$trace" ]]; then
        printf '%s\n' "$trace" | grep -E '^(ip|loc|warp)=' | sed 's/^/    /' || true
        grep -q '^warp=on\|^warp=plus' <<<"$trace" && ok "    WARP tunnel is passing traffic." || { warn "    No WARP marker in trace output."; problems=$((problems + 1)); }
      else
        warn "    Could not fetch the Cloudflare trace through ${iface}."; problems=$((problems + 1))
      fi
    fi
  else
    info "  Xray backend: test from a client config (e.g. https://www.cloudflare.com/cdn-cgi/trace)."
    info "  Expected result: warp=on (or warp=plus) and a Cloudflare egress IP."
  fi
  line

  if (( problems == 0 )); then
    ok "Overall health: OK"
  else
    warn "Overall health: ${problems} item(s) need attention. Run 'warp-manager logs' for details."
  fi
}

# -----------------------------------------------------------------------------
# Menu
# -----------------------------------------------------------------------------
print_banner() {
  detect_os; detect_role; detect_ips
  printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "========================================================================" "$C_RESET"
  printf '%s  %s  v%s%s\n' "$C_BOLD$C_CYAN" "$APP_NAME" "$SCRIPT_VERSION" "$C_RESET"
  printf '%s%s%s\n' "$C_BOLD$C_CYAN" "========================================================================" "$C_RESET"
  printf '  %-18s %s\n' "Host" "$(hostname 2>/dev/null || echo unknown)"
  printf '  %-18s %s\n' "Role" "$DETECTED_ROLE"
  printf '  %-18s %s\n' "Primary IP" "$PRIMARY_IP"
  printf '  %-18s %s\n' "Global IPs" "${#DETECTED_IPS[@]}"
  printf '  %-18s %s\n' "Installation" "$([[ "$(state_get INSTALLED 0)" == "1" ]] && printf 'active (%s / %s)' "$(state_get MODE '?')" "$(state_get TARGET '?')" || echo 'not installed')"
  printf '%s\n' "------------------------------------------------------------------------"
}

cmd_menu() {
  state_init
  while true; do
    print_banner
    local c
    c="$(choose "Main menu - select an option:" \
        "Install / Configure WARP" \
        "Remove / Uninstall WARP" \
        "Update Script" \
        "View Logs" \
        "Status / Health Check" \
        "Exit")" || { printf '\n'; return 0; }
    case "$c" in
      1) cmd_install ;;
      2) cmd_remove ;;
      3) cmd_update ;;
      4) cmd_logs ;;
      5) cmd_status ;;
      6) info "Goodbye."; return 0 ;;
    esac
    if [[ "$c" != "6" ]]; then
      printf '\n'
      ui_read "Press Enter to return to the main menu..." >/dev/null 2>&1 || true
    fi
  done
}

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------
usage() {
  cat <<'EOF'
PasarGuard WARP Manager - install and operate Cloudflare WARP on PasarGuard.

Usage:
  warp-manager [COMMAND] [OPTIONS]
  warp-manager                       Open the interactive numbered menu.

Commands:
  install     Install / configure WARP
  remove      Remove / uninstall WARP
  update      Update this script
  logs        View logs
  status      Status / health check
  menu        Open the interactive menu
  apply       Push generated snippets into the panel API (no reinstall)
  unapply     Remove WARP outbound/rules from the panel API
  help        Show this help

Install options:
  --mode xray|kernel        WARP backend (default: asked interactively)
  --target exit|panel|generator
                            Where the covered traffic leaves the Internet
  --binding single|per-ip   One WARP account or one per source IP
  --ip ADDRESS              Source IPv4 for a single binding (sendThrough)
  --label NAME              Profile label for a single binding
  --labels LIST             Comma separated labels for per-IP mode (nl,de,pl)
  --endpoint HOST:PORT      WARP WireGuard endpoint
  --routing domains|all     Scope of traffic sent through WARP
  --domains LIST            Comma separated domain list for routing rules
  --license KEY             Optional WARP+ license key
  --wgcf-version TAG|latest wgcf release tag (default: v2.2.22)
  --modern-xray             Add noKernelTun / remoteDNS for recent Xray builds

Panel API options (optional):
  --panel-url URL           Panel base URL, e.g. https://panel.example.com
  --panel-user USER         Admin username
  --panel-pass PASS         Admin password
  --panel-token TOKEN       Bearer token instead of username/password
  --core-id ID              Core configuration ID to modify
  --apply-panel             Force API apply
  --no-apply-panel          Never call the API, only write snippets

Other options:
  --yes, -y                 Answer all confirmations with yes
  --dry-run                 Print the plan and exit without changes
  --force                   Allow reinstall / forced update
  --insecure                Skip TLS verification (downloads and panel API)
  --branch BRANCH           Git branch used by 'update'
  --url URL                 Direct script URL used by 'update'
  --check                   With 'update': only check for a new version
  --lines N                 With 'logs': number of lines (default 80)
  --follow                  With 'logs': follow output
  --version, -V             Print version
  --help, -h                Print help

Environment variables:
  WARP_APP_DIR, WARP_BRANCH, WARP_UPDATE_URL, WARP_MODE, WARP_TARGET,
  WARP_BINDING, WARP_SRC_IP, WARP_LABEL, WARP_LABELS, WARP_ENDPOINT, WARP_ROUTING,
  WARP_DOMAINS, WARP_LICENSE_KEY, WARP_APPLY_PANEL, WGCF_VERSION,
  WARP_YES, WARP_DRY_RUN, WARP_FORCE, WARP_INSECURE, WARP_DEBUG,
  PANEL_URL, PANEL_USER, PANEL_PASS, PANEL_TOKEN, PANEL_CORE_ID

Examples:
  warp-manager
  warp-manager install --mode xray --target exit --binding per-ip --yes
  warp-manager install --mode kernel --target exit --ip 203.0.113.10
  warp-manager status
  warp-manager update --check
  warp-manager apply --panel-url https://panel.example.com \
    --panel-user admin --panel-pass 'secret' --core-id 1 --yes
EOF
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      install|remove|update|logs|status|menu|help|apply|unapply) COMMAND="$1"; shift ;;
      --mode) MODE="$2"; shift 2 ;;
      --target) TARGET="$2"; shift 2 ;;
      --binding) BINDING="$2"; BINDING_PRESET=1; shift 2 ;;
      --ip) SRC_IP="$2"; shift 2 ;;
      --label) LABEL="$2"; shift 2 ;;
      --labels) PERIP_LABELS_CSV="$2"; shift 2 ;;
      --endpoint) ENDPOINT="$2"; shift 2 ;;
      --routing) ROUTING="$2"; shift 2 ;;
      --domains) DOMAINS_CSV="$2"; shift 2 ;;
      --license) LICENSE_KEY="$2"; shift 2 ;;
      --wgcf-version) WGCF_VERSION="$2"; shift 2 ;;
      --modern-xray) MODERN_XRAY=1; shift ;;
      --panel-url) PANEL_URL="$2"; shift 2 ;;
      --panel-user) PANEL_USER="$2"; shift 2 ;;
      --panel-pass) PANEL_PASS="$2"; shift 2 ;;
      --panel-token) PANEL_TOKEN="$2"; shift 2 ;;
      --core-id) PANEL_CORE_ID="$2"; shift 2 ;;
      --apply-panel) APPLY_PANEL="yes"; shift ;;
      --no-apply-panel) APPLY_PANEL="no"; shift ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --force) FORCE=1; shift ;;
      --insecure) INSECURE=1; shift ;;
      --branch) REPO_BRANCH="$2"; shift 2 ;;
      --url) UPDATE_URL="$2"; shift 2 ;;
      --check) UPDATE_CHECK_ONLY=1; shift ;;
      --lines) LOG_LINES="$2"; shift 2 ;;
      --follow) LOG_FOLLOW=1; shift ;;
      --version|-V) printf '%s %s\n' "$APP_NAME" "$SCRIPT_VERSION"; exit 0 ;;
      --help|-h|help) usage; exit 0 ;;
      *) die "Unknown option: $1 (use --help)"; ;;
    esac
  done
  [[ -n "$MODE" && "$MODE" != "xray" && "$MODE" != "kernel" ]] && die "--mode must be xray or kernel."
  [[ -n "$TARGET" && "$TARGET" != "exit" && "$TARGET" != "panel" && "$TARGET" != "generator" ]] && die "--target must be exit, panel or generator."
  [[ "$BINDING" != "single" && "$BINDING" != "per-ip" ]] && die "--binding must be single or per-ip."
  [[ "$ROUTING" != "domains" && "$ROUTING" != "all" ]] && die "--routing must be domains or all."
  [[ -n "$SRC_IP" ]] && { is_valid_ipv4 "$SRC_IP" || die "Invalid --ip address: ${SRC_IP}"; }
  [[ "$ENDPOINT" == *:* ]] || die "--endpoint must be in HOST:PORT form."
}

require_root() {
  [[ "$(id -u)" == "0" ]] || die "Root privileges are required. Run with sudo or as root."
}

on_error() {
  local rc=$? lineno="${BASH_LINENO[0]:-$1}"
  [[ -z "$lineno" || "$lineno" == "0" ]] && lineno="unknown"
  error "Unexpected failure at line ${lineno} (exit ${rc}). Check ${LOG_FILE} for details."
  if [[ "${ROUTE_GUARD:-0}" == "1" ]]; then
    warn "Rolling back WireGuard interfaces to protect server access."
    local names; names="$(profile_list)"
    local -a arr=(); [[ -n "$names" ]] && read -r -a arr <<<"$names"
    (( ${#arr[@]} > 0 )) && rollback_kernel "${arr[@]}" || true
  fi
  exit "$rc"
}

cleanup() {
  local rc=$?
  if [[ "${ROUTE_GUARD:-0}" == "1" ]]; then
    local now
    now="$(ip -4 route show default 2>/dev/null | head -n1)"
    if [[ "$now" != "${ROUTE_BEFORE:-}" ]]; then
      error "Default route changed during WARP setup. Restoring."
      local names; names="$(profile_list)"
      local -a arr=(); [[ -n "$names" ]] && read -r -a arr <<<"$names"
      (( ${#arr[@]} > 0 )) && rollback_kernel "${arr[@]}" || true
    fi
  fi
  return "$rc"
}

main() {
  parse_args "$@"
  trap 'on_error $LINENO' ERR
  trap cleanup EXIT

  case "$COMMAND" in
    "")        require_root; cmd_menu ;;
    menu)      require_root; cmd_menu ;;
    install)   require_root; cmd_install ;;
    remove)    require_root; cmd_remove ;;
    update)    require_root; cmd_update ;;
    logs)      cmd_logs ;;
    status)    cmd_status ;;
    apply)     require_root; cmd_apply apply ;;
    unapply)   require_root; cmd_apply remove ;;
    help)      usage ;;
    *)         die "Unknown command: ${COMMAND}" ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
