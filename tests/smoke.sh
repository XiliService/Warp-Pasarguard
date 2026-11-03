#!/usr/bin/env bash
# =============================================================================
# PasarGuard WARP Manager - offline smoke tests
# -----------------------------------------------------------------------------
# No network, no root and no real server changes. Run with: bash tests/smoke.sh
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

PASS=0
FAIL=0

# Names are prefixed because sourcing warp-manager.sh later in this file
# defines its own ok()/fail() helpers, which used to shadow these counters.
t_ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
t_fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then t_ok "$label"; else t_fail "$label"; fi
}
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then t_ok "$label"; else
    t_fail "$label (expected '${expected}', got '${actual}')"
  fi
}

printf '\n%s\n' "PasarGuard WARP Manager - smoke tests"
printf '%s\n' "========================================================================"

# ---------------------------------------------------------------------------
printf '\n[1] Shell syntax\n'
for f in "$ROOT"/*.sh "$ROOT"/tests/*.sh; do
  [[ -f "$f" ]] || continue
  check "bash -n $(basename "$f")" bash -n "$f"
done

# ---------------------------------------------------------------------------
printf '\n[2] CLI surface\n'
check "--version prints a version" bash -c "bash '$ROOT/warp-manager.sh' --version | grep -qE '1\\.0\\.[0-9]+'"
check "--help documents the five menu commands" bash -c "bash '$ROOT/warp-manager.sh' --help | grep -q 'Status / health check'"
check "install.sh --help works" bash -c "bash '$ROOT/install.sh' --help | grep -q 'bootstrap installer'"
check "status runs without root" bash -c "WARP_APP_DIR='$WORK/ro-app' bash '$ROOT/warp-manager.sh' status 2>&1 | grep -q 'Overall health'"

# Fake root for the paths that call require_root (id -u -> 0).
mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\necho 0\n' >"$WORK/bin/id"
chmod +x "$WORK/bin/id"
export PATH="$WORK/bin:$PATH"

check "--help documents the apply command" \
  bash -c "bash '$ROOT/warp-manager.sh' --help | grep -q 'apply       Push generated snippets'"
check "--help documents the fix-compose command" \
  bash -c "bash '$ROOT/warp-manager.sh' --help | grep -q 'fix-compose Re-detect'"
apply_err="$(WARP_APP_DIR="$WORK/apply-app" bash "$ROOT/warp-manager.sh" apply --yes 2>&1 || true)"
if printf '%s' "$apply_err" | grep -q "Run 'warp-manager key'"; then
  t_ok "apply without a panel URL fails with a clear message"
else
  t_fail "apply without a panel URL fails with a clear message"
fi


# ---------------------------------------------------------------------------
printf '\n[3] Bootstrap installer (offline)\n'
(
  export WARP_APP_DIR="$WORK/bootstrap-app" WARP_BIN_LINK="$WORK/bootstrap-bin/warp-manager"
  bash "$ROOT/install.sh" --local "$ROOT/warp-manager.sh" --no-menu >/dev/null
)
check "manager file installed" test -f "$WORK/bootstrap-app/warp-manager.sh"
check "command symlink created" test -L "$WORK/bootstrap-bin/warp-manager"
check "installed copy is executable" test -x "$WORK/bootstrap-app/warp-manager.sh"

# ---------------------------------------------------------------------------
printf '\n[3b] Piped installer (curl | bash -s, BASH_SOURCE is unset)\n'
(
  export WARP_APP_DIR="$WORK/pipe-app" WARP_BIN_LINK="$WORK/pipe-bin/warp-manager"
  cat "$ROOT/install.sh" | bash -s -- --branch arena/01417195-warp-pasarguard \
    --url "file://$ROOT/warp-manager.sh" --no-menu >"$WORK/pipe.log" 2>&1
)
check "piped installer exits without BASH_SOURCE errors" \
  bash -c "! grep -q 'unbound variable' '$WORK/pipe.log'"
check "piped installer installs the manager" test -f "$WORK/pipe-app/warp-manager.sh"
check "piped installer creates the symlink" test -L "$WORK/pipe-bin/warp-manager"
check "piped installer reports Done" grep -q 'Done' "$WORK/pipe.log"
pipe_ver="$(cat "$ROOT/warp-manager.sh" | bash -s -- --version 2>&1)"
if printf '%s' "$pipe_ver" | grep -q 'PasarGuard WARP Manager'; then
  t_ok "manager itself runs from stdin"
else
  t_fail "manager itself runs from stdin"
fi

# ---------------------------------------------------------------------------
printf '\n[4] Interactive menu (piped input)\n'
menu_out="$(printf '6\n' | WARP_APP_DIR="$WORK/menu-app" bash "$ROOT/warp-manager.sh" menu 2>&1 || true)"
check "menu lists Install option" bash -c "printf '%s' \"\$1\" | grep -q 'Install / Configure WARP'" _ "$menu_out"
check "menu lists Update Script option" bash -c "printf '%s' \"\$1\" | grep -q 'Update Script'" _ "$menu_out"
check "menu exits cleanly on option 6" bash -c "printf '%s' \"\$1\" | grep -q 'Goodbye'" _ "$menu_out"

# ---------------------------------------------------------------------------
printf '\n[5] Dry-run install plan\n'
plan_out="$(WARP_APP_DIR="$WORK/plan-app" bash "$ROOT/warp-manager.sh" install \
  --mode xray --target exit --binding single --routing domains --yes --dry-run 2>&1 || true)"
check "plan shows the deployment target guidance" bash -c "printf '%s' \"\$1\" | grep -q 'EXIT NODE'" _ "$plan_out"
check "plan shows the selected backend" bash -c "printf '%s' \"\$1\" | grep -q 'xray'" _ "$plan_out"
check "dry-run makes no changes" bash -c "printf '%s' \"\$1\" | grep -q 'No changes were made'" _ "$plan_out"
check "dry-run created no wgcf binary" test ! -e "$WORK/plan-app/bin/wgcf"

# ---------------------------------------------------------------------------
printf '\n[5a] Routing scope controls outbound position\n'
cat >"$WORK/prepend.sh" <<'EOF'
source "$WARP_MANAGER"
ASSUME_YES=0
choose_routing >/dev/null 2>&1
printf '%s|%s' "$ROUTING" "$RULE_PREPEND"
EOF
d_out="$(printf '1\n\n' | WARP_APP_DIR="$WORK/prepend-a" \
  WARP_MANAGER="$ROOT/warp-manager.sh" bash "$WORK/prepend.sh" 2>/dev/null || true)"
a_out="$(printf '2\n' | WARP_APP_DIR="$WORK/prepend-b" \
  WARP_MANAGER="$ROOT/warp-manager.sh" bash "$WORK/prepend.sh" 2>/dev/null || true)"
assert_eq "domains mode keeps the existing default outbound" "domains|0" "$d_out"
assert_eq "all mode places WARP first" "all|1" "$a_out"

# ---------------------------------------------------------------------------
printf '\n[5b] Full interactive wizard with empty optional answers\n'
cat >"$WORK/wizard.sh" <<'EOF'
source "$WARP_MANAGER"
DETECTED_IPS=("203.0.113.10" "203.0.113.11" "203.0.113.12")
DETECTED_IFACES=("eth0" "eth0" "eth0")
DETECTED_ROLE="node"
ASSUME_YES=0
BINDING_PRESET=0
choose_target >/dev/null 2>&1
choose_mode >/dev/null 2>&1
choose_binding >/dev/null 2>&1
choose_routing >/dev/null 2>&1
choose_optional >/dev/null 2>&1
install_plan >/dev/null 2>&1
printf 'WIZARD_OK target=%s mode=%s binding=%s routing=%s' \
  "$TARGET" "$MODE" "$BINDING" "$ROUTING"
EOF
wizard_out="$(printf '1\n1\n1\n1\n\n\n\n\n\n\n\n\n' \
  | WARP_APP_DIR="$WORK/wizard-app" WARP_MANAGER="$ROOT/warp-manager.sh" \
    bash "$WORK/wizard.sh" 2>/dev/null || true)"
check "wizard survives empty Enter answers (set -e regression)" \
  bash -c "printf '%s' "\$1" | grep -q 'WIZARD_OK'" _ "$wizard_out"
assert_eq "wizard keeps the documented defaults" \
  "WIZARD_OK target=exit mode=xray binding=single routing=domains" "$wizard_out"

# Role detection should trust running containers, not merely leftover folders.
mkdir -p "$WORK/fakebin"
cat >"$WORK/fakebin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "ps" && "${2:-}" == "--format" ]]; then
  case "$3" in
    *Image*) printf 'pasarguard/node:latest\n' ;;
    *Names*) printf 'pg-node\n' ;;
  esac
  exit 0
fi
if [[ "${1:-}" == "exec" ]]; then printf 'Xray 25.9.11\n'; exit 0; fi
exit 0
EOF
chmod +x "$WORK/fakebin/docker"
role_out="$(WARP_APP_DIR="$WORK/role-app" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin:$PATH" bash -c '
    source "$WARP_MANAGER"
    detect_role
    printf "%s" "$DETECTED_ROLE"' 2>/dev/null || true)"
assert_eq "detect_role identifies a node container" "node" "$role_out"
xray_out="$(WARP_APP_DIR="$WORK/role-app2" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin:$PATH" bash -c '
    source "$WARP_MANAGER"
    detect_xray_version
    printf "%s" "$XRAY_VERSION"' 2>/dev/null || true)"
assert_eq "detect_xray_version discovers any container name" "25.9.11" "$xray_out"

# ---------------------------------------------------------------------------
printf '\n[6] Function-level tests (sourced, no main)\n'
export WARP_APP_DIR="$WORK/unit-app"
# shellcheck disable=SC1090
source "$ROOT/warp-manager.sh"

state_init
state_set FOO "bar baz with spaces"
assert_eq "state round-trip" "bar baz with spaces" "$(state_get FOO)"
state_set SECRET "a+/=b\$c"
assert_eq "state round-trip with shell metacharacters" 'a+/=b$c' "$(state_get SECRET)"

profile_meta_set demo PRIVATE_KEY 'AA+/=bb'
assert_eq "profile meta round-trip" 'AA+/=bb' "$(profile_meta demo PRIVATE_KEY)"
assert_eq "safe_name sanitises labels" "nl-de-pl" "$(safe_name 'NL DE/PL')"

PERIP_IPS=("203.0.113.10" "203.0.113.11" "203.0.113.12")
PERIP_LABELS_CSV="nl,de,pl"
normalize_perip
assert_eq "normalize_perip labels" "nl de pl" "${PERIP_LABELS[*]}"
assert_eq "normalize_perip keeps IP count" "3" "${#PERIP_LABELS[@]}"

# Fake wgcf profiles so no network access is needed.
mkprofile() {
  local n="$1" ip="$2" tag="$3"
  mkdir -p "$PROFILE_DIR/$n"
  profile_meta_set "$n" PRIVATE_KEY "PRIVATE-KEY-${n}"
  profile_meta_set "$n" ADDRESS4 "172.16.0.2/32"
  profile_meta_set "$n" ADDRESS6 "2606:4700:110::${n}/128"
  profile_meta_set "$n" PUBLIC_KEY "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
  profile_meta_set "$n" MTU "1280"
  profile_meta_set "$n" ENDPOINT "$DEFAULT_ENDPOINT"
  profile_meta_set "$n" SRC_IP "$ip"
  profile_meta_set "$n" TAG "$tag"
  profile_meta_set "$n" INTERFACE "$tag"
}
mkprofile nl 203.0.113.10 warp-nl
mkprofile de 203.0.113.11 warp-de
mkprofile pl 203.0.113.12 warp-pl

BINDING="per-ip"; MODE="xray"; ROUTING="domains"; DOMAINS_CSV="$DEFAULT_DOMAINS"
build_snippets nl de pl >/dev/null 2>&1
check "per-ip outbounds.json is valid JSON" jq -e 'length == 3' "$OUTPUT_DIR/outbounds.json"
assert_eq "per-ip outbound protocol" "wireguard" "$(jq -r '.[0].protocol' "$OUTPUT_DIR/outbounds.json")"
assert_eq "per-ip sendThrough binding" "203.0.113.10" "$(jq -r '.[0].sendThrough' "$OUTPUT_DIR/outbounds.json")"
assert_eq "per-ip routing uses the balancer" "warp-pool" "$(jq -r '.[0].balancerTag' "$OUTPUT_DIR/routing-rules.json")"
check "balancer selects all three outbounds" jq -e '.[0].selector | length == 3' "$OUTPUT_DIR/balancers.json"
check "generated README is in English" grep -q 'PasarGuard WARP Manager' "$OUTPUT_DIR/README.txt"

BINDING="single"; MODE="kernel"; ROUTING="all"
build_snippets nl >/dev/null 2>&1
assert_eq "kernel outbound protocol" "freedom" "$(jq -r '.[0].protocol' "$OUTPUT_DIR/outbounds.json")"
assert_eq "kernel outbound interface" "warp-nl" "$(jq -r '.[0].streamSettings.sockopt.interface' "$OUTPUT_DIR/outbounds.json")"
assert_eq "routing=all emits no rules" "0" "$(jq -r 'length' "$OUTPUT_DIR/routing-rules.json")"

BINDING="per-ip"; MODE="kernel"; ROUTING="domains"
build_wg_conf nl >"$WORK/warp-nl.conf"
check "kernel config contains Table = off" grep -q '^Table = off' "$WORK/warp-nl.conf"
check "kernel config contains the private key" grep -q '^PrivateKey = PRIVATE-KEY-nl' "$WORK/warp-nl.conf"
check "kernel config contains PersistentKeepalive" grep -q '^PersistentKeepalive = 25' "$WORK/warp-nl.conf"
check "kernel config omits DNS to protect resolv.conf" bash -c "! grep -q '^DNS =' '$WORK/warp-nl.conf'"

# ---------------------------------------------------------------------------
printf '\n[6a] Binding wizard option 2 asks for a source IP\n'
cat >"$WORK/binding.sh" <<'EOF'
source "$WARP_MANAGER"
DETECTED_IPS=("203.0.113.10" "203.0.113.11")
DETECTED_IFACES=("eth0" "eth0")
ASSUME_YES=0
BINDING_PRESET=0
BINDING="single"
choose_binding >/dev/null 2>&1
printf '%s|%s' "$BINDING" "$SRC_IP"
EOF
binding_out="$(printf '2\n1\n' | WARP_APP_DIR="$WORK/binding-app" \
  WARP_MANAGER="$ROOT/warp-manager.sh" bash "$WORK/binding.sh" 2>/dev/null || true)"
assert_eq "option 2 records the chosen source IP" "single|203.0.113.10" "$binding_out"

# ---------------------------------------------------------------------------
printf '\n[6b] Full profile creation with a mocked wgcf binary\n'
mkdir -p "$BIN_DIR"
cat >"$WGCF_BIN" <<'MOCK'
#!/usr/bin/env bash
set -e
case "${1:-}" in
  --help) echo "wgcf mock"; exit 0 ;;
  register)
    printf 'private_key = "MOCKKEY"\ndevice_id = "mock"\naccess_token = "mock"\nlicense_key = ""\n' >wgcf-account.toml
    exit 0 ;;
  update)
    [[ "${2:-}" == "--help" ]] && { echo "Usage: wgcf update [flags]"; exit 0; }
    exit 0 ;;
  generate)
    out="wgcf-profile.conf"
    [[ "${2:-}" == "--profile" && -n "${3:-}" ]] && out="$3"
    cat >"$out" <<'CONF'
[Interface]
PrivateKey = MOCKPRIVATEKEYBASE64=
Address = 172.16.0.2/32
Address = 2606:4700:110::1/128
DNS = 1.1.1.1
MTU = 1280
[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0
AllowedIPs = ::/0
Endpoint = engage.cloudflareclient.com:2408
CONF
    exit 0 ;;
  *) echo "unknown wgcf command" >&2; exit 1 ;;
esac
MOCK
chmod +x "$WGCF_BIN"
BINDING="single"; MODE="xray"
create_profile mockprof 203.0.113.20 "$DEFAULT_ENDPOINT" "LIC-KEY-123" >/dev/null 2>&1
assert_eq "profile private key parsed" "MOCKPRIVATEKEYBASE64=" "$(profile_meta mockprof PRIVATE_KEY)"
assert_eq "profile IPv6 address parsed" "2606:4700:110::1/128" "$(profile_meta mockprof ADDRESS6)"
assert_eq "profile tag for a single binding" "warp" "$(profile_meta mockprof TAG)"
check "older wgcf license_key path patches the account file" \
  grep -q '^license_key = "LIC-KEY-123"' "$PROFILE_DIR/mockprof/wgcf-account.toml"
build_outbound_json mockprof >"$WORK/mock-outbound.json"
check "generated outbound contains the secret key" \
  jq -e '.settings.secretKey == "MOCKPRIVATEKEYBASE64="' "$WORK/mock-outbound.json"
rm -f -- "$WGCF_BIN"

# ---------------------------------------------------------------------------
printf '\n[7] Core config merge is idempotent and reversible\n'
cat >"$WORK/core.json" <<'JSON'
{
  "id": 1,
  "name": "foreign-node",
  "config": {
    "outbounds": [{"tag": "direct", "protocol": "freedom"}],
    "routing": {"rules": [{"type": "field", "outboundTag": "direct", "domain": []}]}
  },
  "type": "xray",
  "exclude_inbound_tags": [],
  "fallbacks_inbound_tags": []
}
JSON
MODE="xray"; ROUTING="domains"; RULE_PREPEND=1
build_snippets nl >/dev/null 2>&1
merge_core_config "$WORK/core.json" "$WORK/merged1.json" apply
merge_core_config "$WORK/core.json" "$WORK/merged2.json" apply
assert_eq "apply inserts one WARP outbound" "1" "$(jq '[.outbounds[] | select(.tag | test("^warp"))] | length' "$WORK/merged1.json")"
assert_eq "existing direct outbound is preserved" "1" "$(jq '[.outbounds[] | select(.tag == "direct")] | length' "$WORK/merged1.json")"
assert_eq "apply twice is idempotent" "2" "$(jq '.outbounds | length' "$WORK/merged2.json")"
jq -n --slurpfile cfg "$WORK/merged1.json" \
  '{ id: 1, name: "foreign-node", config: $cfg[0], type: "xray",
     exclude_inbound_tags: [], fallbacks_inbound_tags: [] }' >"$WORK/core-applied.json"
merge_core_config "$WORK/core-applied.json" "$WORK/stripped.json" remove
assert_eq "remove deletes WARP outbounds" "0" "$(jq '[.outbounds[] | select(.tag | test("^warp"))] | length' "$WORK/stripped.json")"
assert_eq "remove keeps existing outbounds" "1" "$(jq '.outbounds | length' "$WORK/stripped.json")"
assert_eq "remove deletes WARP routing rule" "1" "$(jq '.routing.rules | length' "$WORK/stripped.json")"

# ---------------------------------------------------------------------------
printf '\n[8] Docker compose patch / restore\n'
mkdir -p "$WORK/compose"
cat >"$WORK/compose/docker-compose.yml" <<'YAML'
services:
  node:
    image: pasarguard/node:latest
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      SERVICE_PORT: 62050
    volumes:
      - /var/lib/pg-node:/var/lib/pg-node
YAML
cp "$WORK/compose/docker-compose.yml" "$WORK/compose-original.yml"
export PG_COMPOSE_DIR="$WORK/compose" ASSUME_YES=1
patch_compose >/dev/null 2>&1
check "compose gains /dev/net/tun" grep -q '/dev/net/tun:/dev/net/tun' "$WORK/compose/docker-compose.yml"
check "compose gains seccomp=unconfined" grep -q 'seccomp=unconfined' "$WORK/compose/docker-compose.yml"
check "compose backup exists" bash -c "ls '$BACKUP_DIR'/docker-compose.yml.*.bak >/dev/null 2>&1"
check "compose syntax still parses" bash -c "python3 -c 'import re,sys; lines=open(sys.argv[1]).read().splitlines(); assert any(l.startswith(\"services:\") for l in lines)' '$WORK/compose/docker-compose.yml'"
restore_compose >/dev/null 2>&1
check "compose can be restored from backup" cmp -s "$WORK/compose/docker-compose.yml" "$WORK/compose-original.yml"

# ---------------------------------------------------------------------------
printf '\n[8b] Compose file discovery via Docker labels\n'
mkdir -p "$WORK/fakebin2" "$WORK/compose2"
cat >"$WORK/compose2/docker-compose.yml" <<'YAML'
services:
  node:
    image: pasarguard/node:latest
    network_mode: host
    cap_add:
      - NET_ADMIN
YAML
cat >"$WORK/fakebin2/docker" <<EOF
#!/usr/bin/env bash
CFG="$WORK/compose2/docker-compose.yml"
case "\${1:-}" in
  ps) printf 'pasarguard-pasarguard-1\npg-node\n'; exit 0 ;;
  inspect)
    name="\$2"; fmt="\$4"
    case "\$fmt" in
      *config_files*) printf '%s\n' "\$CFG" ;;
      *com.docker.compose.service*) printf 'node\n' ;;
      *Config.Image*)
        if [[ "\$name" == *node* ]]; then printf 'pasarguard/node:latest\n'
        else printf 'pasarguard/panel:latest\n'; fi ;;
    esac
    exit 0 ;;
  compose) exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/fakebin2/docker"
compose_out="$(WARP_APP_DIR="$WORK/compose-app" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin2:$PATH" bash -c '
    source "$WARP_MANAGER"
    detect_compose
    printf "%s|%s|%s" "$COMPOSE_FILE" "$COMPOSE_CONTAINER" "$COMPOSE_SERVICE_HINT"' 2>/dev/null || true)"
assert_eq "detect_compose prefers the node container" \
  "$WORK/compose2/docker-compose.yml|pg-node|node" "$compose_out"
WARP_APP_DIR="$WORK/compose-app2" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin2:$PATH" ASSUME_YES=1 bash -c '
    source "$WARP_MANAGER"
    detect_compose
    patch_compose >/dev/null 2>&1' || true
check "patch_compose auto-selects the node service without a prompt" \
  grep -q '/dev/net/tun:/dev/net/tun' "$WORK/compose2/docker-compose.yml"

# ---------------------------------------------------------------------------
printf '\n[8c] Every node container is patched (out-node + main-node)\n'
mkdir -p "$WORK/fakebin3" "$WORK/nodeA" "$WORK/nodeB"
for d in nodeA nodeB; do
  cat >"$WORK/$d/docker-compose.yml" <<'YAML'
services:
  node:
    image: pasarguard/node:latest
    network_mode: host
    cap_add:
      - NET_ADMIN
YAML
done
cat >"$WORK/fakebin3/docker" <<EOF
#!/usr/bin/env bash
A="$WORK/nodeA/docker-compose.yml"
B="$WORK/nodeB/docker-compose.yml"
case "\${1:-}" in
  ps) printf 'pasarguard-pasarguard-1\nout-node\nmain-node\n'; exit 0 ;;
  inspect)
    name="\$2"; fmt="\$4"
    case "\$fmt" in
      *config_files*)
        if [[ "\$name" == "out-node" ]]; then printf '%s\n' "\$A"
        elif [[ "\$name" == "main-node" ]]; then printf '%s\n' "\$B"
        else printf '%s\n' "\$A"; fi ;;
      *com.docker.compose.service*) printf 'node\n' ;;
      *Config.Image*)
        if [[ "\$name" == *node* ]]; then printf 'pasarguard/node:latest\n'
        else printf 'pasarguard/panel:latest\n'; fi ;;
    esac
    exit 0 ;;
  compose) exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/fakebin3/docker"
WARP_APP_DIR="$WORK/multinode-app" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin3:$PATH" ASSUME_YES=1 bash -c '
    source "$WARP_MANAGER"
    node_compose_targets > "'"$WORK"'/targets.txt"
    patch_node_composes >/dev/null 2>&1' || true
assert_eq "node_compose_targets finds two distinct node compose files" "2" \
  "$(wc -l < "$WORK/targets.txt" | tr -d ' ')"
check "out-node compose file was patched" \
  grep -q '/dev/net/tun:/dev/net/tun' "$WORK/nodeA/docker-compose.yml"
check "main-node compose file was patched too" \
  grep -q '/dev/net/tun:/dev/net/tun' "$WORK/nodeB/docker-compose.yml"
second_patch="$(WARP_APP_DIR="$WORK/multinode-app2" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin3:$PATH" ASSUME_YES=1 bash -c '
    source "$WARP_MANAGER"
    COMPOSE_FILE="'"$WORK"'/nodeA/docker-compose.yml"
    COMPOSE_SERVICE_HINT="node"; COMPOSE_CONTAINER="out-node"
    patch_compose 2>&1' || true)"
check "re-running the compose patch does not restart containers" \
  bash -c '[[ "$1" == *"no change, no restart"* ]]' _ "$second_patch"

# ---------------------------------------------------------------------------
printf '\n[8d] Panel API reachability diagnostics and local fallback\n'
mkdir -p "$WORK/fakebin4"
cat >"$WORK/fakebin4/curl" <<'EOF'
#!/usr/bin/env bash
url="${@: -1}"
out=""; prev=""
for a in "$@"; do
  if [[ "$prev" == "-o" ]]; then out="$a"; fi
  prev="$a"
done
if [[ "$url" == *127.0.0.1* ]]; then
  printf '{"access_token":"LOCALTOKEN"}' >"$out"
  printf '200'
  exit 0
fi
echo "curl: (6) Could not resolve host: panel.example.com" >&2
exit 6
EOF
chmod +x "$WORK/fakebin4/curl"
cat >"$WORK/fakebin4/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  ps) printf 'pasarguard-pasarguard-1\n'; exit 0 ;;
  inspect)
    fmt="$4"
    case "$fmt" in
      *Config.Image*) printf 'pasarguard/panel:latest\n' ;;
      *NetworkSettings.Ports*) printf '{"8000/tcp":[{"HostIp":"0.0.0.0","HostPort":"8000"}]}\n' ;;
      *NetworkSettings.Networks*) printf '172.18.0.5 \n' ;;
      *) printf '\n' ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/fakebin4/docker"
check "--help documents --allow-local-panel" \
  bash -c "bash '$ROOT/warp-manager.sh' --help | grep -q -- '--allow-local-panel'"
neterr="$(WARP_APP_DIR="$WORK/panel-app" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin4:$PATH" bash -c '
    source "$WARP_MANAGER"
    PANEL_USER=u PANEL_PASS=p
    panel_try_login "https://panel.example.com" 0 || true
    printf "%s" "$PANEL_NETERR"' 2>/dev/null || true)"
check "panel_try_login surfaces the real curl network error" \
  bash -c '[[ "$1" == *"Could not resolve host"* ]]' _ "$neterr"
local_urls="$(WARP_APP_DIR="$WORK/panel-app2" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin4:$PATH" bash -c '
    source "$WARP_MANAGER"
    local_panel_urls' 2>/dev/null || true)"
check "local_panel_urls discovers the local panel port" \
  bash -c '[[ "$1" == *"http://127.0.0.1:8000"* ]]' _ "$local_urls"
login_out="$(WARP_APP_DIR="$WORK/panel-app3" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin4:$PATH" bash -c '
    source "$WARP_MANAGER"
    PANEL_URL="https://panel.example.com" PANEL_USER=u PANEL_PASS=p
    ALLOW_LOCAL_PANEL=1 INSECURE=1
    panel_login 2>&1
    printf "URL=%s TOKEN=%s\n" "$PANEL_URL" "$PANEL_ACCESS_TOKEN"' 2>/dev/null || true)"
check "panel_login falls back to the local panel when allowed" \
  bash -c '[[ "$1" == *"URL=http://127.0.0.1:8000 TOKEN=LOCALTOKEN"* ]]' _ "$login_out"
login_out2="$(WARP_APP_DIR="$WORK/panel-app4" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin4:$PATH" bash -c '
    source "$WARP_MANAGER"
    PANEL_URL="https://panel.example.com" PANEL_USER=u PANEL_PASS=p
    INSECURE=1
    panel_login 2>&1 || true' 2>/dev/null || true)"
check "panel_login does NOT switch panels without the flag" \
  bash -c '[[ "$1" == *"Skipping local panel"* && "$1" == *"Panel login failed"* ]]' _ "$login_out2"

# ---------------------------------------------------------------------------
printf '\n[8e] Manual-paste path (no API needed)\n'
check "--help documents snippets" \
  bash -c "bash '$ROOT/warp-manager.sh' --help | grep -q 'snippets    Print the JSON'"
check "--help documents mark-applied" \
  bash -c "bash '$ROOT/warp-manager.sh' --help | grep -q 'mark-applied  Mark a manual'"
mkdir -p "$WORK/snip-app/outbound"
printf '[{"tag":"warp","protocol":"wireguard"}]\n' > "$WORK/snip-app/outbound/outbounds.json"
printf '[{"type":"field","outboundTag":"warp"}]\n' > "$WORK/snip-app/outbound/routing-rules.json"
printf '[]\n' > "$WORK/snip-app/outbound/balancers.json"
printf 'README\n' > "$WORK/snip-app/outbound/README.txt"
snip_out="$(WARP_APP_DIR="$WORK/snip-app" bash "$ROOT/warp-manager.sh" snippets 2>&1 || true)"
check "snippets prints the outbounds JSON verbatim" \
  bash -c '[[ "$1" == *'"'"'"tag":"warp"'"'"'* ]]' _ "$snip_out"
check "snippets tells the user to run mark-applied" \
  bash -c '[[ "$1" == *"warp-manager mark-applied --yes"* ]]' _ "$snip_out"
printf 'INSTALLED=1\nMODE=xray\nROUTING=domains\nPROFILES=default\n' > "$WORK/snip-app/state.env"
WARP_APP_DIR="$WORK/snip-app" PATH="$WORK/bin:$PATH" \
  bash "$ROOT/warp-manager.sh" mark-applied --yes >/dev/null 2>&1 || true
check "mark-applied records the manual apply" \
  grep -q 'PANEL_APPLY_METHOD=manual' "$WORK/snip-app/state.env"
stat_out="$(WARP_APP_DIR="$WORK/snip-app" bash "$ROOT/warp-manager.sh" status 2>&1 || true)"
check "status shows the config as applied (manual)" \
  bash -c '[[ "$1" == *"Panel config applied (manual)"* ]]' _ "$stat_out"

# ---------------------------------------------------------------------------
printf '\n[8f] Real-world core order (DIRECT / Out-DE / Out-NL / Out-PL / warp / BLOCK)\n'
mkdir -p "$WORK/order-app/outbound"
cat >"$WORK/order-app/core.json" <<'JSON'
{"name":"foreign","type":"xray","exclude_inbound_tags":[],"fallbacks_inbound_tags":[],
 "config":{
  "outbounds":[
    {"tag":"DIRECT","protocol":"freedom"},
    {"tag":"Out-DE","protocol":"freedom","sendThrough":"147.90.59.188"},
    {"tag":"Out-NL","protocol":"freedom","sendThrough":"95.135.200.231"},
    {"tag":"Out-PL","protocol":"freedom","sendThrough":"91.124.209.148"},
    {"tag":"warp","protocol":"wireguard"},
    {"tag":"BLOCK","protocol":"blackhole"}],
  "routing":{"rules":[
    {"type":"field","outboundTag":"BLOCK","ip":["geoip:private"]},
    {"type":"field","inboundTag":["Germany"],"outboundTag":"Out-DE"},
    {"type":"field","inboundTag":["NetherLands"],"outboundTag":"Out-NL"},
    {"type":"field","inboundTag":["Poland"],"outboundTag":"Out-PL"},
    {"type":"field","inboundTag":["SOCKS5"],"outboundTag":"Out-PL"},
    {"type":"field","outboundTag":"warp","domain":["geosite:google","openai.com"]}]}}}
JSON
printf '[{"tag":"warp","protocol":"wireguard","settings":{"secretKey":"NEWKEY"}}]\n' \
  > "$WORK/order-app/outbound/outbounds.json"
printf '[{"type":"field","outboundTag":"warp","domain":["geosite:google","openai.com","ipinfo.io"]}]\n' \
  > "$WORK/order-app/outbound/routing-rules.json"
printf '[]\n' > "$WORK/order-app/outbound/balancers.json"
WARP_APP_DIR="$WORK/order-app" WARP_MANAGER="$ROOT/warp-manager.sh" \
  RULE_PREPEND=0 bash -c '
    source "$WARP_MANAGER"
    RULE_PREPEND=0
    merge_core_config "'"$WORK"'/order-app/core.json" "'"$WORK"'/order-app/merged.json" apply' || true
assert_eq "outbound order keeps DIRECT first and puts warp before BLOCK" \
  "DIRECT Out-DE Out-NL Out-PL warp BLOCK" \
  "$(jq -r '[.outbounds[].tag] | join(" ")' "$WORK/order-app/merged.json")"
assert_eq "WARP rule moves above the inbound catch-all rules, after the BLOCK rule" \
  "BLOCK warp Out-DE Out-NL" \
  "$(jq -r '[.routing.rules[0:4][].outboundTag] | join(" ")' "$WORK/order-app/merged.json")"
assert_eq "no duplicated warp outbound after re-apply" "1" \
  "$(jq -r '[.outbounds[] | select(.tag=="warp")] | length' "$WORK/order-app/merged.json")"
check "empty balancers array is removed" \
  bash -c "! jq -e '.routing.balancers' '$WORK/order-app/merged.json' >/dev/null 2>&1"

# ---------------------------------------------------------------------------
printf '\n[8g] Panel API key auth (X-Api-Key, no /api/admin/token)\n'
mkdir -p "$WORK/fakebin5"
cat >"$WORK/fakebin5/curl" <<'EOF'
#!/usr/bin/env bash
url="${@: -1}"
out=""; prev=""; has_key=0; has_jwt=0
for a in "$@"; do
  if [[ "$prev" == "-o" ]]; then out="$a"; fi
  if [[ "$a" == X-Api-Key:* ]]; then has_key=1; fi
  if [[ "$a" == "Authorization: Bearer JWT" ]]; then has_jwt=1; fi
  prev="$a"
done
if [[ "$url" == */api/admin/token ]]; then
  printf '{"access_token":"JWT"}' >"$out"; printf '200'; exit 0
fi
if [[ "$has_key" != "1" && "$has_jwt" != "1" ]]; then
  printf '{"detail":"unauthorized"}' >"$out"; printf '401'; exit 0
fi
if [[ "$url" == */api/cores ]]; then
  printf '{"count":1,"cores":[{"id":1,"name":"foreign","type":"xray"}]}' >"$out"
  printf '200'; exit 0
fi
if [[ "$url" == */api/api_keys* ]]; then
  printf '{"api_keys":[],"total":0}' >"$out"; printf '200'; exit 0
fi
if [[ "$url" == */api/api_key ]]; then
  printf '{"id":7,"name":"warp-manager","api_key":"pg_key_created_by_script"}' >"$out"
  printf '201'; exit 0
fi
printf '{}' >"$out"; printf '200'; exit 0
EOF
chmod +x "$WORK/fakebin5/curl"
cat >"$WORK/fakebin5/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  ps) printf 'pasarguard-pasarguard-1\n'; exit 0 ;;
  inspect) printf '\n'; exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/fakebin5/docker"
check "--help documents --panel-key" \
  bash -c "bash '$ROOT/warp-manager.sh' --help | grep -q -- '--panel-key KEY'"
probe_out="$(WARP_APP_DIR="$WORK/key-app" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin5:$PATH" bash -c '
    source "$WARP_MANAGER"
    PANEL_API_KEY="pg_key_00000000-0000-4000-8000-000000000000"
    if panel_probe_key "https://panel.example.com" 1; then printf "OK"; else printf "BAD:%s" "$PANEL_HTTP"; fi' 2>/dev/null || true)"
assert_eq "panel_probe_key accepts a real /api/cores response" "OK" "$probe_out"
login_key_out="$(WARP_APP_DIR="$WORK/key-app2" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin5:$PATH" bash -c '
    source "$WARP_MANAGER"
    PANEL_API_KEY="pg_key_00000000-0000-4000-8000-000000000000"
    PANEL_URL="https://panel.example.com" INSECURE=1
    panel_login >/dev/null 2>&1
    printf "%s|%s" "$PANEL_AUTH_MODE" "$PANEL_ACCESS_TOKEN"' 2>/dev/null || true)"
assert_eq "panel_login switches to api-key mode without a token request" \
  "api-key|pg_key_00000000-0000-4000-8000-000000000000" "$login_key_out"
api_hdr_out="$(WARP_APP_DIR="$WORK/key-app3" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin5:$PATH" bash -c '
    source "$WARP_MANAGER"
    PANEL_AUTH_MODE="api-key"
    PANEL_ACCESS_TOKEN="pg_key_00000000-0000-4000-8000-000000000000"
    PANEL_URL="https://panel.example.com"
    if panel_api GET /cores; then printf "%s" "$PANEL_API_BODY"; fi' 2>/dev/null || true)"
check "panel_api sends X-Api-Key and reads /api/cores" \
  bash -c '[[ "$1" == *"foreign"* ]]' _ "$api_hdr_out"
cat >"$WORK/key-wizard.sh" <<'EOF'
source "$WARP_MANAGER"
DETECTED_IPS=("203.0.113.10"); DETECTED_IFACES=("eth0"); DETECTED_ROLE="node"
ASSUME_YES=0; BINDING_PRESET=0
choose_target >/dev/null 2>&1
choose_mode >/dev/null 2>&1
choose_binding >/dev/null 2>&1
choose_routing >/dev/null 2>&1
choose_optional >/dev/null 2>&1
printf 'KEY=%s APPLY=%s URL=%s' "$PANEL_API_KEY" "$APPLY_PANEL" "$PANEL_URL"
EOF
key_wiz="$(printf '1\n1\n1\n1\n\n\n\npg_key_test\n\n\n' \
  | WARP_APP_DIR="$WORK/key-app4" WARP_MANAGER="$ROOT/warp-manager.sh" \
    bash "$WORK/key-wizard.sh" 2>/dev/null || true)"
check "install wizard asks for and stores the API key" \
  bash -c '[[ "$1" == *"KEY=pg_key_test"* && "$1" == *"APPLY=yes"* ]]' _ "$key_wiz"

# ---------------------------------------------------------------------------
printf '\n[8h] Full backup, restore and smart API key lifecycle\n'
check "--help documents backup" \
  bash -c "bash '$ROOT/warp-manager.sh' --help | grep -q 'backup      Full backup'"
check "--help documents restore and key" \
  bash -c "bash '$ROOT/warp-manager.sh' --help | grep -q 'key         Create/reuse'"
mkdir -p "$WORK/fakebin6" "$WORK/bk-app/outbound"
printf 'STATE=1\n' > "$WORK/bk-app/state.env"
printf '{}' > "$WORK/bk-app/outbound/outbounds.json"
cat >"$WORK/fakebin6/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  ps)
    if [[ "${2:-}" == "--format" ]]; then
      printf 'pasarguard-timescaledb-1 timescale/timescaledb:2.30.0-pg17\n'
      printf 'pasarguard-pasarguard-1 pasarguard/panel:latest\n'
      printf 'out-node pasarguard/node:latest\n'
    fi
    exit 0 ;;
  inspect)
    fmt="$4"
    case "$fmt" in
      *Config.Env*json*) printf '["POSTGRES_USER=pguser","POSTGRES_PASSWORD=pgpass","POSTGRES_DB=pgdb"]\n' ;;
      *Config.Env*println*) printf 'SQLALCHEMY_DATABASE_URL=postgresql+asyncpg://x\n' ;;
      *Config.Image*) printf 'timescale/timescaledb:latest\n' ;;
      *) printf '\n' ;;
    esac
    exit 0 ;;
  exec)
    printf -- '-- full database dump\nCREATE TABLE dummy(id int);\n'
    exit 0 ;;
  compose) printf 'services: {}\n'; exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/fakebin6/docker"
bk_dir="$(WARP_APP_DIR="$WORK/bk-app" PATH="$WORK/fakebin6:$PATH" \
  bash -c 'source "'"$ROOT"'/warp-manager.sh"; make_full_backup test' 2>/dev/null || true)"
check "backup creates a MANIFEST and RESTORE.md" \
  bash -c '[[ -f "$1/MANIFEST.txt" && -f "$1/RESTORE.md" && -f "$1/restore.sh" ]]' _ "$bk_dir"
check "backup archives the WARP app directory" \
  bash -c 'ls "$1"/files/*.tar.gz >/dev/null 2>&1' _ "$bk_dir"
check "backup includes a PostgreSQL dump" \
  bash -c '[[ -s "$1/db/pg_dumpall.sql" ]]' _ "$bk_dir"
check "backup records the DB container name" \
  bash -c '[[ "$(cat "$1/db/container.txt")" == "pasarguard-timescaledb-1" ]]' _ "$bk_dir"
# restore the archived files into a scratch root by re-extracting the tarball
check "backup tarball is readable" \
  bash -c 'tar tzf "$1"/files/*.tar.gz >/dev/null 2>&1' _ "$bk_dir"

cat >"$WORK/fakebin6/curl" <<'EOF'
#!/usr/bin/env bash
url="${@: -1}"
out=""; prev=""
for a in "$@"; do
  if [[ "$prev" == "-o" ]]; then out="$a"; fi
  prev="$a"
done
if [[ "$url" == */api/cores ]]; then
  printf '{"count":0,"cores":[]}' >"$out"; printf '200'; exit 0
fi
if [[ "$url" == */api/api_keys* ]]; then
  printf '{"api_keys":[],"total":0}' >"$out"; printf '200'; exit 0
fi
if [[ "$url" == */api/admin/token ]]; then
  printf '{"access_token":"JWT"}' >"$out"; printf '200'; exit 0
fi
if [[ "$url" == */api/api_key ]]; then
  printf '{"id":7,"name":"warp-manager","api_key":"pg_key_created_by_script"}' >"$out"
  printf '201'; exit 0
fi
printf '{}' >"$out"; printf '200'; exit 0
EOF
chmod +x "$WORK/fakebin6/curl"
key_out="$(WARP_APP_DIR="$WORK/key-life-app" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin6:$PATH" bash -c '
    source "$WARP_MANAGER"
    PANEL_URL="https://panel.example.com" INSECURE=1
    PANEL_USER="admin" PANEL_PASS="secret"
    ensure_api_key >/dev/null 2>&1
    printf "%s|%s" "$PANEL_API_KEY" "$PANEL_AUTH_MODE"' 2>/dev/null || true)"
assert_eq "ensure_api_key creates a key via the panel API" \
  "pg_key_created_by_script|api-key" "$key_out"
check "created key is persisted to state.env" \
  grep -q 'PANEL_API_KEY=pg_key_created_by_script' "$WORK/key-life-app/state.env"
mkdir -p "$WORK/fakebin7" "$WORK/rm-app/outbound"
cat >"$WORK/fakebin7/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/fakebin7/docker"
printf 'INSTALLED=1\nMODE=xray\n' > "$WORK/rm-app/state.env"
for f in outbounds.json routing-rules.json balancers.json README.txt; do printf '{}' > "$WORK/rm-app/outbound/$f"; done
cp "$ROOT/warp-manager.sh" "$WORK/rm-app/warp-manager.sh"
WARP_APP_DIR="$WORK/rm-app" PATH="$WORK/fakebin7:$WORK/bin:$PATH" \
  bash "$ROOT/warp-manager.sh" remove --yes >/dev/null 2>&1 || true
check "remove always keeps the pre-remove backup" \
  bash -c 'ls -d "$1"/backups/full-*pre-remove >/dev/null 2>&1' _ "$WORK/rm-app"
check "remove --yes keeps the manager command (no accidental uninstall)" \
  test -f "$WORK/rm-app/warp-manager.sh"
check "remove keeps the manager script so restore is possible" \
  test -f "$WORK/rm-app/warp-manager.sh"
rm_bk="$(ls -d "$WORK"/rm-app/backups/full-*pre-remove 2>/dev/null | head -1)"
check "generated restore.sh is valid bash" bash -n "$rm_bk/restore.sh"
rest_err="$(WARP_APP_DIR="$WORK/rm-app" bash "$ROOT/warp-manager.sh" restore /definitely/missing 2>&1 || true)"
check "restore rejects a missing backup directory" \
  bash -c '[[ "$1" == *"Usage: warp-manager restore"* ]]' _ "$rest_err"
key_reuse="$(WARP_APP_DIR="$WORK/key-life-app" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin6:$PATH" bash -c '
    source "$WARP_MANAGER"
    PANEL_URL="https://panel.example.com" INSECURE=1
    load_saved_api_key
    ensure_api_key >/dev/null 2>&1
    printf "%s" "$PANEL_API_KEY"' 2>/dev/null || true)"
assert_eq "second run reuses the same key across versions" \
  "pg_key_created_by_script" "$key_reuse"

# ---------------------------------------------------------------------------
printf '\n[8i] Zero-credential key creation via the panel database\n'
mkdir -p "$WORK/fakebin8"
cat >"$WORK/fakebin8/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  ps) printf 'pasarguard-timescaledb-1 timescale/timescaledb:latest\n'; exit 0 ;;
  inspect) printf '["POSTGRES_USER=pguser","POSTGRES_PASSWORD=pgpass","POSTGRES_DB=pgdb"]\n'; exit 0 ;;
  exec)
    if printf '%s\n' "$@" | grep -q -- '-tAc'; then printf '1\n'; else :; fi
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/fakebin8/docker"
dbkey="$(WARP_APP_DIR="$WORK/dbkey-app" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin8:$PATH" bash -c '
    source "$WARP_MANAGER"
    create_api_key_via_db' 2>/dev/null || true)"
check "create_api_key_via_db mints a pg_key_ UUID without any credentials" \
  bash -c '[[ "$1" =~ ^pg_key_[0-9a-f-]{36}$ ]]' _ "$dbkey"
key_lifecycle="$(WARP_APP_DIR="$WORK/dbkey-app2" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin8:$PATH" bash -c '
    source "$WARP_MANAGER"
    ASSUME_YES=1
    ensure_api_key >/dev/null 2>&1 || true
    printf "%s|%s" "$PANEL_API_KEY" "$(state_get PANEL_API_KEY "")"' 2>/dev/null || true)"
check "ensure_api_key persists the DB-created key to state.env" \
  bash -c '[[ "$1" == pg_key_*"|"pg_key_* ]]' _ "$key_lifecycle"
check "remove --yes keeps the warp-manager command" \
  bash -c "bash '$ROOT/warp-manager.sh' --help | grep -q -- '--uninstall-manager'"

# ---------------------------------------------------------------------------
printf '\n[9] Script self-update guards\n'
check "update rejects a non-bash payload" bash -c "
  WARP_APP_DIR='$WORK/up-app' WARP_UPDATE_URL='file://$ROOT/README.md' \
    bash '$ROOT/warp-manager.sh' update --check --yes 2>&1 | grep -qi 'not a bash script\|Update aborted\|Downloaded file'"
check "update --check compares versions from a local URL" bash -c "
  WARP_APP_DIR='$WORK/up-app2' WARP_UPDATE_URL='file://$ROOT/warp-manager.sh' \
    bash '$ROOT/warp-manager.sh' update --check --yes 2>&1 | grep -q 'up to date'"

# ---------------------------------------------------------------------------
printf '\n%s\n' "========================================================================"
printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then exit 1; fi
printf 'All smoke tests passed.\n'
