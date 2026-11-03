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
readonly SCRIPT_VERSION="1.0.19"
readonly REPO_OWNER="XiliService"
readonly REPO_NAME="Warp-Pasarguard"
readonly REPO_BRANCH_DEFAULT="arena/01417195-warp-pasarguard"
readonly REPO_BRANCH_FALLBACK="main"
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
PANEL_API_KEY="${PANEL_API_KEY:-}"
PANEL_AUTH_MODE="token"
PANEL_KEY_NAME="warp-manager"
RESTORE_DB="0"; AUTO_KEY="0"; RESTORE_PATH=""; UNINSTALL_MANAGER="0"
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
MODERN_XRAY=1
REMOVE_ALL=0
ALL_TRAFFIC=0
WARP_TUNNEL_TAGS="[]"
PROFILE_BLOB=""
WARP_LINK_BLOB=""
WARP_LINK_SHOW=0
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
COMPOSE_CONTAINER=""; COMPOSE_SERVICE_HINT=""; PANEL_APPLY_OK=0
HANDLED_ERROR=0
PANEL_NETERR=""; PANEL_HTTP=""; PANEL_BODY=""
PANEL_BEST_HTTP=""; PANEL_BEST_BODY=""; PANEL_BEST_URL=""
ALLOW_LOCAL_PANEL="0"
ROUTE_GUARD=0
ROUTE_BEFORE=""
COMPOSE_FILE=""
COMPOSE_SERVICES=""
PANEL_ACCESS_TOKEN=""
# When the panel publishes no host port, all API calls are made through the
# panel container's network namespace (nsenter) instead of the host network.
PANEL_CONTAINER="${WARP_PANEL_CONTAINER:-}"
PANEL_TRANSPORT="${WARP_PANEL_TRANSPORT:-direct}"
PANEL_NS_PID=""
PANEL_NS_UNIX=""
# docker-exec transport: all panel HTTP calls are made by curl INSIDE the panel
# container (works with UVICORN_UDS and with uvicorn bound to 127.0.0.1).
PANEL_EXEC_UDS="${WARP_PANEL_EXEC_UDS:-}"
PANEL_EXEC_SCHEME="${WARP_PANEL_EXEC_SCHEME:-http}"
PANEL_EXEC_HOST="${WARP_PANEL_EXEC_HOST:-127.0.0.1}"
PANEL_EXEC_PORT="${WARP_PANEL_EXEC_PORT:-8000}"
PANEL_EXEC_TMP="/tmp/.warp-manager-panel-body"
RULE_PREPEND=0  # default ROUTING=domains; never make WARP the default outbound

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

# -----------------------------------------------------------------------------
# Docker compose patch: /dev/net/tun + security_opt
# -----------------------------------------------------------------------------
# Emit "compose_file|compose_service|container" for EVERY running node
# container. A host can run several nodes (e.g. out-node + main-node) and all
# of them may execute the WARP outbound, so patching only the first is wrong.
node_compose_targets() {
  local name cfg hint image
  have docker || return 0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    image="$(docker inspect "$name" --format '{{.Config.Image}}' 2>/dev/null || true)"
    [[ "$name" == *node* || "$image" == *node* ]] || continue
    cfg="$(docker inspect "$name" \
            --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' 2>/dev/null || true)"
    cfg="${cfg%%,*}"
    [[ -n "$cfg" && "$cfg" != "<no value>" && -f "$cfg" ]] || continue
    hint="$(docker inspect "$name" \
            --format '{{ index .Config.Labels "com.docker.compose.service" }}' 2>/dev/null || true)"
    [[ "$hint" == "<no value>" ]] && hint=""
    printf '%s|%s|%s\n' "$cfg" "$hint" "$name"
  done < <(docker ps --format '{{.Names}}' 2>/dev/null || true)
  return 0
}

# Patch every node compose file. Falls back to the old single-file detection
# when Docker labels are unavailable (e.g. node installed as a systemd unit).
patch_node_composes() {
  local file hint container rest key t
  local -a targets=() seen=()
  while IFS='|' read -r file hint container; do
    [[ -n "$file" ]] || continue
    key="${file}|${hint}"
    [[ " ${seen[*]:-} " == *" ${key} "* ]] && continue
    seen+=("$key"); targets+=("${key}|${container}")
  done < <(node_compose_targets)
  if (( ${#targets[@]} == 0 )); then
    COMPOSE_FILE=""; COMPOSE_SERVICE_HINT=""; COMPOSE_CONTAINER=""
    patch_compose
    return 0
  fi
  info "Found ${#targets[@]} node compose target(s); patching all of them."
  for t in "${targets[@]}"; do
    file="${t%%|*}"; rest="${t#*|}"
    hint="${rest%%|*}"; container="${rest##*|}"
    COMPOSE_FILE="$file"; COMPOSE_SERVICE_HINT="$hint"; COMPOSE_CONTAINER="$container"
    patch_compose || return 1
  done
  ok "All node containers now have /dev/net/tun permissions."
  return 0
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
  local -a pkgs=(curl ca-certificates jq iproute2 coreutils sed gawk grep tar util-linux)
  [[ "$MODE" == "kernel" ]] && pkgs+=(wireguard-tools)
  local -a missing=()
  local p
  for p in "${pkgs[@]}"; do
    case "$p" in
      jq) have jq || missing+=("$p") ;;
      curl) have curl || missing+=("$p") ;;
      iproute2) have ip || missing+=("$p") ;;
      wireguard-tools) have wg || missing+=("$p") ;;
      util-linux) have nsenter || missing+=("$p") ;;
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
  mkdir -p "$dir"; chmod 700 "$dir"
  # Reuse an existing / imported WARP account. Cloudflare's registration API
  # (api.cloudflareclient.com) is frequently unreachable from Iranian hosts.
  if [[ -f "$dir/meta.env" ]] \
     && [[ -n "$(profile_meta "$name" PRIVATE_KEY)" ]] \
     && [[ -n "$(profile_meta "$name" PUBLIC_KEY)" ]] \
     && [[ -n "$(profile_meta "$name" ADDRESS4)" ]]; then
    ok "Reusing the existing WARP account for profile '${name}' (no Cloudflare registration)."
    return 0
  fi
  info "Creating WARP account profile '${name}' (source ${src_ip:-system default}, endpoint ${endpoint})."
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
        settings: (
          {
            secretKey: $key,
            address: ([$a4] + (if $a6 != "" and $a6 != $a4 then [$a6] else [] end)),
            peers: [ { publicKey: $pub, endpoint: $ep,
                       allowedIPs: ["0.0.0.0/0", "::/0"] } ],
            mtu: 1280
          }
          # Xray >= 1.8 uses noKernelTun. With noKernelTun absent Xray sees
          # CAP_NET_ADMIN (we add it for /dev/net/tun) and installs a KERNEL
          # WireGuard link plus global routes/ip rules inside the node, which
          # breaks every other config. Userspace netstack is self-contained.
          | if $modern == 1 then
              . + { noKernelTun: true, remoteDNS: ["1.1.1.1", "1.0.0.1"] }
            else
              . + { kernelMode: false, DNS: "1.1.1.1" }
            end
        )
      }
      | if $send != "" then . + { sendThrough: $send } else . end'
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
    printf '   ORDER MATTERS: the FIRST outbound is the default for unmatched traffic.\n'
    if [[ "$ROUTING" == "all" ]]; then
      printf '   Put the WARP outbound first so it becomes the default outbound.\n'
    else
      printf '   Keep your existing first outbound (DIRECT) first. Put WARP after the\n'
      printf '   location outbounds and BEFORE any BLOCK/blackhole outbound.\n'
    fi
    printf '2) Paste objects from routing-rules.json into "routing.rules".\n'
    printf '   ORDER MATTERS: Xray checks rules top-down; the FIRST match wins.\n'
    printf '   The WARP rule must be ABOVE every catch-all inbound rule such as\n'
    printf '   Germany -> Out-DE, otherwise those rules win and WARP is never used.\n'
    printf '   Keep any leading BLOCK/security rule above the WARP rule.\n' 
    if (( ${#names[@]} > 1 )); then
      printf '3) Paste objects from balancers.json into "routing.balancers".\n'
    fi
    printf '\nWARP outbound uses noKernelTun: true (userspace WireGuard). It does NOT\n'
    printf 'create a kernel WireGuard link or add routes/ip rules inside the node.\n'
    printf 'Do not use kernelMode on recent Xray builds: with CAP_NET_ADMIN it can\n'
    printf 'hijack the node routing table and break every other config.\n'
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
  if [[ -z "${COMPOSE_FILE:-}" ]]; then
    detect_compose || { warn "No docker-compose.yml found. Add the TUN settings manually if your node runs in Docker."; return 0; }
  fi
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
  local backup before_hash after_hash
  before_hash="$(sha256sum "$COMPOSE_FILE" 2>/dev/null | awk '{print $1}')"
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
  after_hash="$(sha256sum "$COMPOSE_FILE" 2>/dev/null | awk '{print $1}')"
  if [[ -n "$before_hash" && "$before_hash" == "$after_hash" ]]; then
    ok "Compose file already has TUN permissions (no change, no restart)."
    return 0
  fi
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

load_saved_api_key() {
  [[ -n "$PANEL_API_KEY" ]] && return 0
  local k; k="$(state_get PANEL_API_KEY '')"
  if [[ -n "$k" ]]; then PANEL_API_KEY="$k"; fi
  return 0
}

load_saved_panel_url() {
  local u c t x
  if [[ -z "$PANEL_URL" ]]; then
    u="$(state_get PANEL_URL '')"
    if [[ -n "$u" ]]; then PANEL_URL="$u"; fi
  fi
  if [[ -z "$PANEL_CONTAINER" ]]; then
    c="$(state_get PANEL_CONTAINER '')"
    if [[ -n "$c" ]]; then PANEL_CONTAINER="$c"; fi
  fi
  t="$(state_get PANEL_TRANSPORT '')"
  if [[ -n "$t" ]]; then PANEL_TRANSPORT="$t"; fi
  x="$(state_get PANEL_NS_UNIX '')"
  if [[ -n "$x" ]]; then PANEL_NS_UNIX="$x"; fi
  if [[ "$PANEL_TRANSPORT" == "docker-exec" ]]; then
    PANEL_EXEC_UDS="$(state_get PANEL_EXEC_UDS '')"
    PANEL_EXEC_SCHEME="$(state_get PANEL_EXEC_SCHEME http)"
    PANEL_EXEC_HOST="$(state_get PANEL_EXEC_HOST 127.0.0.1)"
    PANEL_EXEC_PORT="$(state_get PANEL_EXEC_PORT 8000)"
  fi
  return 0
}

# Read-only probe: PasarGuard accepts an API key via the X-Api-Key header
# (Authorization: ApiKey <key> also works). A valid /api/cores response is
# {"count":N,"cores":[...]}, which lets us identify the correct panel URL.
panel_probe_key() {
  local base="$1" k="$2" tmp err code body
  tmp="$(mktemp)"; err="$(mktemp)"
  local -a opts=(-sS -X GET --connect-timeout 2 --max-time 8 \
                 -H "X-Api-Key: ${PANEL_API_KEY}" \
                 -H 'Accept: application/json' -o "$tmp" -w '%{http_code}')
  if [[ "$k" == "1" ]]; then opts+=(-k); fi
  PANEL_NETERR=""; PANEL_HTTP=""; PANEL_BODY=""
  # NOTE: the panel uses APIRouter(prefix="/api/core") + @router.get("s"),
  # so the list endpoint is /api/cores (NOT /api/core/s).
  code="$(curl_panel "${opts[@]}" "${base%/}/api/cores" 2>"$err")" || {
    PANEL_NETERR="$(tr '\n' ' ' < "$err" | cut -c1-240)"
    rm -f -- "$tmp" "$err"; return 1
  }
  rm -f -- "$err"
  body="$(cat "$tmp")"; rm -f -- "$tmp"
  PANEL_HTTP="$code"
  PANEL_BODY="$(printf '%s' "$body" | head -c 240)"
  if [[ "$code" =~ ^[0-9]+$ && -z "$PANEL_BEST_HTTP" ]]; then
    PANEL_BEST_HTTP="$code"
    PANEL_BEST_BODY="$PANEL_BODY"
    PANEL_BEST_URL="$base"
  fi
  if [[ ! "$code" =~ ^2 ]]; then return 1; fi
  if ! jq -e '(.cores | type) == "array"' <<<"$body" >/dev/null 2>&1; then
    PANEL_HTTP="invalid-shape"
    return 1
  fi
  return 0
}

# Panel containers running on THIS host can be reached directly, which helps
# when the public dashboard domain does not resolve (or is firewalled) from
# the VPS itself. Read-only discovery; nothing is changed here.
local_panel_urls() {
  local line name image ports port cport ip ips uvicorn_port env
  local -a cports=()
  have docker || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    name="${line%% *}"; image="${line#* }"
    [[ -n "$name" ]] || continue
    case "${name} ${image}" in
      *pgbouncer*|*pgadmin*|*timescale*|*postgres*|*redis*|*node*) continue ;;
    esac
    if [[ "$image" != *pasarguard/panel* && "$name" != *panel* ]]; then
      [[ "$name" == *pasarguard* ]] || continue
    fi
    env="$(docker inspect "$name" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true)"
    uvicorn_port="$(grep '^UVICORN_PORT=' <<<"$env" | head -n1 | cut -d= -f2- || true)"
    if [[ ! "$uvicorn_port" =~ ^[0-9]+$ ]]; then uvicorn_port="8000"; fi
    ports="$(docker inspect "$name" --format '{{json .NetworkSettings.Ports}}' 2>/dev/null || true)"
    cports=("$uvicorn_port" 8080 80 3000 9000 2053 2096 443 8443)
    if [[ -n "$ports" && "$ports" != "null" && "$ports" != "{}" ]] && have jq; then
      while IFS= read -r cport; do
        cport="${cport%%/*}"
        if [[ "$cport" =~ ^[0-9]+$ ]]; then cports+=("$cport"); fi
      done < <(jq -r 'to_entries[]? | .key' <<<"$ports" 2>/dev/null || true)
      while IFS= read -r port; do
        if [[ "$port" =~ ^[0-9]+$ ]]; then printf 'http://127.0.0.1:%s\n' "$port"; fi
      done < <(jq -r 'to_entries[]? | .value[]? | .HostPort // empty' <<<"$ports" 2>/dev/null || true)
    fi
    # Host loopback (works only if a port was published) and the container's
    # own bridge IP (always reachable from the host on a Docker network).
    printf 'http://127.0.0.1:%s\n' "$uvicorn_port"
    ips="$(docker inspect "$name" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null || true)"
    for ip in $ips; do
      [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
      for cport in "${cports[@]}"; do
        printf 'http://%s:%s\n' "$ip" "$cport"
      done
      printf 'https://%s:443\nhttps://%s:8443\nhttps://%s:2096\n' "$ip" "$ip" "$ip"
    done
  done < <(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null || true)
  return 0
}

# Common local ports used by a panel container (host networking or an
# unpublished bridge port). Only tried when --allow-local-panel is given.
# Public/reverse-proxy URLs. A host-level nginx/Caddy usually matches on the
# Host header (SNI), so https://127.0.0.1:443 returns 404 while the real domain
# works. Gather domains from the panel container env and the host itself.
panel_public_urls() {
  local name env origin host ip
  have docker || return 0
  while IFS= read -r name; do
    env="$(docker inspect "$name" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true)"
    [[ -n "$env" ]] || continue
    while IFS= read -r origin; do
      origin="${origin%/}"
      [[ "$origin" == http://* || "$origin" == https://* ]] || continue
      printf '%s\n' "$origin"
    done < <(printf '%s\n' "$env" \
             | grep -E '^(VITE_BASE_API|PASSKEY_ORIGIN|ALLOWED_ORIGINS|SUBSCRIPTION_BASE_URL)=' \
             | grep -oE 'https?://[^ ,;"'\''/]+' | sort -u || true)
  done < <(panel_container_names)
  host="$(hostname -f 2>/dev/null || true)"
  if [[ -n "$host" && "$host" == *.* ]]; then
    printf 'https://%s\nhttp://%s\n' "$host" "$host"
  fi
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'https://%s\nhttp://%s\n' "$ip" "$ip"
  fi
  # A host-level reverse proxy often serves the panel on a domain that is not
  # in the container env. Read server_name from the usual proxy config trees.
  local domain
  if have grep; then
    while IFS= read -r domain; do
      [[ "$domain" == *.* && "$domain" != *'*'* ]] || continue
      case "$domain" in localhost*|127.0.0.*|_) continue ;; esac
      printf 'https://%s\nhttp://%s\n' "$domain" "$domain"
    done < <(grep -rhoE 'server_name[[:space:]]+[^;]+' \
             /etc/nginx /etc/caddy /etc/traefik 2>/dev/null \
             | sed -E 's/^server_name[[:space:]]+//' | tr ' ' '\n' \
             | sed 's/;$//' | grep -v '^$' | sort -u || true)
  fi
  return 0
}

local_port_probes() {
  local p
  local -a ports=(8000 8080 80 443 8443 2053 2096 9000 3000)
  for p in "${ports[@]}"; do
    printf 'http://127.0.0.1:%s\n' "$p"
    if [[ "$p" == "443" || "$p" == "8443" || "$p" == "2096" ]]; then
      printf 'https://127.0.0.1:%s\n' "$p"
    fi
  done
  return 0
}

# Single login attempt. Sets PANEL_ACCESS_TOKEN on success, otherwise records
# ---------------------------------------------------------------------------
# Panel transport
# ---------------------------------------------------------------------------
# List containers that could be running the PasarGuard panel API.
panel_container_names() {
  have docker || return 0
  local line name image env
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    name="${line%% *}"; image="${line#* }"
    [[ -n "$name" ]] || continue
    case "${name} ${image}" in
      *pgbouncer*|*pgadmin*|*timescale*|*postgres*|*redis*|*node*) continue ;;
    esac
    if [[ "$image" != *pasarguard/panel* && "$name" != *panel* ]]; then
      env="$(docker inspect "$name" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true)"
      [[ "$name" == *pasarguard* ]] || continue
    fi
    printf '%s\n' "$name"
  done < <(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null || true)
  return 0
}

# curl wrapper used ONLY for panel API calls. When PANEL_TRANSPORT=nsenter the
# request runs in the panel container's network namespace, so 127.0.0.1 is the
# container's own loopback (works even with no published port / UDS proxy).
# Rebuild a host URL as a container-local URL for the docker-exec transport.
panel_exec_url() {
  local url="$1" path
  path="$(printf '%s' "$url" | sed -E 's#^[a-zA-Z]+://[^/]+##')"
  [[ -z "$path" ]] && path="/"
  [[ "$path" == /* ]] || path="/${path}"
  if [[ -n "$PANEL_EXEC_UDS" ]]; then
    printf 'http://localhost%s' "$path"
  else
    printf '%s://%s:%s%s' "$PANEL_EXEC_SCHEME" "$PANEL_EXEC_HOST" "$PANEL_EXEC_PORT" "$path"
  fi
}

# Emulate the curl interface used by panel_probe_key / panel_try_login /
# panel_api, but run curl inside the panel container. The body is written to a
# temp file in the container, copied back to the host -o target, and the HTTP
# status code is printed on stdout exactly like curl -w '%{http_code}'.
curl_panel_exec() {
  local -a args=()
  local out="" err code
  err="$(mktemp)"
  if [[ -n "$PANEL_EXEC_UDS" ]]; then args+=(--unix-socket "$PANEL_EXEC_UDS"); fi
  while (( $# > 0 )); do
    case "$1" in
      -o) out="$2"; args+=(-o "$PANEL_EXEC_TMP"); shift 2 ;;
      http://*|https://*) args+=("$(panel_exec_url "$1")"); shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  code="$(docker exec -i "$PANEL_CONTAINER" curl "${args[@]}" 2>"$err")" || {
    cat "$err" >&2; rm -f -- "$err"; return 1
  }
  rm -f -- "$err"
  if [[ -n "$out" ]]; then
    if ! docker cp "$PANEL_CONTAINER:$PANEL_EXEC_TMP" "$out" >/dev/null 2>&1; then
      printf 'docker cp of the panel response failed' >&2
      return 1
    fi
  fi
  docker exec "$PANEL_CONTAINER" rm -f -- "$PANEL_EXEC_TMP" >/dev/null 2>&1 || true
  printf '%s' "$code"
  return 0
}

curl_panel() {
  if [[ "$PANEL_TRANSPORT" == "docker-exec" ]]; then
    curl_panel_exec "$@"
    return $?
  fi
  local -a pre=() extra=()
  if [[ "$PANEL_TRANSPORT" == "nsenter" ]]; then
    local pid="${PANEL_NS_PID:-}"
    if [[ ! "$pid" =~ ^[0-9]+$ || "$pid" == "0" ]] && [[ -n "$PANEL_CONTAINER" ]] && have docker; then
      pid="$(docker inspect "$PANEL_CONTAINER" --format '{{.State.Pid}}' 2>/dev/null || true)"
    fi
    if [[ "$pid" =~ ^[0-9]+$ && "$pid" != "0" ]] && have nsenter; then
      PANEL_NS_PID="$pid"
      if [[ -n "$PANEL_NS_UNIX" ]]; then
        pre=(nsenter -t "$pid" -n -m --)
        extra+=(--unix-socket "$PANEL_NS_UNIX")
      else
        pre=(nsenter -t "$pid" -n --)
      fi
    fi
  fi
  if (( ${#pre[@]} > 0 )); then
    "${pre[@]}" curl "${extra[@]}" "$@"
  else
    curl "${extra[@]}" "$@"
  fi
}

# Try to reach the panel API from inside each candidate container's netns.
# Used as a last resort after every host-level URL has failed.
# Last-resort discovery: ask curl INSIDE the panel container. This bypasses
# host networking entirely and supports UVICORN_UDS (the panel image ships curl
# for its own healthcheck). Official binding modes:
#   UVICORN_UDS                -> unix socket, no TCP listener at all
#   SSL cert + key             -> HTTPS on 0.0.0.0:UVICORN_PORT
#   neither                    -> HTTP on 127.0.0.1:UVICORN_PORT only
panel_exec_probe() {
  local mode="${1:-key}"
  have docker || return 1
  if [[ "$mode" == "key" && -z "$PANEL_API_KEY" ]]; then return 1; fi
  local name env uds port cert key host tport k target scheme base
  local saved_transport="$PANEL_TRANSPORT" saved_container="$PANEL_CONTAINER"
  local saved_uds="$PANEL_EXEC_UDS" saved_scheme="$PANEL_EXEC_SCHEME"
  local saved_host="$PANEL_EXEC_HOST" saved_port="$PANEL_EXEC_PORT"
  local -a names=() targets=()
  while IFS= read -r name; do names+=("$name"); done < <(panel_container_names)
  if (( ${#names[@]} == 0 )); then return 1; fi
  info "Trying curl inside ${#names[@]} candidate container(s)."
  for name in "${names[@]}"; do
    env="$(docker inspect "$name" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true)"
    info "  ${name}: $(grep -E '^UVICORN_(PORT|UDS|HOST|SSL_CERTFILE|SSL_KEYFILE)=' <<<"$env" | tr '\n' ' ')"
    if ! docker exec "$name" sh -c 'command -v curl >/dev/null 2>&1' >/dev/null 2>&1; then
      continue
    fi
    uds="$(grep '^UVICORN_UDS=' <<<"$env" | head -n1 | cut -d= -f2- || true)"
    port="$(grep '^UVICORN_PORT=' <<<"$env" | head -n1 | cut -d= -f2- || true)"
    cert="$(grep '^UVICORN_SSL_CERTFILE=' <<<"$env" | head -n1 | cut -d= -f2- || true)"
    key="$(grep '^UVICORN_SSL_KEYFILE=' <<<"$env" | head -n1 | cut -d= -f2- || true)"
    host="$(grep '^UVICORN_HOST=' <<<"$env" | head -n1 | cut -d= -f2- || true)"
    [[ "$port" =~ ^[0-9]+$ ]] || port="8000"
    if [[ -z "$host" || "$host" == "0.0.0.0" ]]; then host="127.0.0.1"; fi

    targets=()
    if [[ -n "$uds" ]]; then targets+=("uds|${uds}|${port}"); fi
    if [[ -n "$cert" && -n "$key" ]]; then targets+=("https|${port}|${port}"); fi
    targets+=("http|${port}|${port}")
    for p in 8000 8080 3000 9000 80 443; do targets+=("http|${p}|${p}"); done

    for target in "${targets[@]}"; do
      IFS='|' read -r scheme tport port <<<"$target"
      PANEL_TRANSPORT="docker-exec"
      PANEL_CONTAINER="$name"
      PANEL_EXEC_HOST="$host"
      PANEL_EXEC_PORT="$port"
      PANEL_EXEC_SCHEME="$scheme"
      if [[ "$scheme" == "uds" ]]; then
        PANEL_EXEC_UDS="$tport"; PANEL_EXEC_SCHEME="http"
      else
        PANEL_EXEC_UDS=""
      fi
      k=0; [[ "$scheme" == "https" ]] && k=1
      base="http://127.0.0.1:${port}"
      if [[ "$mode" == "token" ]]; then
        panel_try_login "$base" "$k" || continue
      else
        panel_probe_key "$base" "$k" || continue
      fi
      PANEL_URL="$base"
      INSECURE="$k"
      state_set PANEL_URL "$base"
      state_set PANEL_CONTAINER "$name"
      state_set PANEL_TRANSPORT docker-exec
      state_set PANEL_EXEC_UDS "$PANEL_EXEC_UDS"
      state_set PANEL_EXEC_SCHEME "$PANEL_EXEC_SCHEME"
      state_set PANEL_EXEC_HOST "$PANEL_EXEC_HOST"
      state_set PANEL_EXEC_PORT "$PANEL_EXEC_PORT"
      ok "Panel API reachable via curl inside container ${name}."
      return 0
    done
  done
  PANEL_TRANSPORT="$saved_transport"; PANEL_CONTAINER="$saved_container"
  PANEL_EXEC_UDS="$saved_uds"; PANEL_EXEC_SCHEME="$saved_scheme"
  PANEL_EXEC_HOST="$saved_host"; PANEL_EXEC_PORT="$saved_port"
  return 1
}

panel_nsenter_probe() {
  local mode="${1:-key}"
  have docker || return 1
  if [[ "$mode" == "key" && -z "$PANEL_API_KEY" ]]; then return 1; fi
  if ! have nsenter; then
    warn "nsenter is not installed; cannot reach a panel container without a published port."
    return 1
  fi
  local name pid env port cport k base saved_transport="$PANEL_TRANSPORT"
  local -a names=() ports=()
  while IFS= read -r name; do names+=("$name"); done < <(panel_container_names)
  if (( ${#names[@]} == 0 )); then return 1; fi
  info "Trying the panel API from inside ${#names[@]} container(s) via nsenter."
  for name in "${names[@]}"; do
    pid="$(docker inspect "$name" --format '{{.State.Pid}}' 2>/dev/null || true)"
    if [[ ! "$pid" =~ ^[0-9]+$ || "$pid" == "0" ]]; then continue; fi
    env="$(docker inspect "$name" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true)"
    port="$(grep '^UVICORN_PORT=' <<<"$env" | head -n1 | cut -d= -f2- || true)"
    ports=(8000 8080 80 3000 9000 2053)
    if [[ "$port" =~ ^[0-9]+$ ]]; then ports=("$port" "${ports[@]}"); fi
    if have jq; then
      while IFS= read -r cport; do
        cport="${cport%%/*}"
        if [[ "$cport" =~ ^[0-9]+$ ]]; then ports+=("$cport"); fi
      done < <(docker inspect "$name" --format '{{json .NetworkSettings.Ports}}' 2>/dev/null \
               | jq -r 'to_entries[]? | .key' 2>/dev/null || true)
    fi
    for cport in "${ports[@]}"; do
      for k in 0 1; do
        [[ "$k" == "1" && "$cport" != "443" && "$cport" != "8443" && "$cport" != "2096" ]] && continue
        base="http://127.0.0.1:${cport}"
        [[ "$k" == "1" ]] && base="https://127.0.0.1:${cport}"
        PANEL_TRANSPORT="nsenter"
        PANEL_NS_PID="$pid"
        PANEL_NS_UNIX=""
        if [[ "$mode" == "token" ]]; then
          panel_try_login "$base" "$k" || { PANEL_TRANSPORT="$saved_transport"; continue; }
        else
          panel_probe_key "$base" "$k" || { PANEL_TRANSPORT="$saved_transport"; continue; }
        fi
        PANEL_URL="$base"
        PANEL_CONTAINER="$name"
        PANEL_NS_UNIX=""
        INSECURE="$k"
        state_set PANEL_URL "$base"
        state_set PANEL_CONTAINER "$name"
        state_set PANEL_TRANSPORT nsenter
        state_set PANEL_NS_UNIX ""
        ok "Panel API reachable inside container ${name} (${base})."
        return 0
      done
    done
  done
  PANEL_TRANSPORT="$saved_transport"
  PANEL_NS_PID=""; PANEL_NS_UNIX=""
  return 1
}

# the exact reason in PANEL_NETERR (curl error) or PANEL_HTTP/PANEL_BODY.
panel_try_login() {
  local base="$1" k="$2" tmp err code body
  tmp="$(mktemp)"; err="$(mktemp)"
  local -a opts=(-sS -X POST --connect-timeout 3 --max-time 12 \
                 -H 'Accept: application/json' -o "$tmp" -w '%{http_code}')
  if [[ "$k" == "1" ]]; then opts+=(-k); fi
  PANEL_NETERR=""; PANEL_HTTP=""; PANEL_BODY=""
  code="$(curl_panel "${opts[@]}" --data-urlencode "username=${PANEL_USER}" \
        --data-urlencode "password=${PANEL_PASS}" \
        "${base%/}/api/admin/token" 2>"$err")" || {
    PANEL_NETERR="$(tr '\n' ' ' < "$err" | cut -c1-240)"
    rm -f -- "$tmp" "$err"
    return 1
  }
  rm -f -- "$err"
  body="$(cat "$tmp")"; rm -f -- "$tmp"
  PANEL_ACCESS_TOKEN="$(jq -r '.access_token // empty' <<<"$body" 2>/dev/null || true)"
  if [[ -z "$PANEL_ACCESS_TOKEN" ]]; then
    PANEL_HTTP="$code"; PANEL_BODY="$(printf '%s' "$body" | head -c 240)"
    return 1
  fi
  return 0
}

panel_login() {
  if [[ -n "$PANEL_API_KEY" ]]; then
    PANEL_AUTH_MODE="api-key"
    PANEL_ACCESS_TOKEN="$PANEL_API_KEY"
    local configured="${PANEL_URL:-}" b url k pass
    local -a urls=() passes=(1)
    [[ "$INSECURE" == "1" ]] || passes+=(2)
    if [[ -n "$configured" ]]; then urls+=("$configured"); fi
    while IFS= read -r b; do
      [[ -n "$b" ]] || continue
      [[ " ${urls[*]:-} " == *" ${b} "* ]] || urls+=("$b")
    done < <(local_panel_urls)
    while IFS= read -r b; do
      [[ -n "$b" ]] || continue
      [[ " ${urls[*]:-} " == *" ${b} "* ]] || urls+=("$b")
    done < <(local_port_probes)
    while IFS= read -r b; do
      [[ -n "$b" ]] || continue
      [[ " ${urls[*]:-} " == *" ${b} "* ]] || urls+=("$b")
    done < <(panel_public_urls)
    if (( ${#urls[@]} == 0 )); then
      error "No panel URL configured and no local panel found."
      return 1
    fi
    # Plain HTTP URLs only need one attempt; HTTPS URLs also get a second
    # attempt with TLS verification relaxed when --insecure was not requested.
    local -a probes=() probe
    for url in "${urls[@]}"; do
      if [[ "$url" == https://* ]]; then
        probes+=("${url}|${INSECURE:-0}")
        [[ "$INSECURE" != "1" ]] && probes+=("${url}|1")
      else
        probes+=("${url}|0")
      fi
    done
    PANEL_BEST_HTTP=""; PANEL_BEST_BODY=""; PANEL_BEST_URL=""
    info "Checking ${#probes[@]} candidate panel endpoint(s) with the API key."
    for probe in "${probes[@]}"; do
      url="${probe%|*}"; k="${probe##*|}"
      if panel_probe_key "$url" "$k"; then
        PANEL_URL="$url"; INSECURE="$k"
        ok "Panel API key accepted at ${url}"
        return 0
      fi
    done
    if panel_exec_probe key; then return 0; fi
    if panel_nsenter_probe key; then return 0; fi
    error "The API key did not work on any panel endpoint."
    if [[ -n "$PANEL_NETERR" ]]; then error "  Last network error: ${PANEL_NETERR}"; fi
    error "  Last response (HTTP ${PANEL_HTTP}): ${PANEL_BODY}"
    if [[ -n "$PANEL_BEST_HTTP" ]]; then
      error "  First HTTP reply: ${PANEL_BEST_HTTP} at ${PANEL_BEST_URL}: ${PANEL_BEST_BODY}"
    fi
    local tried
    for tried in "${urls[@]}"; do info "  Tried: ${tried}"; done
    if have docker; then
      while IFS= read -r tried; do
        [[ -n "$tried" ]] && info "  Container: ${tried}"
      done < <(docker ps --format '{{.Names}} {{.Image}} {{.Ports}}' 2>/dev/null || true)
    fi
    warn "Create the key in Panel -> API Keys with cores:read + cores:update."
    warn "It must look like pg_key_<uuid>. Set --panel-url if the panel is remote."
    return 1
  fi
  if [[ -n "$PANEL_TOKEN" ]]; then
    PANEL_ACCESS_TOKEN="$PANEL_TOKEN"
    return 0
  fi
  if [[ -z "$PANEL_URL" && "$ALLOW_LOCAL_PANEL" != "1" ]]; then
    error "Panel URL is required. Use --panel-url URL."
    return 1
  fi
  if [[ -z "$PANEL_USER" ]]; then
    PANEL_USER="$(ui_read "Panel admin username: ")" || return 1
  fi
  if [[ -z "$PANEL_PASS" ]]; then
    PANEL_PASS="$(ui_read_secret "Panel admin password: ")" || return 1
  fi

  local configured="${PANEL_URL:-}" b url pass k configured_err="" auth_rejected=""
  local -a urls=() passes=(1)
  if [[ -n "$configured" ]]; then urls+=("$configured"); fi
  [[ "$INSECURE" == "1" ]] || passes+=(2)
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    [[ " ${urls[*]} " == *" ${b} "* ]] || urls+=("$b")
  done < <(local_panel_urls)
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    [[ " ${urls[*]} " == *" ${b} "* ]] || urls+=("$b")
  done < <(panel_public_urls)
  if [[ "$ALLOW_LOCAL_PANEL" == "1" ]]; then
    while IFS= read -r b; do
      [[ -n "$b" ]] || continue
      [[ " ${urls[*]} " == *" ${b} "* ]] || urls+=("$b")
    done < <(local_port_probes)
  fi

  for pass in "${passes[@]}"; do
    if [[ "$pass" == "2" ]]; then
      warn "Retrying with TLS certificate verification disabled (add --insecure to skip this)."
    fi
    for url in "${urls[@]}"; do
      k=0; [[ "$pass" == "2" || "$INSECURE" == "1" ]] && k=1
      if [[ -n "$configured" && "$url" != "$configured" ]]; then
        if [[ "$ALLOW_LOCAL_PANEL" != "1" ]]; then
          info "Skipping local panel ${url} (pass --allow-local-panel to use it)."
          continue
        fi
        warn "Using the LOCAL panel at ${url} because ${configured} is unreachable."
        warn "Make sure this is the panel that manages your users."
      elif [[ -z "$configured" && "$ALLOW_LOCAL_PANEL" != "1" ]]; then
        continue
      fi
      if panel_try_login "$url" "$k"; then
        PANEL_URL="$url"; INSECURE="$k"
        ok "Authenticated with the panel API at ${url}"
        if [[ "$k" == "1" ]]; then warn "TLS verification is disabled for this session."; fi
        return 0
      fi
      if [[ "$url" == "$configured" && -z "$configured_err" ]]; then
        if [[ -n "$PANEL_NETERR" ]]; then configured_err="network: ${PANEL_NETERR}"
        else configured_err="HTTP ${PANEL_HTTP}: ${PANEL_BODY}"; fi
      fi
      if [[ "$PANEL_HTTP" == "401" || "$PANEL_HTTP" == "403" ]] && [[ -z "$auth_rejected" ]]; then
        auth_rejected="$url"
      fi
    done
  done

  if panel_exec_probe token; then return 0; fi
  if panel_nsenter_probe token; then return 0; fi
  error "Panel login failed."
  error "  ${configured} -> ${configured_err:-unknown error}"
  if [[ -n "$auth_rejected" ]]; then
    warn "Panel API found at ${auth_rejected}, but the credentials were rejected (HTTP 401/403)."
    warn "Re-run with --panel-url ${auth_rejected} and the correct admin password."
  fi
  local u
  for u in "${urls[@]}"; do info "  Tried endpoint: ${u}"; done
  if (( ${#urls[@]} > 1 )); then
    warn "A panel is running locally. If THAT is the panel with your users,"
    warn "re-run with --allow-local-panel, or paste the snippets manually."
  else
    warn "Check DNS/TLS/firewall from this VPS. Admin user needs cores:read+update."
  fi
  return 1
}

panel_api() {
  local method="$1" path="$2" data="${3:-}"
  local bodyfile code
  bodyfile="$(mktemp)"
  local -a opts=(-sS -X "$method" --connect-timeout 10 --max-time 45 \
                 -H 'Accept: application/json' -o "$bodyfile" -w '%{http_code}')
  if [[ "$PANEL_AUTH_MODE" == "api-key" ]]; then
    opts+=(-H "X-Api-Key: ${PANEL_ACCESS_TOKEN}")
  else
    opts+=(-H "Authorization: Bearer ${PANEL_ACCESS_TOKEN}")
  fi
  [[ "$INSECURE" == "1" ]] && opts+=(-k)
  if [[ -n "$data" ]]; then
    opts+=(-H 'Content-Type: application/json' --data-binary "$data")
  fi
  code="$(curl_panel "${opts[@]}" "$(panel_endpoint)${path}" 2>/dev/null)" || {
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
     --argjson tunnel "$WARP_TUNNEL_TAGS" \
     --argjson apply "$([[ "$action" == "apply" ]] && echo 1 || echo 0)" \
     '
     def ours: (.tag // "") | test("^warp(-|$)");
     def our_rule: ((.outboundTag // "") | test("^warp(-|$)")) or (.balancerTag == "warp-pool");
     def is_block: (((.tag // "") | ascii_downcase) | test("block|blackhole"))
                   or (((.protocol // "") | ascii_downcase) | test("blackhole"));
     def is_block_rule: (.outboundTag // "") | ascii_downcase | test("block|blackhole");
     .config
     | .outbounds = ([ (.outbounds // [])[] | select(ours | not) ])
     | .routing   = (.routing // {})
     | .routing.rules = ([ (.routing.rules // [])[] | select(our_rule | not) ])
     | .routing.balancers = ([ (.routing.balancers // [])[] | select(.tag != "warp-pool") ])
     | if $apply == 1 then
         # Outbound order: the FIRST outbound is the default. Keep it untouched.
         # Insert WARP after the real freedom outbounds but BEFORE any trailing
         # BLOCK/blackhole outbound.
         (if $prepend == 1 then
            .outbounds = ($obs[0] + .outbounds)
          else
            (.outbounds // []) as $o
            | ([ range(0; ($o|length)) as $i
                 | select($o[$i] | is_block) | $i ] | min // ($o|length)) as $cut
            | .outbounds = ($o[0:$cut] + $obs[0] + $o[$cut:])
          end)
         # Rule order: Xray evaluates top-down, first match wins. Inbound-based
         # catch-all rules (Germany -> Out-DE, ...) must NOT shadow the WARP
         # domains rule. Keep leading BLOCK/security rules above it.
         | (.routing.rules // []) as $r
         | ([ range(0; ($r|length)) as $i
              | select(($r[$i] | is_block_rule) | not) | $i ]
            | min // ($r|length)) as $rcut
         # On the MAIN PANEL core, scope WARP to the "tunnel" inbounds only.
         # On an egress relay all configs share 3 inbounds, so a domain rule
         # would silently capture every user.
         | .routing.rules = ($r[0:$rcut]
             + (if ($tunnel | length) > 0 then
                  [ ($rules[0][0] | del(.domain) + { inboundTag: $tunnel }) ]
                else $rules[0] end)
             + $r[$rcut:])
         | .routing.balancers = (.routing.balancers + $bals[0])
         | if (.routing.balancers | length) == 0 then del(.routing.balancers) else . end
       else . end
     ' "$core_file" >"$out_file"
}

# Node health for the post-apply safety check. Returns a comma-separated list
# of node IDs currently in "error" state; silently yields nothing if the API
# key lacks the nodes:read permission or the panel is unreachable.
PANEL_HEALTH_AVAILABLE=0
PANEL_ERROR_IDS=""
PANEL_ERROR_BEFORE=""
# Sets globals directly (never call in $(...): a subshell would discard them).
panel_error_node_ids() {
  PANEL_ERROR_IDS=""
  PANEL_HEALTH_AVAILABLE=0
  panel_api GET "/nodes" 2>/dev/null || return 0
  PANEL_HEALTH_AVAILABLE=1
  PANEL_ERROR_IDS="$(jq -r '[.nodes[]? | select(.status == "error") | (.id | tostring)] | sort | join(",")' \
      <<<"$PANEL_API_BODY" 2>/dev/null || true)"
  return 0
}

# PUT the exact pre-apply Core config back.
panel_rollback_core() {
  local core_id="$1" snapshot="$2" body
  [[ -f "$snapshot" ]] || return 1
  body="$(jq -n --slurpfile c "$snapshot" '{
      name: ($c[0].name),
      config: ($c[0].config),
      type: ($c[0].type // null),
      exclude_inbound_tags: ($c[0].exclude_inbound_tags // []),
      fallbacks_inbound_tags: ($c[0].fallbacks_inbound_tags // [])
    }')" || return 1
  panel_api PUT "/core/${core_id}?restart_nodes=true" "$body" || return 1
  return 0
}

apply_to_panel() {
  local action="${1:-apply}"
  PANEL_APPLY_OK=0
  if [[ -z "$PANEL_URL" && -z "$PANEL_API_KEY" ]]; then
    warn "Panel URL and API key are not configured; skipping API apply."
    return 0
  fi
  have jq || die "jq is required for panel API integration."
  panel_login || { warn "Could not authenticate. Panel snippets are still available for manual paste."; return 0; }
  panel_error_node_ids
  PANEL_ERROR_BEFORE="$PANEL_ERROR_IDS"

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
      # With several Core configs, prefer the MAIN PANEL core (the one with
      # "... Tunnel ..." inbounds). This keeps --yes fully non-interactive and
      # never picks a shared egress relay by accident.
      local cid picked=""
      for cid in "${ids[@]}"; do
        panel_api GET "/core/${cid}" 2>/dev/null || continue
        if jq -e '[ (.config.inbounds // [])[] | .tag // empty
                    | select(ascii_downcase | test("tunnel")) ] | length > 0' \
             <<<"$PANEL_API_BODY" >/dev/null 2>&1; then
          picked="$cid"; break
        fi
      done
      if [[ -n "$picked" ]]; then
        core_id="$picked"
        info "Auto-selected Core config ${core_id} (it has the tunnel inbounds)."
      elif [[ "$ASSUME_YES" == "1" ]]; then
        core_id="${ids[0]}"
        warn "No Core config has tunnel inbounds; using the first one."
      else
        local c
        c="$(choose "Select the Core configuration used by the MAIN PANEL:" "${labels[@]}")" || return 1
        core_id="${ids[$((c - 1))]}"
      fi
    fi
  fi
  info "Using core config ID ${core_id}."

  panel_api GET "/core/${core_id}" || { warn "Could not read core config ${core_id}."; return 0; }
  local snapshot="$BACKUP_DIR/panel-core-${core_id}-$(now_tag).json"
  mkdir -p "$BACKUP_DIR"
  printf '%s\n' "$PANEL_API_BODY" | jq . >"$snapshot"
  chmod 600 "$snapshot"
  info "Panel core backup saved: ${snapshot}"

  # The WARP decision must be made where the user inbounds live. On the main
  # panel those are named "... Tunnel ..."; on an egress relay (Germany /
  # NetherLands / Poland / SOCKS5) all configs are merged into 3 inbounds and
  # a WARP rule there affects EVERY user.
  WARP_TUNNEL_TAGS="$(jq -c '[ (.config.inbounds // [])[] | .tag // empty
        | select(ascii_downcase | test("tunnel")) ]' "$snapshot" 2>/dev/null || echo '[]')"
  [[ -n "$WARP_TUNNEL_TAGS" ]] || WARP_TUNNEL_TAGS="[]"
  if [[ "$action" == "apply" ]]; then
    if [[ "$WARP_TUNNEL_TAGS" != "[]" ]]; then
      info "Found tunnel inbounds on this Core: ${WARP_TUNNEL_TAGS}. WARP applies ONLY to them."
    elif [[ "$ALL_TRAFFIC" == "1" ]]; then
      warn "No tunnel inbounds on this Core; --all-traffic applies WARP to all users."
    else
      error "This Core config has NO 'tunnel' inbound: it is a shared egress relay."
      error "Adding WARP here affects every config, because all users are merged into these inbounds."
      error "Run warp-manager on the MAIN PANEL server (where your users and inbounds are) instead."
      warn "See docs/ARCHITECTURE.md. Override only if you really want all traffic: --all-traffic"
      rm -f -- "$snapshot"
      return 1
    fi
  fi

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
      first_outbound: ($after[0].outbounds[0].tag // "unchanged"),
      outbound_order: [ $after[0].outbounds[].tag ],
      first_rules: [ $after[0].routing.rules[0:3][] | (.outboundTag // .balancerTag // "?") ] }' || true
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
  PANEL_APPLY_OK=1
  state_set_many "PANEL_URL=$PANEL_URL" "PANEL_API_KEY=$PANEL_API_KEY" \
    "PANEL_AUTH_MODE=$PANEL_AUTH_MODE" "PANEL_CORE_ID=$core_id" \
    "PANEL_LAST_APPLY=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "PANEL_LAST_BACKUP=$snapshot"
  cp -f -- "$merged" "$OUTPUT_DIR/core-config-preview.json"
  rm -f -- "$merged"
}

# -----------------------------------------------------------------------------
# Install wizard
# -----------------------------------------------------------------------------
print_target_guidance() {
  header "Deployment target - READ CAREFULLY"
  cat <<'TXT'
  Run this script on the MAIN PANEL server (Iran), where all user inbounds
  live. The foreign server is only an egress relay for its three IPs.

  Why: the foreign relay Core has just 3 location inbounds, so ALL 12 user
  configs are merged there. A WARP rule on that Core applies to EVERY user.
  On the main panel Core each config category is a separate inbound, so WARP
  can be scoped to the "... Tunnel ..." inbounds only. cdn / direct configs
  keep using the three foreign IPs.

    [ Clients ] ---> [ Iran / MAIN PANEL ] ---vless---> [ NL / DE / PL relay ]
                     12 separate inbounds              4 inbounds, 3 IPs
                     WARP decision HERE                keep this Core untouched

  The script refuses to apply to a Core with no tunnel inbound (a shared
  egress relay) unless --all-traffic is given. See docs/ARCHITECTURE.md 2.1.

  If Cloudflare's WARP registration API is unreachable from this server,
  create the account once on the foreign server and reuse it here:
      foreign: warp-manager export-profile
      here:    warp-manager import-profile 'WARP1:...'
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
  if [[ "$ROUTING" == "all" ]]; then RULE_PREPEND=1; else RULE_PREPEND=0; fi
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
  if [[ "$ROUTING" == "all" ]]; then
    RULE_PREPEND=1
    info "WARP outbound will be placed first in the outbounds array (default outbound)."
  else
    RULE_PREPEND=0
    info "WARP will be appended; your existing first outbound stays the default."
  fi
  return 0
}

choose_optional() {
  local ans
  ans="$(ui_read "WARP+ license key (optional, Enter to skip): ")" || return 1
  [[ -n "$ans" ]] && LICENSE_KEY="$ans"
  ans="$(ui_read "WARP endpoint [${ENDPOINT}]: ")" || return 1
  [[ -n "$ans" ]] && ENDPOINT="$ans"
  if [[ -z "$PANEL_API_KEY" ]]; then
    ans="$(ui_read_secret "Panel API key (Panel -> API Keys, pg_key_...; Enter to skip): ")" || return 1
    if [[ -n "$ans" ]]; then
      PANEL_API_KEY="$ans"
      APPLY_PANEL="yes"
    fi
  fi
  if [[ -z "$PANEL_URL" ]]; then
    ans="$(ui_read "Panel URL (Enter = auto-detect when an API key is set): ")" || return 1
    if [[ -n "$ans" ]]; then PANEL_URL="$ans"; fi
  fi
  if [[ -n "$PANEL_API_KEY" ]]; then
    return 0
  fi
  if [[ -n "$PANEL_URL" && -z "$PANEL_USER" ]]; then
    ans="$(ui_read "Panel admin username (used ONCE to create a dedicated API key; Enter to skip): ")" || return 1
    PANEL_USER="$ans"
    if [[ -n "$PANEL_USER" ]]; then
      ans="$(ui_read_secret "Panel admin password: ")" || return 1
      PANEL_PASS="$ans"
    fi
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
  if [[ -n "$PANEL_API_KEY" ]]; then
    printf '  %-22s %s\n' "Panel API" "${PANEL_URL:-auto-detect} (API key: set)"
  else
    printf '  %-22s %s\n' "Panel API" "${PANEL_URL:-not configured (manual paste)}"
  fi
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

# -----------------------------------------------------------------------------
# Two-server repair / health check (1.0.19)
# -----------------------------------------------------------------------------
# Both servers run this script. Option 1 (install) must never just stop: it
# installs a fresh setup, or repairs an existing dedicated WARP deployment.
write_server_guide() {
  local f="$APP_DIR/SERVER-GUIDE.md" host port
  host="$(state_get WARP_LINK_HOST "")"
  port="$(state_get WARP_LINK_PORT "")"
  mkdir -p "$APP_DIR" 2>/dev/null || return 0
  cat >"$f" <<GUIDE
# PasarGuard WARP Manager - TWO SERVERS REQUIRED

This script MUST be installed and run on BOTH servers. WARP itself terminates
on the FOREIGN relay; the IRAN main panel only carries one dedicated inbound.
Deleting the WARP inbound / outbound / routing rule on the FOREIGN server cuts
the WARP config on Iran. Do NOT test by deleting - use 'warp-manager warp-check'.

Saved WARP link on this host: __HOST__:__PORT__ (TCP, credentials in state.env).

## Install the script on BOTH servers (one time)

    curl -fsSL -H 'Accept: application/vnd.github.raw' 'https://api.github.com/repos/XiliService/Warp-Pasarguard/contents/install.sh?ref=arena/01417195-warp-pasarguard' | sudo bash -s -- --branch arena/01417195-warp-pasarguard

## FOREIGN relay server

    sudo warp-manager update --yes
    sudo warp-manager                      # menu option 1 (install / repair)
    sudo warp-manager warp-link --show     # print the saved WARPLINK1 line
    sudo warp-manager warp-check
    sudo warp-manager status

Keeps: WARP-LINK SOCKS inbound, warp outbound (before BLOCK), one scoped rule.

## IRAN MAIN PANEL server

    sudo warp-manager update --yes
    sudo warp-manager                      # menu option 1 (install / repair)
    sudo warp-manager warp-inbound 'WARPLINK1:...' --yes   # first time only
    sudo warp-manager warp-check
    sudo warp-manager status

Keeps: WARP-DEDICATED inbound (clone of a real VLESS/Reality inbound),
WARP-LINK SOCKS outbound (before BLOCK), one scoped rule.
Create the Host in the Panel: Hosts -> Add Host -> Inbound tag WARP-DEDICATED.

## Repair after anything was deleted (run in THIS order)

    # 1) FOREIGN server
    sudo warp-manager update --yes
    sudo warp-manager repair --yes

    # 2) IRAN server
    sudo warp-manager update --yes
    sudo warp-manager repair --yes

    # 3) BOTH servers
    sudo warp-manager warp-check

The saved link credentials in state.env (mode 0600) are reused, so no line has
to be pasted again. Full documentation: docs/TWO-SERVERS.md in the repository.
GUIDE
  sed -i "s/__HOST__/${host:-FOREIGN-IP}/; s/__PORT__/${port:-PORT}/" "$f" 2>/dev/null || true
  chmod 644 "$f" 2>/dev/null || true
  if [[ "${WARP_GUIDE_WRITTEN:-0}" != "1" ]]; then
    info "Per-server command guide written to ${f}"
    WARP_GUIDE_WRITTEN=1
  fi
}

warp_detect_role() {
  local in_tag link_pass imported
  in_tag="$(state_get WARP_IN_TAG "")"
  link_pass="$(state_get WARP_LINK_PASS "")"
  imported="$(state_get PROFILE_IMPORTED 0)"
  if [[ -n "$in_tag" ]]; then printf 'iran'; return 0; fi
  if [[ -n "$link_pass" && "$imported" == "1" ]]; then printf 'iran'; return 0; fi
  if [[ -n "$link_pass" ]]; then printf 'foreign'; return 0; fi
  printf 'none'
}

cmd_repair() {
  state_init
  load_saved_api_key; load_saved_panel_url
  have jq || die "jq is required."
  header "$APP_NAME v$SCRIPT_VERSION - Repair dedicated WARP"
  local role; role="$(warp_detect_role)"
  case "$role" in
    foreign)
      info "Detected role: FOREIGN relay server."
      info "Rebuilding the WARP-LINK inbound, WARP outbound and WARP rule from saved credentials."
      info "The Iran server needs NO change: the same port, user and password are reused."
      WARP_LINK_SHOW=0
      cmd_warp_link
      ;;
    iran)
      info "Detected role: IRAN MAIN PANEL server."
      local blob lh lp
      blob="$(warp_link_blob_from_state)" || die "No saved WARP link on this host. Run 'warp-manager warp-link --show' on the FOREIGN server and 'warp-inbound' here."
      lh="$(printf '%s' "$blob" | base64 -d 2>/dev/null | jq -r .host)"
      lp="$(printf '%s' "$blob" | base64 -d 2>/dev/null | jq -r .port)"
      if ! timeout 4 bash -c 'exec 3<>/dev/tcp/$1/$2' _ "$lh" "$lp" 2>/dev/null; then
        error "The FOREIGN WARP link ${lh}:${lp} is not reachable."
        info "FIRST run on the FOREIGN server: warp-manager repair --yes"
        info "THEN run 'warp-manager repair --yes' here again."
        info "Do not delete any inbound/outbound/rule to test the link; use 'warp-manager warp-check'."
        warn "Still rebuilding THIS server's WARP config so it is ready when the foreign link returns."
        WARP_SKIP_LINK_CHECK=1
      fi
      info "Rebuilding the dedicated WARP inbound, WARP-LINK outbound and its routing rule."
      cmd_warp_inbound ""
      WARP_SKIP_LINK_CHECK=0
      ;;
    none)
      if is_installed; then
        warn "WARP is installed but no dedicated two-server link is configured on this host."
        info "FOREIGN server:  warp-manager warp-link --yes"
        info "IRAN server:     warp-manager warp-inbound 'WARPLINK1:...' --yes"
        info "See docs/TWO-SERVERS.md for the full commands for BOTH servers."
      else
        info "Nothing is installed on this server yet. Running a fresh install..."
        cmd_install_fresh
      fi
      ;;
  esac
  write_server_guide
  info "Verify the whole path with: warp-manager warp-check"
  info "This script must be installed and run on BOTH servers. See docs/TWO-SERVERS.md and SERVER-GUIDE.md."
  return 0
}

cmd_warp_check() {
  state_init
  load_saved_api_key; load_saved_panel_url
  have jq || die "jq is required."
  header "$APP_NAME v$SCRIPT_VERSION - Dedicated WARP link check"
  local blob link lh lp lu ls role problems=0 probe cid cfg q
  blob="$(warp_link_blob_from_state)" \
    || die "No dedicated WARP link is configured here. Run 'warp-manager install' (option 1) first."
  link="$(printf '%s' "$blob" | base64 -d 2>/dev/null)" || die "Saved link data is invalid. Run 'warp-manager repair --yes'."
  lh="$(jq -r .host <<<"$link")"; lp="$(jq -r .port <<<"$link")"
  lu="$(jq -r .user <<<"$link")"; ls="$(jq -r .pass <<<"$link")"
  role="$(warp_detect_role)"
  printf '  %-20s %s\n' "Detected role" "$role"
  printf '  %-20s %s\n' "Foreign link" "${lh}:${lp}"
  printf '  %-20s %s\n' "Link credentials" "saved in state.env (0600)"

  if timeout 4 bash -c 'exec 3<>/dev/tcp/$1/$2' _ "$lh" "$lp" 2>/dev/null; then
    ok "FOREIGN WARP link port is reachable from this server."
  else
    bad "FOREIGN WARP link port is NOT reachable. Run 'warp-manager repair --yes' on the FOREIGN server."
    problems=$((problems + 1))
  fi
  if have curl; then
    probe="$(curl -sS --max-time 20 -x "socks5h://${lu}:${ls}@${lh}:${lp}" \
              https://ipinfo.io/json 2>/dev/null || true)"
    if printf '%s' "$probe" | jq -e '.org // "" | test("Cloudflare"; "i")' >/dev/null 2>&1; then
      ok "Live WARP path: $(printf '%s' "$probe" | jq -r '.ip + " / " + (.org // "?")')"
    else
      bad "Live WARP path did not reach Cloudflare: $(printf '%s' "$probe" | head -c 160)"
      problems=$((problems + 1))
    fi
  fi

  cid="$(state_get WARP_LINK_CORE "")"
  if [[ -n "$cid" && -n "$PANEL_API_KEY" ]] && panel_login >/dev/null 2>&1; then
    if panel_api GET "/core/${cid}" >/dev/null 2>&1; then
      cfg="$PANEL_API_BODY"
      if [[ "$role" == "foreign" ]]; then
        q='[ (.config.inbounds // [])[] | .tag ] as $i
           | [ (.config.outbounds // [])[] | .tag ] as $o
           | [ (.config.routing.rules // [])[] | .outboundTag ] as $r
           | ($i | index("WARP-LINK")) != null
             and ($o | index("warp")) != null
             and ($r | index("warp")) != null'
      else
        q='[ (.config.inbounds // [])[] | .tag ] as $i
           | [ (.config.outbounds // [])[] | .tag ] as $o
           | [ (.config.routing.rules // [])[] | .outboundTag ] as $r
           | ($i | index("WARP-DEDICATED")) != null
             and ($o | index("WARP-LINK")) != null
             and ($r | index("WARP-LINK")) != null'
      fi
      if jq -e "$q" <<<"$cfg" >/dev/null 2>&1; then
        ok "Panel Core ${cid} contains the WARP inbound, outbound and routing rule."
      else
        bad "Panel Core ${cid} is MISSING a WARP inbound, outbound or routing rule. Run 'warp-manager repair --yes'."
        problems=$((problems + 1))
      fi
    else
      warn "Could not read Panel Core ${cid}; skipping the Core config check."
    fi
  else
    warn "No usable Panel API key / Core id; skipping the Core config check."
  fi

  header "Both servers are required"
  if [[ "$role" == "iran" ]]; then
    info "FOREIGN server:  warp-manager update --yes && warp-manager repair --yes"
    info "IRAN server:     warp-manager update --yes && warp-manager repair --yes"
  else
    info "FOREIGN server:  warp-manager update --yes && warp-manager repair --yes"
    info "IRAN server:     warp-manager update --yes && warp-manager repair --yes"
  fi
  info "Do NOT delete WARP inbounds/outbounds/rules to test the link. Use 'warp-manager warp-check'."
  if (( problems == 0 )); then ok "Dedicated WARP link check: OK"; else warn "Dedicated WARP link check: ${problems} item(s) need attention."; fi
  return 0
}

cmd_install() {
  state_init
  if is_installed && [[ "$FORCE" != "1" ]]; then
    warn "WARP is already managed on this server. Option 1 will REPAIR it instead of reinstalling."
    cmd_repair
    return $?
  fi
  cmd_install_fresh
}

cmd_install_fresh() {
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
  load_saved_api_key

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

  local pre_install_backup
  pre_install_backup="$(make_full_backup pre-install)" || warn "Could not take a full backup; continuing anyway."
  if [[ -n "$pre_install_backup" ]]; then
    ok "Full backup taken before install: ${pre_install_backup}"
    ok "Restore with: warp-manager restore ${pre_install_backup}"
  fi

  if [[ "$APPLY_PANEL" != "no" && -z "$PANEL_API_KEY" ]]; then
    if ! ensure_api_key; then
      warn "Continuing without an API key; snippets will be written for manual paste."
    fi
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
    patch_node_composes
  fi

  state_set_many \
    "INSTALLED=1" "MODE=$MODE" "TARGET=$TARGET" "BINDING=$BINDING" \
    "ROUTING=$ROUTING" "ENDPOINT=$ENDPOINT" "DOMAINS=$DOMAINS_CSV" \
    "PROFILES=${names[*]}" "INSTALLED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "SCRIPT_VERSION=$SCRIPT_VERSION" "STATE_VERSION=1" "PANEL_URL=$PANEL_URL" \
    "PANEL_API_KEY=$PANEL_API_KEY"

  if [[ "$APPLY_PANEL" != "no" && ( -n "$PANEL_URL" || -n "$PANEL_API_KEY" ) ]]; then
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
  header "Two servers are required (dedicated WARP)"
  warn "The full WARP account/profile is now on THIS server. Do NOT use 'apply' for the dedicated setup."
  info "FOREIGN server:  warp-manager warp-link --yes      (prints one WARPLINK1: line)"
  info "IRAN server:     warp-manager warp-inbound 'WARPLINK1:...' --yes"
  info "BOTH servers:    warp-manager repair --yes  /  warp-manager warp-check"
  info "Install and run this script on BOTH servers. See docs/TWO-SERVERS.md."
  write_server_guide
}

# -----------------------------------------------------------------------------
# Dedicated API key: create ONCE, verify and reuse across all versions
# -----------------------------------------------------------------------------
# Create the dedicated key directly in the panel database. Used when no admin
# session is available (e.g. an env-only admin or a proxied dashboard domain).
# The panel stores key_hash as "v1$<b64url(sha256[:16])>$sha256$<sha256hex>".
create_api_key_via_db() {
  have docker || return 1
  have python3 || return 1
  local dbc env_json user pass dbname uuid raw lookup trimmed admin_id sql
  dbc="$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
        | awk '$2 ~ /timescale|postgres/ {print $1; exit}')"
  [[ -n "$dbc" ]] || return 1
  env_json="$(docker inspect "$dbc" --format '{{json .Config.Env}}' 2>/dev/null || true)"
  [[ -n "$env_json" && "$env_json" != "null" ]] || return 1
  user=""; pass=""; dbname=""
  if have jq; then
    user="$(jq -r '.[]? | select(startswith("POSTGRES_USER=")) | ltrimstr("POSTGRES_USER=")' <<<"$env_json" | head -n1)"
    pass="$(jq -r '.[]? | select(startswith("POSTGRES_PASSWORD=")) | ltrimstr("POSTGRES_PASSWORD=")' <<<"$env_json" | head -n1)"
    dbname="$(jq -r '.[]? | select(startswith("POSTGRES_DB=")) | ltrimstr("POSTGRES_DB=")' <<<"$env_json" | head -n1)"
  else
    user="$(grep -o 'POSTGRES_USER=[^"]*' <<<"$env_json" | head -n1 | cut -d= -f2-)"
    pass="$(grep -o 'POSTGRES_PASSWORD=[^"]*' <<<"$env_json" | head -n1 | cut -d= -f2-)"
    dbname="$(grep -o 'POSTGRES_DB=[^"]*' <<<"$env_json" | head -n1 | cut -d= -f2-)"
  fi
  user="${user:-postgres}"; pass="${pass:-}"; dbname="${dbname:-pasarguard}"

  # The panel may use a different database name than POSTGRES_DB. Probe a few
  # candidates and require both the admins and api_keys tables to be present.
  admin_id=""; local candidate db_ok=""
  for candidate in "$dbname" postgres pasarguard pasarguard_db panel "$user"; do
    [[ -n "$candidate" ]] || continue
    admin_id="$(docker exec -e PGPASSWORD="$pass" "$dbc" psql -U "$user" -d "$candidate" \
        -tAc 'SELECT id FROM admins ORDER BY id LIMIT 1' 2>/dev/null | tr -d '[:space:]')"
    [[ "$admin_id" =~ ^[0-9]+$ ]] || continue
    if docker exec -e PGPASSWORD="$pass" "$dbc" psql -U "$user" -d "$candidate" \
        -tAc 'SELECT 1 FROM api_keys LIMIT 1' >/dev/null 2>&1; then
      db_ok="$candidate"; break
    fi
  done
  if [[ -z "$db_ok" ]]; then return 1; fi
  local dbname="$db_ok"

  uuid="$(python3 -c 'import uuid; print(uuid.uuid4())')" || return 1
  local -a parts=()
  while IFS= read -r line; do parts+=("$line"); done < <(python3 - "$uuid" <<'PYHASH'
import sys, hashlib, base64
u = sys.argv[1]
raw = "pg_key_" + u
d = hashlib.sha256(raw.encode()).digest()
lookup = base64.urlsafe_b64encode(d[:16]).decode().rstrip("=")
hexd = hashlib.sha256(raw.encode()).hexdigest()
print(raw)
print("v1$%s$sha256$%s" % (lookup, hexd))
print("pg_key_%s***%s" % (u[:3], u[-3:]))
PYHASH
)
  [[ ${#parts[@]} -eq 3 ]] || return 1
  raw="${parts[0]}"; lookup="${parts[1]}"; trimmed="${parts[2]}"

  # All values are generated internally; no user input reaches this SQL.
  sql="BEGIN;
DELETE FROM api_keys WHERE name = '${PANEL_KEY_NAME}';
INSERT INTO api_keys (admin_id, name, key_hash, api_key_trimmed, permissions, inherit_permissions, note, status, created_at)
VALUES (${admin_id}, '${PANEL_KEY_NAME}', '${lookup}', '${trimmed}', '{}'::jsonb, TRUE, 'Created by WARP Manager; reused across versions', 'active', NOW());
COMMIT;"
  if ! printf '%s\n' "$sql" | docker exec -i -e PGPASSWORD="$pass" "$dbc" \
       psql -U "$user" -d "$db_ok" -v ON_ERROR_STOP=1 -q >/dev/null 2>&1; then
    return 1
  fi
  printf '%s' "$raw"
  return 0
}

# Dedicated API key: create ONCE, verify and reuse across all versions.
# Order: saved key -> official API with admin credentials -> local database.
ensure_api_key() {
  load_saved_api_key
  load_saved_panel_url
  if [[ -n "$PANEL_API_KEY" ]]; then
    if panel_login >/dev/null 2>&1; then
      info "Reusing the existing dedicated API key '${PANEL_KEY_NAME}'."
      return 0
    fi
    warn "Stored API key is no longer valid; creating a new one."
  fi

  local stale="$PANEL_API_KEY" session_out="" created=""
  if [[ -z "$PANEL_USER" || -z "$PANEL_PASS" ]]; then
    if [[ "$ASSUME_YES" != "1" && -r /dev/tty ]]; then
      PANEL_USER="$(ui_read "Panel admin username (used ONCE; Enter to skip): ")" || PANEL_USER=""
      if [[ -n "$PANEL_USER" ]]; then
        PANEL_PASS="$(ui_read_secret "Panel admin password (used once, never stored): ")" || PANEL_PASS=""
      fi
    fi
  fi
  if [[ -n "$PANEL_USER" && -n "$PANEL_PASS" ]]; then
    PANEL_API_KEY=""
    PANEL_AUTH_MODE="token"
    local saved_allow="$ALLOW_LOCAL_PANEL"
    ALLOW_LOCAL_PANEL="1"
    # Do NOT use $(...) here: a subshell would discard PANEL_ACCESS_TOKEN.
    local login_log; login_log="$(mktemp)"
    panel_login >"$login_log" 2>&1 || true
    session_out="$(cat "$login_log" 2>/dev/null || true)"
    rm -f -- "$login_log"
    ALLOW_LOCAL_PANEL="$saved_allow"
    if [[ -n "$PANEL_ACCESS_TOKEN" && "$PANEL_AUTH_MODE" == "token" ]] && \
       panel_api GET "/cores" >/dev/null 2>&1; then
      local ids payload key
      if panel_api GET "/api_keys?name=${PANEL_KEY_NAME}" >/dev/null 2>&1; then
        ids="$(jq -c '[.api_keys[]?.id]' <<<"$PANEL_API_BODY" 2>/dev/null || echo '[]')"
        if [[ "$ids" != "[]" ]]; then
          panel_api POST "/api_keys/bulk/delete" "{\"ids\":${ids}}" >/dev/null 2>&1 || true
        fi
      fi
      payload="$(jq -n --arg n "$PANEL_KEY_NAME" \
          '{name: $n, note: "Created by WARP Manager; reused across versions", inherit_permissions: true}')"
      if panel_api POST "/api_key" "$payload" >/dev/null 2>&1; then
        key="$(jq -r '.api_key // empty' <<<"$PANEL_API_BODY" 2>/dev/null || true)"
        if [[ -n "$key" ]]; then created="$key"; fi
      fi
    else
      info "Official API login unavailable: ${session_out:-no panel endpoint responded}."
    fi
  fi

  if [[ -z "$created" ]]; then
    warn "Creating the dedicated API key directly in the local panel database."
    warn "A full backup exists; only the '${PANEL_KEY_NAME}' row in api_keys is touched."
    created="$(create_api_key_via_db)" || created=""
  fi

  if [[ -z "$created" ]]; then
    PANEL_API_KEY="$stale"
    PANEL_AUTH_MODE="token"
    error "Could not create a dedicated API key automatically."
    warn "Create one in Panel -> API Keys and pass: --panel-key pg_key_... ."
    return 1
  fi

  PANEL_API_KEY="$created"
  PANEL_AUTH_MODE="api-key"
  PANEL_ACCESS_TOKEN="$created"
  state_set PANEL_API_KEY "$created"
  state_set PANEL_KEY_NAME "$PANEL_KEY_NAME"
  if [[ -n "$PANEL_URL" ]]; then state_set PANEL_URL "$PANEL_URL"; fi
  ok "Created dedicated API key '${PANEL_KEY_NAME}' and saved it for all future runs."
  if ! panel_login >/dev/null 2>&1; then
    warn "Key was created but no panel endpoint answered yet; 'apply' will retry."
  elif [[ -n "$PANEL_URL" ]]; then
    state_set PANEL_URL "$PANEL_URL"
  fi
  return 0
}

cmd_key() {
  state_init
  header "$APP_NAME v$SCRIPT_VERSION - API Key"
  load_saved_api_key
  load_saved_panel_url
  if ensure_api_key; then
    info "Key name: ${PANEL_KEY_NAME}"
    info "Stored at: ${STATE_FILE} (0600). Shared by every version of this script."
    return 0
  fi
  return 1
}

cmd_snippets() {
  state_init
  header "$APP_NAME v$SCRIPT_VERSION - Panel Snippets"
  local f
  for f in outbounds.json routing-rules.json balancers.json README.txt; do
    [[ -f "$OUTPUT_DIR/$f" ]] || die "Missing ${OUTPUT_DIR}/${f}. Run 'warp-manager import-profile' (or install on a host that reaches Cloudflare) first."
  done
  printf '\n--- 1) outbounds.json : paste into "outbounds" AFTER the first outbound, BEFORE any BLOCK ---\n'
  cat "$OUTPUT_DIR/outbounds.json"
  printf '\n--- 2) routing-rules.json : paste ABOVE all inbound->outbound rules (first match wins) ---\n'
  cat "$OUTPUT_DIR/routing-rules.json"
  printf '\n--- 3) balancers.json (single mode: empty, nothing to paste) ---\n'
  cat "$OUTPUT_DIR/balancers.json"
  cat <<'TXT'

IMPORTANT: copy only what is INSIDE the [ ] brackets - from the first { to
the last }. Do NOT paste the [ ] brackets into an existing array; add a comma
after the previous item first.

In the panel: Core Settings -> select the Core used by the EXIT NODE -> edit JSON.
Keep your existing first outbound first (routing=domains). Save, then run:
  warp-manager mark-applied --yes
TXT
  return 0
}

cmd_mark_applied() {
  state_init
  header "$APP_NAME v$SCRIPT_VERSION - Confirm Manual Panel Apply"
  state_set_many \
    "PANEL_LAST_APPLY=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "PANEL_APPLY_METHOD=manual"
  ok "Panel config marked as applied (manual paste)."
  info "Verify with: warp-manager status"
  return 0
}

cmd_fix_compose() {
  state_init
  header "$APP_NAME v$SCRIPT_VERSION - Fix Compose TUN Permissions"
  is_installed || warn "WARP is not marked as installed; this only patches docker-compose.yml."
  patch_node_composes
  info "Done. Recreate any container whose restart was declined."
  return 0
}

# -----------------------------------------------------------------------------
# WARP profile transfer: register the account once on a host that can reach
# Cloudflare, then reuse it on hosts that cannot (no new account, no API call).
# -----------------------------------------------------------------------------
cmd_export_profile() {
  state_init
  local names name f blob
  names="$(profile_list)"
  if [[ -z "$names" ]]; then
    # Fall back to any profile directory with a usable meta.env.
    for f in "$PROFILE_DIR"/*/meta.env; do
      [[ -f "$f" ]] || continue
      name="$(basename "$(dirname "$f")")"
      names="$name"; break
    done
  fi
  [[ -n "$names" ]] || die "No WARP profile found. Install WARP once on a host that can reach Cloudflare."
  name="${names%% *}"
  f="$PROFILE_DIR/$name/meta.env"
  [[ -f "$f" ]] || die "Profile '${name}' has no meta.env."
  grep -q '^PRIVATE_KEY=' "$f" || die "Profile '${name}' is incomplete."
  blob="$(base64 -w0 < "$f")" || die "Could not encode the profile."
  header "$APP_NAME v$SCRIPT_VERSION - Export WARP profile"
  warn "This line contains the WireGuard PRIVATE KEY. Keep it private and delete it after use."
  printf '\nWARP1:%s\n\n' "$blob"
  info "On the other server run: warp-manager import-profile 'WARP1:<line above>'"
  return 0
}

cmd_import_profile() {
  local blob="${1:-}" name="default" f tmp
  [[ -n "$blob" ]] || die "Usage: warp-manager import-profile 'WARP1:...' (get the line from export-profile)."
  state_init
  tmp="$(mktemp)"
  if ! printf '%s' "$blob" | base64 -d > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"; die "Invalid profile data: base64 decoding failed."
  fi
  grep -q '^PRIVATE_KEY=' "$tmp" || { rm -f -- "$tmp"; die "Invalid profile data: PRIVATE_KEY missing."; }
  grep -q '^PUBLIC_KEY=' "$tmp" || { rm -f -- "$tmp"; die "Invalid profile data: PUBLIC_KEY missing."; }
  grep -q '^ADDRESS4=' "$tmp" || { rm -f -- "$tmp"; die "Invalid profile data: ADDRESS4 missing."; }
  mkdir -p "$PROFILE_DIR/$name"; chmod 700 "$PROFILE_DIR/$name"
  mv -f -- "$tmp" "$PROFILE_DIR/$name/meta.env"
  chmod 600 "$PROFILE_DIR/$name/meta.env"
  state_set_many "INSTALLED=1" "MODE=xray" "TARGET=panel" "BINDING=single" \
    "ROUTING=domains" "DOMAINS=$DEFAULT_DOMAINS" "ENDPOINT=$DEFAULT_ENDPOINT" \
    "PROFILES=$name" "PROFILE_IMPORTED=1" "SCRIPT_VERSION=$SCRIPT_VERSION"
  MODE="xray"; ROUTING="domains"; DOMAINS_CSV="$DEFAULT_DOMAINS"
  MODERN_XRAY=1; RULE_PREPEND=0
  build_snippets "$name" || die "Could not generate the panel snippets from the imported profile."
  ok "WARP profile '${name}' imported. No Cloudflare registration was needed."
  info "Next: warp-manager apply --yes"
  return 0
}

# -----------------------------------------------------------------------------
# Dedicated WARP link: WARP terminates on the FOREIGN server (where Cloudflare
# is reachable) but only the "tunnel" configs on the IRAN main panel use it.
#
# warp-link  (foreign server): adds a private SOCKS inbound + WARP outbound and
#            a rule scoped to that inbound. No other config is touched.
# warp-join  (Iran server):    adds a SOCKS outbound to that inbound and splits
#            the tunnel inbound tags out of the existing location rules.
# -----------------------------------------------------------------------------
WARP_LINK_TAG="WARP-LINK"

panel_put_core() {
  local core_id="$1" snapshot="$2" merged="$3" body
  body="$(jq -n --slurpfile c "$snapshot" --slurpfile cfg "$merged" '{
      name: ($c[0].name),
      config: $cfg[0],
      type: ($c[0].type // null),
      exclude_inbound_tags: ($c[0].exclude_inbound_tags // []),
      fallbacks_inbound_tags: ($c[0].fallbacks_inbound_tags // [])
    }')" || return 1
  panel_api PUT "/core/${core_id}?restart_nodes=true" "$body" || return 1
  return 0
}

PANEL_SELECTED_CORE_ID=""
panel_authed_core() {
  local want_tunnel="$1" cid best=""
  PANEL_SELECTED_CORE_ID=""
  panel_login || return 1
  panel_api GET "/cores" || return 1
  local -a ids=()
  while IFS= read -r cid; do [[ -n "$cid" ]] && ids+=("$cid"); done \
    < <(jq -r '.cores[]? | .id' <<<"$PANEL_API_BODY" 2>/dev/null)
  (( ${#ids[@]} > 0 )) || return 1
  for cid in "${ids[@]}"; do
    panel_api GET "/core/${cid}" 2>/dev/null || continue
    local has
    has="$(jq -r '[ (.config.inbounds // [])[] | .tag // empty
                    | select(ascii_downcase | test("tunnel")) ] | length' \
          <<<"$PANEL_API_BODY" 2>/dev/null || echo 0)"
    if [[ "$want_tunnel" == "1" && "$has" != "0" ]] || \
       [[ "$want_tunnel" == "0" && "$has" == "0" ]]; then
      best="$cid"; break
    fi
  done
  if [[ -z "$best" ]]; then
    if [[ "$want_tunnel" == "1" ]]; then
      error "No Core config with tunnel inbounds was found. Set --core-id to the Iran main Core."
    else
      error "No Core config without tunnel inbounds was found. Set --core-id to the foreign relay Core."
    fi
    return 1
  fi
  PANEL_SELECTED_CORE_ID="$best"
  return 0
}

resolve_link_core() {
  local want="$1"
  PANEL_SELECTED_CORE_ID=""
  if [[ -n "${PANEL_CORE_ID:-}" ]]; then
    PANEL_SELECTED_CORE_ID="$PANEL_CORE_ID"; return 0
  fi
  panel_authed_core "$want"
}

require_clean_core_id() {
  local cid="${1:-}"
  [[ "$cid" =~ ^[0-9]+$ ]] || die "Invalid Core config ID '${cid}'. Use --core-id <number>."
}

cmd_warp_link() {
  state_init
  load_saved_api_key; load_saved_panel_url
  have jq || die "jq is required."
  if [[ "${WARP_LINK_SHOW:-0}" == "1" ]]; then
    local show_blob
    show_blob="$(warp_link_blob_from_state)" \
      || die "No saved WARP link on this host. Run 'warp-manager warp-link --yes' once."
    warn "This line contains the link password. Keep it private."
    printf '\nWARPLINK1:%s\n\n' "$show_blob"
    info "Nothing was changed. Copy the whole line above into the IRAN server."
    return 0
  fi
  local names; names="$(profile_list)"
  [[ -n "$names" ]] || die "No WARP profile on this host. Run 'warp-manager install' or 'import-profile' first."
  local -a profiles=(); read -r -a profiles <<<"$names"
  MODE="xray"; ROUTING="domains"; DOMAINS_CSV="$DEFAULT_DOMAINS"; MODERN_XRAY=1
  build_snippets "${profiles[@]}" >/dev/null || die "Could not build the WARP outbound."
  header "$APP_NAME v$SCRIPT_VERSION - Create dedicated WARP link (FOREIGN server)"
  [[ -n "$PANEL_API_KEY" ]] || ensure_api_key || die "Could not create/verify the Panel API key."
  resolve_link_core 0 || die "Could not choose the foreign relay Core config."
  local core_id="$PANEL_SELECTED_CORE_ID"
  require_clean_core_id "$core_id"
  info "Using Core config ${core_id} on this egress relay."
  panel_api GET "/core/${core_id}" || die "Could not read Core config ${core_id}."
  local snapshot="$BACKUP_DIR/warp-link-core-${core_id}-$(now_tag).json"
  printf '%s\n' "$PANEL_API_BODY" | jq . >"$snapshot"; chmod 600 "$snapshot"
  info "Core backup saved: ${snapshot}"

  local port user pass host used
  used="$(jq -r --arg t "$WARP_LINK_TAG" \
      '[ (.config.inbounds // [])[] | select((.tag // "") != $t) | .port // empty ] | join(",")' \
      "$snapshot" 2>/dev/null || true)"
  port="$(state_get WARP_LINK_PORT "")"
  user="$(state_get WARP_LINK_USER "")"
  pass="$(state_get WARP_LINK_PASS "")"
  if [[ -z "$port" || -z "$user" || -z "$pass" ]]; then
    port="$(( 20000 + RANDOM % 20000 ))"
    user="warp$(printf '%04x' "$RANDOM")"
    pass="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
  fi
  while [[ ",$used," == *",$port,"* ]]; do port="$(( 20000 + RANDOM % 20000 ))"; done
  host="${WARP_LINK_HOST:-}"
  if [[ -z "$host" ]] && have ip; then
    host="$(ip -4 route get 1.1.1.1 2>/dev/null \
            | awk '{ for (i=1; i<=NF; i++) if ($i == "src") print $(i+1) }' | head -n1 || true)"
  fi
  [[ -n "$host" ]] || host="$PRIMARY_IP"
  [[ -n "$host" ]] || host="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "$host" ]] || die "Could not determine this server's IP (set WARP_LINK_HOST)."

  local obs merged
  obs="$(cat "$OUTPUT_DIR/outbounds.json")"
  merged="$(mktemp)"
  if ! jq --argjson obs "$obs" --argjson port "$port" --arg user "$user" \
       --arg pass "$pass" --arg tag "$WARP_LINK_TAG" '
     .config
     | .outbounds = ([ (.outbounds // [])[]
         | select(((.tag // "") != "warp") and ((.tag // "") != $tag)) ])
     | .inbounds  = ([ (.inbounds  // [])[]
         | select((.tag // "") != $tag) ])
     | .routing = (.routing // {})
     | .routing.rules = ([ (.routing.rules // [])[]
         | select( ((.outboundTag // "") != "warp")
                   and (([(.inboundTag // [])[]] | index($tag)) == null) ) ])
     | (.outbounds) as $o
     | ([ range(0; ($o|length)) as $i
          | select( (($o[$i] | (.tag // "") | ascii_downcase | test("block|blackhole")))
                    or (($o[$i] | (.protocol // "") | ascii_downcase | test("blackhole"))) )
          | $i ] | min // ($o|length)) as $cut
     | .outbounds = ($o[0:$cut] + $obs + $o[$cut:])
     | .inbounds = (.inbounds + [{
         tag: $tag, protocol: "socks", port: $port, listen: "0.0.0.0",
         settings: { auth: "password", accounts: [{ user: $user, pass: $pass }],
                     udp: true, ip: "0.0.0.0" }
       }])
     | (.routing.rules) as $r
     | ([ range(0; ($r|length)) as $i
          | select((($r[$i] | (.outboundTag // "") | ascii_downcase
                     | test("block|blackhole")) | not)) | $i ]
        | min // ($r|length)) as $rcut
     | .routing.rules = ($r[0:$rcut]
         + [{ type: "field", inboundTag: [$tag], outboundTag: "warp" }]
         + $r[$rcut:])
   ' "$snapshot" >"$merged"; then
    rm -f -- "$merged"; die "Could not build the WARP link config."
  fi
  if ! confirm "Apply the dedicated WARP link to Core ${core_id} now?"; then
    warn "Skipped. Preview: ${merged}"; return 0
  fi
  if ! panel_put_core "$core_id" "$snapshot" "$merged"; then
    error "Panel update failed. Restore from ${snapshot}"; rm -f -- "$merged"; return 1
  fi
  state_set_many "WARP_LINK_HOST=$host" "WARP_LINK_PORT=$port" \
    "WARP_LINK_USER=$user" "WARP_LINK_PASS=$pass" "WARP_LINK_CORE=$core_id"
  local blob
  blob="$(jq -cn --arg h "$host" --argjson p "$port" --arg u "$user" \
      --arg s "$pass" --arg t "$WARP_LINK_TAG" \
      '{host:$h,port:$p,user:$u,pass:$s,tag:$t}' | base64 -w0)"
  warn "This line contains the link password. Keep it private."
  printf '\nWARPLINK1:%s\n\n' "$blob"
  ok "Dedicated WARP link created on port ${port}. ONLY traffic sent to this link uses WARP."
  info "The link listens on ${host}:${port} (TCP). If a firewall on the FOREIGN host filters it, allow that port; the node container uses host networking."
  info "On the IRAN main panel server run: warp-manager warp-inbound 'WARPLINK1:<line above>' --yes"
  info "BOTH servers need this script. To repair later: 'warp-manager repair --yes' on each server."
  info "Never delete the WARP inbound/outbound/rule to test; use 'warp-manager warp-check'."
  write_server_guide
  rm -f -- "$merged"
  return 0
}

# -----------------------------------------------------------------------------
# Dedicated WARP inbound (1.0.17)
# -----------------------------------------------------------------------------
# A brand-new inbound on the MAIN PANEL server is the ONLY thing routed to WARP.
# No existing inbound, outbound or routing rule is modified.
WARP_DEDICATED_TAG="WARP-DEDICATED"

warp_link_blob_from_state() {
  local h p u s t
  h="$(state_get WARP_LINK_HOST "")"; p="$(state_get WARP_LINK_PORT "")"
  u="$(state_get WARP_LINK_USER "")"; s="$(state_get WARP_LINK_PASS "")"
  t="$(state_get WARP_LINK_TAG "$WARP_LINK_TAG")"
  [[ -n "$h" && -n "$p" && -n "$u" && -n "$s" ]] || return 1
  jq -cn --arg h "$h" --argjson p "$p" --arg u "$u" \
      --arg s "$s" --arg t "$t" \
      '{host:$h,port:$p,user:$u,pass:$s,tag:$t}' | base64 -w0
}

warp_primary_ip() {
  local ip4=""
  if have ip; then
    ip4="$(ip -4 route get 1.1.1.1 2>/dev/null \
           | awk '{ for (i=1; i<=NF; i++) if ($i == "src") print $(i+1) }' \
           | head -n1 || true)"
  fi
  [[ -n "$ip4" ]] || ip4="${PRIMARY_IP:-}"
  [[ -n "$ip4" ]] || ip4="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  printf '%s' "$ip4"
}

cmd_warp_inbound() {
  local blob="${1:-}" link
  state_init
  load_saved_api_key; load_saved_panel_url
  have jq || die "jq is required."
  [[ "$blob" == WARPLINK1:* ]] && blob="${blob#WARPLINK1:}"
  [[ -n "$blob" ]] || blob="$(warp_link_blob_from_state)" \
    || die "Usage: warp-manager warp-inbound 'WARPLINK1:...'"
  link="$(printf '%s' "$blob" | base64 -d 2>/dev/null)" || die "Invalid link data."
  jq -e '.host and .port and .user and .pass and .tag' <<<"$link" >/dev/null 2>&1 \
    || die "Invalid link data (missing host/port/user/pass/tag)."

  header "$APP_NAME v$SCRIPT_VERSION - Dedicated WARP inbound (MAIN PANEL server)"
  local lh lp lu ls lt
  lh="$(jq -r .host <<<"$link")"; lp="$(jq -r .port <<<"$link")"
  lu="$(jq -r .user <<<"$link")"; ls="$(jq -r .pass <<<"$link")"
  lt="$(jq -r .tag <<<"$link")"
  if [[ "${WARP_SKIP_LINK_CHECK:-0}" == "1" ]]; then
    warn "Skipping the foreign link check (repair mode); rebuilding the local config anyway."
  elif ! timeout 4 bash -c 'exec 3<>/dev/tcp/$1/$2' _ "$lh" "$lp" 2>/dev/null; then
    die "The WARP link ${lh}:${lp} is not reachable from this server. Open TCP ${lp} on the FOREIGN server, then retry."
  else
    ok "WARP link ${lh}:${lp} is reachable from this server."
  fi

  # Real traffic test: Iran -> foreign SOCKS link -> WARP -> Cloudflare.
  if have curl && [[ "${WARP_SKIP_LINK_CHECK:-0}" != "1" ]]; then
    local probe
    probe="$(curl -sS --max-time 20 \
              -x "socks5h://${lu}:${ls}@${lh}:${lp}" \
              https://ipinfo.io/json 2>/dev/null || true)"
    if printf '%s' "$probe" | jq -e '.org // "" | test("Cloudflare"; "i")' >/dev/null 2>&1; then
      ok "Live WARP test through the foreign node: $(printf '%s' "$probe" | jq -r '.ip + " / " + (.org // "?")')"
    else
      warn "Live WARP test did not show a Cloudflare IP yet: $(printf '%s' "$probe" | head -c 160)"
    fi
  fi

  [[ -n "$PANEL_API_KEY" ]] || ensure_api_key || die "Could not create/verify the Panel API key."
  resolve_link_core 1 || die "Could not choose the MAIN PANEL Core config."
  local core_id="$PANEL_SELECTED_CORE_ID"
  require_clean_core_id "$core_id"
  info "Using Core config ${core_id} (MAIN PANEL server)."
  panel_api GET "/core/${core_id}" || die "Could not read Core config ${core_id}."
  local snapshot="$BACKUP_DIR/warp-inbound-core-${core_id}-$(now_tag).json"
  printf '%s\n' "$PANEL_API_BODY" | jq . >"$snapshot"; chmod 600 "$snapshot"
  info "Core backup saved: ${snapshot}"

  # Default to the LIVE Core config so any changes made in the Panel UI are
  # kept. Only fall back to the pre-join backup when the live rules are still
  # missing tunnel tags (the damage done by 1.0.15/1.0.16 warp-join).
  local base="$snapshot" prev damaged
  prev="$(ls -1t "$BACKUP_DIR"/warp-join-core-*.json 2>/dev/null | head -n1 || true)"
  damaged="$(jq -r '
     [ (.config.inbounds // [])[] | .tag // empty
       | select(ascii_downcase | test("tunnel")) ] as $t
     | [ (.config.routing.rules // [])[] | (.inboundTag // [])
         | if type == "array" then .[] else . end ] as $used
     | [ $t[] | select(. as $x | ($used | index($x)) == null) ] | length
   ' "$snapshot" 2>/dev/null || echo 0)"
  if [[ "${damaged:-0}" != "0" && -n "$prev" ]] \
     && jq -e '.config.inbounds and .config.outbounds' "$prev" >/dev/null 2>&1; then
    base="$prev"
    warn "Live rules are missing ${damaged} tunnel tag(s); restoring the original rules from ${prev}"
  else
    info "Using the live Core config as the baseline (existing rules are intact)."
  fi

  local inport tag="$WARP_DEDICATED_TAG" used
  inport="$(state_get WARP_IN_PORT "")"
  used="$(jq -r --arg t "$tag" \
        '[ (.config.inbounds // [])[] | select((.tag // "") != $t) | .port // empty ] | join(",")' \
        "$base" 2>/dev/null || true)"
  if [[ -z "$inport" || ",$used," == *",$inport,"* ]]; then
    inport="$(( 20000 + RANDOM % 20000 ))"
    while [[ ",$used," == *",$inport,"* ]]; do inport="$(( 20000 + RANDOM % 20000 ))"; done
  fi

  # Clone a REAL existing inbound (VLESS/Reality/etc.), not a SOCKS one: the
  # Panel only offers inbounds from the Core config for host creation, and
  # only a normal proxy inbound produces a v2rayNG / v2rayN client config.
  local src_tag clone protocol
  src_tag="$(jq -r --arg t "$tag" '
     [ (.config.inbounds // [])[] | select((.tag // "") != $t)
       | select(((.protocol // "") | ascii_downcase
                 | test("^(vless|vmess|trojan|shadowsocks)$"))) ] as $c
     | (([$c[] | select((.tag // "") | ascii_downcase | test("reality|dc"))] + $c)
        | .[0].tag // empty)
   ' "$base" 2>/dev/null || true)"
  [[ -n "$src_tag" ]] || die "No VLESS/VMESS/Trojan/Shadowsocks inbound to clone on Core ${core_id}. Create one normal inbound in the Panel first."
  clone="$(jq -c --arg t "$tag" --argjson p "$inport" --arg s "$src_tag" '
     [ (.config.inbounds // [])[] | select(.tag == $s) ][0]
     | .tag = $t | .port = $p
   ' "$base")" || die "Could not clone inbound ${src_tag}."
  protocol="$(jq -r .protocol <<<"$clone")"
  info "Cloning inbound '${src_tag}' (${protocol}) as '${tag}' on TCP port ${inport}."

  local merged; merged="$(mktemp)"
  if ! jq --argjson link "$link" --argjson clone "$clone" --arg tag "$tag" '
     def is_block:
       (((.outboundTag // "") | ascii_downcase | test("block|blackhole"))
        or ((.protocol // "") | ascii_downcase | test("blackhole")));
     .config
     | .outbounds = ([ (.outbounds // [])[]
         | select(((.tag // "") != "warp") and ((.tag // "") != $link.tag)) ])
     | .inbounds  = ([ (.inbounds  // [])[] | select((.tag // "") != $tag) ])
     | .routing = (.routing // {})
     | .routing.rules = ([ (.routing.rules // [])[]
         | select( ((.outboundTag // "") != "warp")
                   and ((.outboundTag // "") != $link.tag)
                   and (([(.inboundTag // [])[]] | index($tag)) == null) ) ])
     | (.outbounds) as $o
     | ([ range(0; ($o|length)) as $i | select(($o[$i] | is_block)) | $i ]
        | min // ($o|length)) as $cut
     | .outbounds = ($o[0:$cut] + [{
          tag: $link.tag, protocol: "socks",
          settings: { servers: [{ address: $link.host, port: $link.port,
                                  users: [{ user: $link.user, pass: $link.pass }] }] }
        }] + $o[$cut:])
     | .inbounds = (.inbounds + [$clone])
     | (.routing.rules) as $r
     | ([ range(0; ($r|length)) as $i | select((($r[$i] | is_block) | not)) | $i ]
        | min // ($r|length)) as $rcut
     | .routing.rules = ($r[0:$rcut]
         + [{ type: "field", inboundTag: [$tag], outboundTag: $link.tag }]
         + $r[$rcut:])
   ' "$base" >"$merged"; then
    rm -f -- "$merged"; die "Could not build the dedicated WARP inbound config."
  fi

  if ! confirm "Add the dedicated WARP inbound to Core ${core_id} now?"; then
    warn "Skipped. Preview: ${merged}"; return 0
  fi
  if ! panel_put_core "$core_id" "$snapshot" "$merged"; then
    error "Panel update failed. Restore from ${snapshot}"; rm -f -- "$merged"; return 1
  fi
  state_set_many "WARP_LINK_HOST=$lh" "WARP_LINK_PORT=$lp" \
    "WARP_LINK_USER=$lu" "WARP_LINK_PASS=$ls" "WARP_LINK_TAG=$lt" \
    "WARP_LINK_CORE=$core_id" "WARP_IN_TAG=$tag" "WARP_IN_PORT=$inport" \
    "WARP_IN_SOURCE=$src_tag" "WARP_IN_PROTOCOL=$protocol" \
    "PANEL_LAST_APPLY=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local myip; myip="$(warp_primary_ip)"
  header "New dedicated WARP inbound (only this config uses WARP)"
  printf '  %-16s %s\n' "Inbound tag" "$tag"
  printf '  %-16s %s\n' "Protocol" "$protocol"
  printf '  %-16s %s\n' "Cloned from" "$src_tag"
  printf '  %-16s %s\n' "Port (TCP)" "$inport"
  printf '  %-16s %s\n' "Server address" "${myip:-THIS-SERVER-IP}"
  header "Create the host in the Panel now"
  printf '  %s\n' "Hosts -> Add Host -> Inbound tag: ${tag}"
  printf '  %s\n' "Address: ${myip:-THIS-SERVER-IP}   Port: ${inport}   (leave the other fields at their defaults)"
  info "The Panel lists this inbound immediately after the Core update. The generated config works in v2rayNG / v2rayN."
  info "Allow TCP ${inport} on the IRAN host firewall. Only the host(s) you create on ${tag} use WARP."
  info "The FOREIGN server must keep its WARP-LINK inbound/outbound/rule; if it is removed this config stops."
  info "BOTH servers need this script: to repair run 'warp-manager repair --yes' on each. See docs/TWO-SERVERS.md."
  info "Do not delete WARP items to test the link; run 'warp-manager warp-check'."
  ok "All existing cdn / direct / tunnel inbounds and their routing rules are unchanged."
  write_server_guide
  rm -f -- "$merged"
  return 0
}

cmd_warp_join() {
  warn "warp-join now creates a dedicated WARP inbound; it no longer changes existing tunnel rules."
  cmd_warp_inbound "$@"
}

cmd_warp_unlink() {
  state_init
  load_saved_api_key; load_saved_panel_url
  have jq || die "jq is required."
  header "$APP_NAME v$SCRIPT_VERSION - Remove dedicated WARP inbound"
  [[ -n "$PANEL_API_KEY" ]] || ensure_api_key || die "Could not create/verify the Panel API key."
  resolve_link_core 1 || die "Could not choose the MAIN PANEL Core config."
  local core_id="$PANEL_SELECTED_CORE_ID"
  require_clean_core_id "$core_id"
  panel_api GET "/core/${core_id}" || die "Could not read Core config ${core_id}."
  local snapshot="$BACKUP_DIR/warp-unlink-core-${core_id}-$(now_tag).json"
  printf '%s\n' "$PANEL_API_BODY" | jq . >"$snapshot"; chmod 600 "$snapshot"
  info "Core backup saved: ${snapshot}"

  # Surgical removal from the LIVE config: keeps anything else the operator
  # changed in the Panel UI, and leaves all original rules intact.
  local merged; merged="$(mktemp)"
  if ! jq --arg tag "$WARP_DEDICATED_TAG" --arg link "$WARP_LINK_TAG" '
     .config
     | .inbounds  = ([ (.inbounds // [])[] | select((.tag // "") != $tag) ])
     | .outbounds = ([ (.outbounds // [])[]
         | select(((.tag // "") != "warp") and ((.tag // "") != $link)) ])
     | .routing = (.routing // {})
     | .routing.rules = ([ (.routing.rules // [])[]
         | select( ((.outboundTag // "") != "warp")
                   and ((.outboundTag // "") != $link)
                   and (([(.inboundTag // [])[]] | index($tag)) == null) ) ])
   ' "$snapshot" >"$merged"; then
    rm -f -- "$merged"; die "Could not build the cleaned Core config."
  fi
  if ! confirm "Remove the dedicated WARP inbound from Core ${core_id} now?"; then
    warn "Skipped."; rm -f -- "$merged"; return 0
  fi
  if ! panel_put_core "$core_id" "$snapshot" "$merged"; then
    error "Panel update failed. Restore from ${snapshot}"; rm -f -- "$merged"; return 1
  fi
  rm -f -- "$merged"
  state_set_many "WARP_IN_TAG=" "WARP_IN_PORT=" "WARP_IN_SOURCE=" "WARP_IN_PROTOCOL="
  warn "Delete any Hosts you created for ${WARP_DEDICATED_TAG} in the Panel UI manually."
  ok "Core ${core_id} cleaned. All existing configs keep their original rules and work exactly as before."
  return 0
}

cmd_apply() {
  local action="${1:-apply}"
  state_init
  load_saved_api_key
  header "$APP_NAME v$SCRIPT_VERSION - Apply Panel Config (${action})"
  have jq || die "jq is required for panel API integration."
  if [[ -z "$PANEL_API_KEY" ]]; then
    ensure_api_key || die "Could not create/verify a dedicated API key. Run 'warp-manager key'."
  fi
  if [[ -z "$PANEL_URL" && -z "$PANEL_API_KEY" ]]; then
    die "Provide --panel-key KEY, or run 'warp-manager key' first."
  fi
  local saved_routing
  saved_routing="$(state_get ROUTING domains)"
  if [[ "$saved_routing" == "all" ]]; then RULE_PREPEND=1; else RULE_PREPEND=0; fi
  if [[ "$action" == "apply" ]]; then
    info "Step 1/2 - ensure every node container has /dev/net/tun."
    patch_node_composes || warn "Compose patching had a problem; TUN may already be available on the host."
    info "Step 2/2 - push the WARP outbound/rules into the panel Core Settings."
  else
    info "Removing the WARP outbound/rules from the panel Core Settings."
  fi
  if [[ "$action" == "apply" ]]; then
    # Always rebuild the snippets from the stored wgcf profile. A script update
    # that fixes the WireGuard outbound must take effect WITHOUT reinstalling.
    local names_csv; names_csv="$(profile_list)"
    if [[ -n "$names_csv" ]]; then
      local -a profiles=()
      read -r -a profiles <<<"$names_csv"
      MODE="$(state_get MODE xray)"
      BINDING="$(state_get BINDING single)"
      ROUTING="$(state_get ROUTING domains)"
      DOMAINS_CSV="$(state_get DOMAINS "$DEFAULT_DOMAINS")"
      ENDPOINT="$(state_get ENDPOINT "$DEFAULT_ENDPOINT")"
      build_snippets "${profiles[@]}" || die "Could not rebuild the WARP snippets."
      info "Rebuilt the WARP outbound from the stored WARP profile (userspace WireGuard)."
    fi
  fi
  local f
  for f in outbounds.json routing-rules.json balancers.json; do
    [[ -f "$OUTPUT_DIR/$f" ]] || die "Missing ${OUTPUT_DIR}/${f}. Run 'warp-manager install' first."
  done
  apply_to_panel "$action"
  [[ "$PANEL_APPLY_OK" == "1" ]] || die \
    "Panel config was NOT applied. Read the error above, or paste the snippets manually (see ${OUTPUT_DIR}/README.txt)."
  if [[ "$action" == "apply" ]]; then
    # Safety net: if a node went into "error" after the change, restore the
    # exact pre-apply Core config automatically instead of leaving all users
    # disconnected.
    info "Verifying node health after the change (10s)..."
    sleep 10
    panel_error_node_ids
    local after="$PANEL_ERROR_IDS"
    if [[ "$PANEL_HEALTH_AVAILABLE" == "1" && -n "$after" && "$after" != "$PANEL_ERROR_BEFORE" ]]; then
      error "A node reported an error after applying WARP. Rolling back automatically."
      local rb_core rb_snap
      rb_core="$(state_get PANEL_CORE_ID '')"
      rb_snap="$(state_get PANEL_LAST_BACKUP '')"
      if [[ -n "$rb_core" && -n "$rb_snap" && -f "$rb_snap" ]] && \
         panel_rollback_core "$rb_core" "$rb_snap"; then
        warn "Rolled back to ${rb_snap}. Your other configs are restored."
        state_set PANEL_LAST_APPLY "rolled-back"
        HANDLED_ERROR=1
        return 1
      fi
      error "Automatic rollback failed. Run: warp-manager unapply --yes"
      HANDLED_ERROR=1
      return 1
    fi
    ok "WARP is now ACTIVE in the panel config."
    info "Final test, from a CLIENT config: https://ipinfo.io/json with 'tunnel' vs 'direct'."
  else
    ok "WARP outbound/rules removed from the panel config."
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Full backup (panel files + database + compose + core configs)
# -----------------------------------------------------------------------------
backup_target_dirs() {
  local d f
  local -a dirs=()
  for d in "$APP_DIR" /opt/pasarguard /var/lib/pasarguard /opt/pasarguard-warp \
           /opt/pg-node /var/lib/pg-node /etc/wireguard \
           /opt/out-node /opt/main-node; do
    [[ -d "$d" ]] && dirs+=("$d")
  done
  while IFS='|' read -r f _ _; do
    d="$(dirname "$f" 2>/dev/null || true)"
    [[ -n "$d" && -d "$d" ]] && dirs+=("$d")
  done < <(node_compose_targets)
  if (( ${#dirs[@]} > 0 )); then printf '%s\n' "${dirs[@]}" | awk '!seen[$0]++'; fi
  return 0
}

# Prints ONLY the backup directory on stdout. All progress goes to stderr.
make_full_backup() {
  local label="${1:-manual}" tag dest
  tag="$(now_tag)"
  dest="$BACKUP_DIR/full-${tag}-${label}"
  mkdir -p "$dest/files" "$dest/db" "$dest/compose" "$dest/cores" || return 1

  local d name
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    name="$(printf '%s' "${d#/}" | tr '/' '_')"
    if tar czf "$dest/files/${name}.tar.gz" -C "$(dirname "$d")" \
        --exclude="$(basename "$d")/logs" \
        --exclude="$(basename "$d")/backups/full-*" \
        "$(basename "$d")" >/dev/null 2>&1; then
      info "  Files: ${d}" >&2
    else
      warn "  Could not archive ${d}" >&2
    fi
  done < <(backup_target_dirs)

  local dbc env_json user pass dbname pc url cand
  if have docker; then
    dbc="$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
          | awk '$2 ~ /timescale|postgres/ {print $1; exit}')"
    if [[ -n "$dbc" ]] && have jq; then
      env_json="$(docker inspect "$dbc" --format '{{json .Config.Env}}' 2>/dev/null || true)"
      user="$(jq -r '.[]? | select(startswith("POSTGRES_USER=")) | ltrimstr("POSTGRES_USER=")' <<<"$env_json" | head -n1)"
      pass="$(jq -r '.[]? | select(startswith("POSTGRES_PASSWORD=")) | ltrimstr("POSTGRES_PASSWORD=")' <<<"$env_json" | head -n1)"
      dbname="$(jq -r '.[]? | select(startswith("POSTGRES_DB=")) | ltrimstr("POSTGRES_DB=")' <<<"$env_json" | head -n1)"
      [[ -n "$user" ]] || user="postgres"
      [[ -n "$dbname" ]] || dbname="pasarguard"
      if docker exec -e PGPASSWORD="$pass" "$dbc" pg_dumpall -U "$user" \
           >"$dest/db/pg_dumpall.sql" 2>/dev/null; then
        info "  Database: pg_dumpall from ${dbc}" >&2
        printf '%s\n' "$dbc" > "$dest/db/container.txt"
      elif docker exec -e PGPASSWORD="$pass" "$dbc" pg_dump -U "$user" -d "$dbname" \
           >"$dest/db/pg_dump.sql" 2>/dev/null; then
        info "  Database: pg_dump from ${dbc}" >&2
        printf '%s\n' "$dbc" > "$dest/db/container.txt"
      else
        warn "  PostgreSQL dump failed - copy the DB volume manually." >&2
      fi
      printf '%s\n' "$user" > "$dest/db/user.txt"
      printf '%s\n' "$dbname" > "$dest/db/name.txt"
      chmod 600 "$dest/db/container.txt" "$dest/db/user.txt" "$dest/db/name.txt" 2>/dev/null || true
    fi
    pc="$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
         | awk '$2 ~ /pasarguard\/panel/ {print $1; exit}')"
    if [[ -n "$pc" ]]; then
      url="$(docker inspect "$pc" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
            | grep '^SQLALCHEMY_DATABASE_URL=sqlite' | head -n1 | cut -d= -f2- || true)"
      if [[ -n "$url" ]]; then
        cand="${url#*///}"
        for cand in "$cand" "/app/$cand" "/opt/pasarguard/$cand"; do
          if docker cp "$pc:$cand" "$dest/db/db.sqlite3" >/dev/null 2>&1; then
            info "  Database: SQLite copy" >&2
            break
          fi
        done
      fi
    fi
  fi

  local cf
  while IFS='|' read -r cf _ _; do
    [[ -f "$cf" ]] || continue
    ( cd "$(dirname "$cf")" && docker compose -f "$(basename "$cf")" config ) \
      >"$dest/compose/$(basename "$(dirname "$cf")").yml" 2>/dev/null || true
  done < <(node_compose_targets)

  # Application-level core configs (best effort, needs an API key).
  if [[ -n "$PANEL_API_KEY" ]] && have jq; then
    local saved_mode="$PANEL_AUTH_MODE" saved_token="$PANEL_ACCESS_TOKEN"
    if panel_login >/dev/null 2>&1 && panel_api GET "/cores" >/dev/null 2>&1; then
      local list="$PANEL_API_BODY" id
      while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        if panel_api GET "/core/${id}" >/dev/null 2>&1; then
          printf '%s\n' "$PANEL_API_BODY" | jq . >"$dest/cores/core-${id}.json" 2>/dev/null || true
        fi
      done < <(jq -r '.cores[]?.id' <<<"$list" 2>/dev/null)
      info "  Panel core configs saved as JSON" >&2
    fi
    PANEL_AUTH_MODE="$saved_mode"; PANEL_ACCESS_TOKEN="$saved_token"
  fi

  {
    printf 'PasarGuard WARP Manager - full backup manifest\n'
    printf 'Created:   %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'Host:      %s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf 'Version:   %s\n' "$SCRIPT_VERSION"
    printf 'Label:     %s\n' "$label"
    printf 'Contains:  panel/node files, PostgreSQL or SQLite dump, compose configs, core JSON\n'
  } >"$dest/MANIFEST.txt"

  cat >"$dest/RESTORE.md" <<'TXT'
# Restoring this backup

STOP the panel before restoring the database:

    cd /opt/pasarguard && docker compose down

1) Restore files (compose, .env, certs, node dirs, WARP profiles):

    warp-manager restore /PATH/TO/THIS/DIRECTORY
    # If the manager command was uninstalled, this is equivalent:
    bash /PATH/TO/THIS/DIRECTORY/restore.sh

2) Restore the database (pick the file that exists in db/):

    docker compose -f /opt/pasarguard/docker-compose.yml up -d <db-service>
    cat db/pg_dumpall.sql | docker exec -i <db-container> psql -U <user>
    # or, for a single-database dump:
    cat db/pg_dump.sql | docker exec -i <db-container> psql -U <user> -d <dbname>
    # or, for SQLite: docker cp db/db.sqlite3 <panel-container>:/app/db.sqlite3

3) Recreate containers:

    cd /opt/pasarguard && docker compose up -d
    cd /opt/out-node  && docker compose up -d   # repeat for every node

Core Settings are also saved individually in cores/core-<id>.json and in
/opt/pasarguard-warp/backups/panel-core-<id>-*.json - they can be pasted back
into the panel UI if only the Core config needs rolling back.
TXT

  cat >"$dest/restore.sh" <<'EOF'
#!/usr/bin/env bash
# Generated by warp-manager. Review before running.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
for f in "$SRC"/files/*.tar.gz; do
  [[ -f "$f" ]] || continue
  echo "Restoring $f"
  tar xzf "$f" -C /
done
echo "Files restored. See RESTORE.md for the database steps."
EOF
  chmod 700 "$dest/restore.sh"
  chmod 600 "$dest"/db/* 2>/dev/null || true
  printf '%s' "$dest"
  return 0
}

cmd_backup() {
  state_init
  load_saved_api_key
  header "$APP_NAME v$SCRIPT_VERSION - Full Backup"
  local dest
  dest="$(make_full_backup "${BACKUP_LABEL:-manual}")" || die "Backup failed."
  ok "Full backup saved: ${dest}"
  info "Size: $(du -sh "$dest" 2>/dev/null | awk '{print $1}')"
  info "Restore: warp-manager restore ${dest}"
  return 0
}

cmd_restore() {
  local src="${1:-}"
  [[ -n "$src" && -d "$src" ]] || die "Usage: warp-manager restore /opt/pasarguard-warp/backups/full-..."
  state_init
  header "$APP_NAME v$SCRIPT_VERSION - Restore"
  warn "This OVERWRITES panel/node/WARP files. Stop the panel containers first."
  cat "$src/MANIFEST.txt" 2>/dev/null || true
  if ! confirm "Restore files from this backup?"; then warn "Cancelled."; return 0; fi
  local f
  for f in "$src"/files/*.tar.gz; do
    [[ -f "$f" ]] || continue
    if tar xzf "$f" -C /; then ok "Restored $(basename "$f")"; else warn "Failed: $(basename "$f")"; fi
  done
  if [[ -f "$src/db/pg_dumpall.sql" || -f "$src/db/pg_dump.sql" || -f "$src/db/db.sqlite3" ]]; then
    warn "The database was NOT restored automatically. See ${src}/RESTORE.md."
  fi
  ok "File restore complete. Restart the panel with: cd /opt/pasarguard && docker compose up -d"
  return 0
}

# -----------------------------------------------------------------------------
# Remove
# -----------------------------------------------------------------------------
cmd_remove() {
  state_init
  load_saved_api_key
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
  This stops WARP interfaces / removes config files created by this tool,
  deletes the WARP account, and rolls back the /dev/net/tun compose patch.
  Panel Core Settings are cleaned automatically ONLY when a working API key
  is available. Otherwise remove the WARP outbound/rules manually in the
  panel UI BEFORE reinstalling, or duplicates will appear.
  A full backup (files + database) is taken automatically first.
TXT
  line
  if ! confirm "Continue with removal?"; then warn "Cancelled."; return 0; fi
  [[ "$DRY_RUN" == "1" ]] && { info "Dry-run complete. No changes were made."; return 0; }

  local pre_remove_backup
  pre_remove_backup="$(make_full_backup pre-remove)" || warn "Could not take a full backup; continuing anyway."
  if [[ -n "$pre_remove_backup" ]]; then
    ok "Full backup taken before removal: ${pre_remove_backup}"
    ok "Restore with: warp-manager restore ${pre_remove_backup}"
  fi

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

  if [[ "$APPLY_PANEL" != "no" && ( -n "$PANEL_URL" || -n "$PANEL_API_KEY" ) ]]; then
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

  if [[ "$UNINSTALL_MANAGER" != "1" && "$ASSUME_YES" == "1" ]]; then
    info "Keeping the 'warp-manager' command (pass --uninstall-manager to remove it)."
  elif [[ "$UNINSTALL_MANAGER" == "1" ]] || confirm "Also uninstall the manager command and logs? (backups are ALWAYS kept)"; then
    rm -f -- "$BIN_LINK"
    local x
    for x in "$APP_DIR"/* "$APP_DIR"/.[!.]*; do
      [[ -e "$x" ]] || continue
      case "$(basename "$x")" in
        backups|warp-manager.sh) continue ;;
      esac
      rm -rf -- "$x"
    done
    ok "Manager command removed. Backups and the script remain in ${APP_DIR}."
    ok "Restore any time with: bash ${APP_DIR}/warp-manager.sh restore <backup-dir>"
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
    if fetch "$url" "$tmp" 2>/dev/null; then
      fetched=1
      for b in "${branches[@]}"; do
        if [[ "$url" == *"ref=${b}"* || "$url" == *"/${b}/warp-manager.sh"* || "$url" == *"/heads/${b}/warp-manager.sh"* ]]; then
          REPO_BRANCH="$b"; break
        fi
      done
      break
    fi
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
    if [[ ! -f "$PROFILE_DIR/$n/wgcf-account.toml" ]]; then
      if [[ "$(state_get PROFILE_IMPORTED 0)" == "1" ]]; then
        ok "  Reused WARP account (imported profile; no wgcf account file needed)."
      else
        warn "  Account file missing for ${n}."; problems=$((problems + 1))
      fi
    fi
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
  if [[ "$installed" == "1" && "$(state_get PANEL_LAST_APPLY never)" == "never" ]]; then
    bad "  NOT ACTIVE - the snippets were generated but NOT applied to the panel."
    bad "  If the panel API is unreachable: 'warp-manager snippets' + paste manually."
    problems=$((problems + 1))
  else
    ok "  Panel config applied ($(state_get PANEL_APPLY_METHOD api)) at $(state_get PANEL_LAST_APPLY never)"
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
    info "  Xray backend: traffic must be tested from a CLIENT config, not this server."
    if [[ "$routing" == "all" ]]; then
      info "  routing=all: https://www.cloudflare.com/cdn-cgi/trace -> warp=on."
    else
      info "  routing=domains: only the listed domains use WARP."
      info "  Test with a listed domain (e.g. https://ipinfo.io) -> Cloudflare egress IP."
      info "  www.cloudflare.com is NOT listed, so it will show warp=off (expected)."
    fi
  fi
  line

  if [[ "$installed" == "1" && "$(state_get PANEL_LAST_APPLY never)" == "never" ]]; then
    header "Next step"
    info "  Recommended: create an API key in Panel -> API Keys, then:"
    info "     warp-manager backup
  warp-manager key
  warp-manager apply --panel-key pg_key_... --yes
  warp-manager apply --panel-user admin --panel-pass 'secret' --yes"
    info "     (It fixes outbound/rule order automatically; URL is auto-detected.)"
    info "  Without an API key: warp-manager snippets, paste into Core Settings,"
    info "     Save, then warp-manager mark-applied --yes"
    line
  fi
  if (( problems == 0 )); then
    ok "Overall health: OK"
  else
    warn "Overall health: ${problems} item(s) need attention."
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
  if [[ "$(state_get INSTALLED 0)" == "1" && "$(state_get PANEL_LAST_APPLY never)" == "never" ]]; then
    printf '  %-18s %s\n' "Status" "installed, NOT ACTIVE - run 'warp-manager snippets'"
  fi
  printf '%s\n' "------------------------------------------------------------------------"
}

cmd_menu() {
  state_init
  while true; do
    print_banner
    local c
    c="$(choose "Main menu - select an option:" \
        "Install / Repair WARP" \
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
  install     Install / configure WARP, or REPAIR an existing setup (option 1)
  repair      Repair the dedicated WARP link on THIS server (no reinstall)
  warp-check  Verify the whole two-server WARP path without changing anything
  remove      Remove / uninstall WARP
  update      Update this script
  logs        View logs
  status      Status / health check
  menu        Open the interactive menu
  apply       Push generated snippets into the panel API (no reinstall)
  unapply     Remove WARP outbound/rules from the panel API
  fix-compose Re-detect and patch the NODE compose service for TUN access
  snippets    Print the JSON to paste into Core Settings (no API needed)
  mark-applied  Mark a manual Core Settings paste as done
  backup      Full backup: panel/node files, database, compose, core configs
  restore DIR Restore files from a full backup (DB steps in RESTORE.md)
  key         Create/reuse the dedicated Panel API key
  export-profile  Print the WARP profile as one WARP1: line (private!)
  import-profile 'WARP1:...'  Reuse an existing WARP account, no Cloudflare call
  warp-link       (FOREIGN server) create a dedicated WARP link; prints WARPLINK1:
  warp-link --show  (FOREIGN server) print the saved WARPLINK1 line again
  warp-inbound 'WARPLINK1:...'  (MAIN PANEL) clone a real inbound as WARP-only
  warp-unlink   (MAIN PANEL server) remove it and restore the original rules
  warp-join 'WARPLINK1:...'  Alias for warp-inbound (kept for compatibility)
  help        Show this help

Server selection: THIS SCRIPT MUST BE INSTALLED AND RUN ON BOTH SERVERS.
  * FOREIGN relay server: warp-link --yes creates the WARP-LINK inbound, the
    userspace WARP outbound and its routing rule. WARP terminates here.
  * IRAN MAIN PANEL server: warp-inbound clones a real VLESS inbound as
    WARP-DEDICATED; only that config uses WARP. No local WARP outbound there.
  Deleting the WARP inbound/outbound/rule on the FOREIGN server cuts the WARP
  config on Iran. Do NOT test by deleting: run 'warp-manager warp-check' and
  'warp-manager repair --yes' on BOTH servers instead.
  Full per-server commands: docs/TWO-SERVERS.md and docs/ARCHITECTURE.md 2.1.

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
  --modern-xray             Use userspace WireGuard (default; safe inside Docker)
  --legacy-xray            Use legacy kernelMode/DNS fields (old Xray only)
  --all-traffic            Allow WARP on a shared egress core (NOT recommended)

Panel API options (optional):
  --panel-url URL           Panel base URL, e.g. https://panel.example.com
  --panel-user USER         Admin username
  --panel-pass PASS         Admin password
  --panel-key KEY           Panel API key (pg_key_...); preferred, no login needed
  --auto-key                Create/reuse the dedicated API key automatically
  --backup-label NAME       Label for a 'backup' run
  --from DIR                Backup directory for 'restore' (or pass it directly)
  --uninstall-manager       With 'remove': also remove the warp-manager command
  --panel-token TOKEN       Bearer token instead of username/password
  --core-id ID              Core configuration ID to modify
  --apply-panel             Force API apply
  --no-apply-panel          Never call the API, only write snippets

Other options:
  --yes, -y                 Answer all confirmations with yes
  --dry-run                 Print the plan and exit without changes
  --force                   Allow reinstall / forced update
  --insecure                Skip TLS verification (downloads and panel API)
  --allow-local-panel    Permit using a panel container on this host when
                         the configured panel URL is unreachable
  --branch BRANCH           Git branch used by 'update'
  --url URL                 Direct script URL used by 'update'
  --check                   With 'update': only check for a new version
  --show                    With 'warp-link': print the saved link, change nothing
  --lines N                 With 'logs': number of lines (default 80)
  --follow                  With 'logs': follow output
  --version, -V             Print version
  --help, -h                Print help

Environment variables:
  WARP_APP_DIR, WARP_BRANCH, WARP_UPDATE_URL, WARP_MODE, WARP_TARGET,
  WARP_PANEL_CONTAINER, WARP_PANEL_TRANSPORT (docker-exec / nsenter / direct),
  WARP_PANEL_EXEC_UDS, WARP_PANEL_EXEC_SCHEME, WARP_PANEL_EXEC_PORT,
  WARP_LINK_HOST        Override the IP published by warp-link
  WARP_BINDING, WARP_SRC_IP, WARP_LABEL, WARP_LABELS, WARP_ENDPOINT, WARP_ROUTING,
  WARP_DOMAINS, WARP_LICENSE_KEY, WARP_APPLY_PANEL, WGCF_VERSION,
  WARP_YES, WARP_DRY_RUN, WARP_FORCE, WARP_INSECURE, WARP_DEBUG,
  PANEL_URL, PANEL_USER, PANEL_PASS, PANEL_TOKEN, PANEL_API_KEY, PANEL_CORE_ID

Examples:
  warp-manager
  warp-manager install --mode xray --target exit --binding per-ip --yes
  warp-manager install --mode kernel --target exit --ip 203.0.113.10
  warp-manager status
  warp-manager update --check
  warp-manager apply --panel-key pg_key_... --yes
  warp-manager apply --panel-url https://panel.example.com \
    --panel-user admin --panel-pass 'secret' --core-id 1 --yes
EOF
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      install|remove|update|logs|status|menu|help|apply|unapply|fix-compose|snippets|mark-applied|backup|restore|key|export-profile|import-profile|warp-link|warp-join|warp-inbound|warp-unlink|repair|warp-check) COMMAND="$1"; shift ;;
      WARP1:*) PROFILE_BLOB="${1#WARP1:}"; shift ;;
      WARPLINK1:*) WARP_LINK_BLOB="${1#WARPLINK1:}"; shift ;;
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
      --legacy-xray) MODERN_XRAY=0; shift ;;
      --all-traffic) ALL_TRAFFIC=1; shift ;;
      --panel-url) PANEL_URL="$2"; shift 2 ;;
      --panel-user) PANEL_USER="$2"; shift 2 ;;
      --panel-pass) PANEL_PASS="$2"; shift 2 ;;
      --panel-token) PANEL_TOKEN="$2"; shift 2 ;;
      --panel-key) PANEL_API_KEY="$2"; shift 2 ;;
      --backup-label) BACKUP_LABEL="$2"; shift 2 ;;
      --auto-key) AUTO_KEY=1; shift ;;
      --restore-db) RESTORE_DB=1; shift ;;
      --uninstall-manager) UNINSTALL_MANAGER=1; shift ;;
      --from) RESTORE_PATH="$2"; shift 2 ;;
      --core-id) PANEL_CORE_ID="$2"; shift 2 ;;
      --show) WARP_LINK_SHOW=1; shift ;;
      --apply-panel) APPLY_PANEL="yes"; shift ;;
      --no-apply-panel) APPLY_PANEL="no"; shift ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --force) FORCE=1; shift ;;
      --insecure) INSECURE=1; shift ;;
      --allow-local-panel) ALLOW_LOCAL_PANEL=1; shift ;;
      --branch) REPO_BRANCH="$2"; shift 2 ;;
      --url) UPDATE_URL="$2"; shift 2 ;;
      --check) UPDATE_CHECK_ONLY=1; shift ;;
      --lines) LOG_LINES="$2"; shift 2 ;;
      --follow) LOG_FOLLOW=1; shift ;;
      --version|-V) printf '%s %s\n' "$APP_NAME" "$SCRIPT_VERSION"; exit 0 ;;
      --help|-h|help) usage; exit 0 ;;
      /*|./*|../*) RESTORE_PATH="$1"; shift ;;
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
  # A handled failure (e.g. an automatic rollback) already printed its own
  # clear message; do not add the scary generic "Unexpected failure" line.
  if [[ "${HANDLED_ERROR:-0}" == "1" ]]; then return 0; fi
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
    fix-compose) require_root; cmd_fix_compose ;;
    snippets)  cmd_snippets ;;
    mark-applied) require_root; cmd_mark_applied ;;
    backup)    require_root; cmd_backup ;;
    restore)   require_root; cmd_restore "${RESTORE_PATH:-}" ;;
    key)       require_root; cmd_key ;;
    export-profile) require_root; cmd_export_profile ;;
    import-profile) require_root; cmd_import_profile "$PROFILE_BLOB" ;;
    warp-link) require_root; cmd_warp_link ;;
    warp-join) require_root; cmd_warp_join "$WARP_LINK_BLOB" ;;
    warp-inbound) require_root; cmd_warp_inbound "$WARP_LINK_BLOB" ;;
    warp-unlink) require_root; cmd_warp_unlink ;;
    repair) require_root; cmd_repair ;;
    warp-check) require_root; cmd_warp_check ;;
    help)      usage ;;
    *)         die "Unknown command: ${COMMAND}" ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
