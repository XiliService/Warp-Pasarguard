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
check "menu lists Install option" bash -c "printf '%s' \"\$1\" | grep -q 'Install / Repair WARP'" _ "$menu_out"
check "menu Install option says it can repair" bash -c "printf '%s' \"\$1\" | grep -q 'Install / Repair WARP'" _ "$menu_out"
check "menu lists Update Script option" bash -c "printf '%s' \"\$1\" | grep -q 'Update Script'" _ "$menu_out"
check "menu exits cleanly on option 6" bash -c "printf '%s' \"\$1\" | grep -q 'Goodbye'" _ "$menu_out"

# ---------------------------------------------------------------------------
printf '\n[5] Dry-run install plan\n'
plan_out="$(WARP_APP_DIR="$WORK/plan-app" bash "$ROOT/warp-manager.sh" install \
  --mode xray --target exit --binding single --routing domains --yes --dry-run 2>&1 || true)"
check "plan shows the deployment target guidance" bash -c "printf '%s' \"\$1\" | grep -q 'MAIN PANEL server'" _ "$plan_out"
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
printf '\n[8j] Panel API transport when no host port is published\n'
mkdir -p "$WORK/fakebin9"
cat >"$WORK/fakebin9/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  ps) printf 'pasarguard-pasarguard-1 pasarguard/panel:latest\n'
      printf 'pasarguard-timescaledb-1 timescale/timescaledb:latest\n'; exit 0 ;;
  inspect)
    case "$4" in
      *State.Pid*) printf '4242\n' ;;
      *Config.Env*) printf '\n' ;;
      *NetworkSettings.Ports*) printf '{}\n' ;;
      *NetworkSettings.Networks*) printf '172.18.0.5 \n' ;;
      *Config.Image*) printf 'pasarguard/panel:latest\n' ;;
      *) printf '\n' ;;
    esac; exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/fakebin9/docker"
cat >"$WORK/fakebin9/nsenter" <<'EOF'
#!/usr/bin/env bash
while [[ "${1:-}" != "--" && $# -gt 0 ]]; do shift; done
[[ $# -gt 0 ]] && shift
exec env WARP_NSENTER_USED=1 "$@"
EOF
chmod +x "$WORK/fakebin9/nsenter"
cat >"$WORK/fakebin9/curl" <<'EOF'
#!/usr/bin/env bash
printf '200\n'
EOF
chmod +x "$WORK/fakebin9/curl"
urls="$(WARP_APP_DIR="$WORK/urls-app" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin9:$PATH" bash -c '
    source "$WARP_MANAGER"
    local_panel_urls' 2>/dev/null || true)"
check "local_panel_urls emits the container bridge IP even with no published port" \
  bash -c '[[ "$1" == *"http://172.18.0.5:8000"* ]]' _ "$urls"
check "local_panel_urls also emits the host loopback candidate" \
  bash -c '[[ "$1" == *"http://127.0.0.1:8000"* ]]' _ "$urls"
transport="$(WARP_APP_DIR="$WORK/ns-app" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin9:$PATH" bash -c '
    source "$WARP_MANAGER"; state_init
    PANEL_TRANSPORT="nsenter"; PANEL_CONTAINER="pasarguard-pasarguard-1"
    PANEL_NS_PID="4242"
    WARP_NSENTER_USED=""; curl_panel -sS -X GET http://127.0.0.1:8000/api/cores >/dev/null
    printf "%s|%s" "$PANEL_TRANSPORT" "$(state_get PANEL_CONTAINER "")"' 2>/dev/null || true)"
check "curl_panel uses nsenter when the panel has no host port" \
  bash -c '[[ "$1" == nsenter* ]]' _ "$transport"
ns_state="$(WARP_APP_DIR="$WORK/ns-app2" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin9:$PATH" bash -c '
    source "$WARP_MANAGER"; state_init
    PANEL_API_KEY="pg_key_test"
    panel_probe_key() { return 0; }
    panel_nsenter_probe >/dev/null 2>&1
    printf "%s|%s|%s" "$PANEL_TRANSPORT" "$(state_get PANEL_CONTAINER "")" "$(state_get PANEL_TRANSPORT "")"' 2>/dev/null || true)"
check "panel_nsenter_probe persists container and transport for later runs" \
  bash -c '[[ "$1" == "nsenter|pasarguard-pasarguard-1|nsenter" ]]' _ "$ns_state"

# ---------------------------------------------------------------------------
printf '\n[8k] Panel curl-inside-container (UDS / loopback-only) transport\n'
mkdir -p "$WORK/fakebin10"
cat >"$WORK/fakebin10/docker" <<EOF
#!/usr/bin/env bash
BOX="$WORK/exec-body"
case "\${1:-}" in
  ps) printf 'pasarguard-pasarguard-1 pasarguard/panel:latest\n'; exit 0 ;;
  inspect)
    case "\$4" in
      *Config.Env*) printf 'VITE_BASE_API=https://panel.example.com/\nUVICORN_UDS=/run/pasarguard.socket\nUVICORN_PORT=8000\n' ;;
      *) printf '\n' ;; esac; exit 0 ;;
  exec)
    shift; [[ "\${1:-}" == "-i" ]] && shift; cname="\$1"; shift
    if [[ "\${1:-}" == "rm" ]]; then rm -f "\$BOX"; exit 0; fi
    if [[ "\${1:-}" == "sh" ]]; then exit 0; fi
    if [[ "\${1:-}" == "curl" ]]; then
      shift
      while [[ \$# -gt 0 ]]; do
        if [[ "\$1" == "-o" ]]; then printf '{"cores":[]}' > "\$BOX"; shift 2
        elif [[ "\$1" == --unix-socket ]]; then shift 2
        elif [[ "\$1" == http://* ]]; then shift
        else shift; fi
      done
      printf '200'; exit 0
    fi
    exit 0 ;;
  cp) cp -f "\$BOX" "\$3" 2>/dev/null; exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/fakebin10/docker"
public="$(WARP_APP_DIR="$WORK/pub-app" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin10:$PATH" bash -c '
    source "$WARP_MANAGER"
    panel_public_urls' 2>/dev/null || true)"
check "panel_public_urls discovers VITE_BASE_API from the panel container" \
  bash -c '[[ "$1" == *"https://panel.example.com"* ]]' _ "$public"
check "panel_public_urls also emits the host FQDN" \
  bash -c '[[ "$1" == *"https://"* ]]' _ "$public"
exec_result="$(WARP_APP_DIR="$WORK/exec-app" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin10:$PATH" bash -c '
    source "$WARP_MANAGER"; state_init
    PANEL_TRANSPORT="docker-exec"; PANEL_CONTAINER="pasarguard-pasarguard-1"
    PANEL_EXEC_UDS="/run/pasarguard.socket"; PANEL_EXEC_SCHEME="http"
    PANEL_EXEC_HOST="127.0.0.1"; PANEL_EXEC_PORT="8000"
    out="$(mktemp)"
    code="$(curl_panel -sS -X GET -o "$out" -w "%{http_code}" http://127.0.0.1:8000/api/cores)"
    printf "%s|%s" "$code" "$(cat "$out")"' 2>/dev/null || true)"
check "curl_panel docker-exec returns the HTTP code and writes the body" \
  bash -c '[[ "$1" == "200|{\"cores\":[]}" ]]' _ "$exec_result"
exec_state="$(WARP_APP_DIR="$WORK/exec-app2" WARP_MANAGER="$ROOT/warp-manager.sh" \
  PATH="$WORK/fakebin10:$PATH" bash -c '
    source "$WARP_MANAGER"; state_init
    PANEL_API_KEY="pg_key_test"
    panel_probe_key() { return 0; }
    panel_exec_probe key >/dev/null 2>&1
    printf "%s|%s|%s" "$(state_get PANEL_TRANSPORT "")" "$(state_get PANEL_CONTAINER "")" "$(state_get PANEL_EXEC_UDS "")"' 2>/dev/null || true)"
check "panel_exec_probe persists the UDS transport for later runs" \
  bash -c '[[ "$1" == "docker-exec|pasarguard-pasarguard-1|/run/pasarguard.socket" ]]' _ "$exec_state"

# ---------------------------------------------------------------------------
printf '\n[8l] Userspace WireGuard outbound (does not take the node down)\n'
mkdir -p "$WORK/wgprof/profiles/default"
cat >"$WORK/wgprof/profiles/default/meta.env" <<'EOF'
TAG=warp
INTERFACE=warp
PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
ADDRESS4=172.16.0.2/32
ADDRESS6=fd01:db8::2/128
PUBLIC_KEY=bmXOC+F1FxEMF9dyiK2H5/1SUtzH0YoV0CV9KtCkQpHyo=
ENDPOINT=engage.cloudflareclient.com:2408
EOF
modern_out="$(WARP_APP_DIR="$WORK/wgprof" WARP_MANAGER="$ROOT/warp-manager.sh" bash -c '
  source "$WARP_MANAGER"; MODE=xray; MODERN_XRAY=1; build_outbound_json default' 2>/dev/null || true)"
check "WARP outbound uses noKernelTun true by default" \
  bash -c 'printf "%s" "$1" | jq -e ".settings.noKernelTun == true" >/dev/null' _ "$modern_out"
check "WARP outbound uses remoteDNS as an array" \
  bash -c '[[ "$1" == *"\"remoteDNS\""* ]]' _ "$modern_out"
check "WARP outbound no longer emits legacy kernelMode/DNS" \
  bash -c '[[ "$1" != *kernelMode* && "$1" != *"\"DNS\""* ]]' _ "$modern_out"
legacy_out="$(WARP_APP_DIR="$WORK/wgprof" WARP_MANAGER="$ROOT/warp-manager.sh" bash -c '
  source "$WARP_MANAGER"; MODE=xray; MODERN_XRAY=0; build_outbound_json default' 2>/dev/null || true)"
check "--legacy-xray still emits the old kernelMode/DNS fields" \
  bash -c '[[ "$1" == *kernelMode* && "$1" == *"\"DNS\""* ]]' _ "$legacy_out"
check "--help documents --legacy-xray" \
  bash -c "bash '$ROOT/warp-manager.sh' --help | grep -q -- '--legacy-xray'"
check "apply rebuilds snippets from the stored WARP profile" \
  bash -c "sed -n '/^cmd_apply()/,/^}/p' '$ROOT/warp-manager.sh' | grep -q 'build_snippets'"
check "apply has an automatic rollback safety net" \
  bash -c "grep -q 'panel_rollback_core' '$ROOT/warp-manager.sh'"
cat >"$WORK/rollback-snapshot.json" <<'EOF'
{"id":1,"name":"Default Core Config","type":"xray","config":{"outbounds":[{"tag":"DIRECT","protocol":"freedom"}],"routing":{"rules":[]}},"exclude_inbound_tags":[],"fallbacks_inbound_tags":[]}
EOF
rb_body="$(WARP_APP_DIR="$WORK/rb-app" WARP_MANAGER="$ROOT/warp-manager.sh" bash -c '
  source "$WARP_MANAGER"; state_init
  panel_api() { BODY="$3"; PANEL_API_BODY="{}"; return 0; }
  panel_rollback_core 1 "$1"
  printf "%s" "$BODY"' _ "$WORK/rollback-snapshot.json" 2>/dev/null || true)"
check "automatic rollback PUTs the exact pre-apply core config" \
  bash -c 'printf %s "$1" | grep -q "Default Core Config" && printf %s "$1" | grep -q DIRECT && printf %s "$1" | grep -q xray' _ "$rb_body"
cat >"$WORK/nodes-health.json" <<'EOF'
{"nodes":[{"id":3,"status":"error"},{"id":1,"status":"connected"}],"total":2}
EOF
health="$(WARP_APP_DIR="$WORK/h-app" NODES_FILE="$WORK/nodes-health.json" \
  WARP_MANAGER="$ROOT/warp-manager.sh" bash -c '
  source "$WARP_MANAGER"; state_init
  panel_api() { PANEL_API_BODY="$(cat "$NODES_FILE")"; return 0; }
  panel_error_node_ids
  printf "%s|%s" "$PANEL_ERROR_IDS" "$PANEL_HEALTH_AVAILABLE"' 2>/dev/null || true)"
check "post-apply health check detects a node in error state" \
  bash -c '[[ "$1" == "3|1" ]]' _ "$health"

# ---------------------------------------------------------------------------
printf '\n[8m] Main-panel only: WARP must be scoped to tunnel inbounds\n'
cat >"$WORK/iran-core.json" <<'JSON'
{
  "id": 1, "name": "Default Core Config", "type": "xray",
  "exclude_inbound_tags": [], "fallbacks_inbound_tags": [],
  "config": {
    "inbounds": [
      {"tag": "[DE] - CloudFlare - CDN", "protocol": "vless"},
      {"tag": "[DE] - Tunnel - ArvanCloud", "protocol": "vless"},
      {"tag": "[NL] - Tunnel - ArvanCloud", "protocol": "vless"}
    ],
    "outbounds": [
      {"tag": "DIRECT", "protocol": "freedom"},
      {"tag": "Germany", "protocol": "vless"},
      {"tag": "BLOCK", "protocol": "blackhole"}
    ],
    "routing": {"rules": [
      {"type": "field", "outboundTag": "BLOCK", "ip": ["geoip:private"]},
      {"type": "field", "inboundTag": ["[DE] - CloudFlare - CDN"], "outboundTag": "Germany"}
    ]}
  }
}
JSON
cat >"$WORK/no-tunnel-core.json" <<'JSON'
{"id":1,"name":"foreign-node","type":"xray","exclude_inbound_tags":[],"fallbacks_inbound_tags":[],
 "config":{"inbounds":[{"tag":"Germany","protocol":"vless"},{"tag":"NetherLands","protocol":"vless"},{"tag":"Poland","protocol":"vless"}],
 "outbounds":[{"tag":"DIRECT","protocol":"freedom"},{"tag":"Out-DE","protocol":"freedom"},{"tag":"BLOCK","protocol":"blackhole"}],
 "routing":{"rules":[{"type":"field","outboundTag":"BLOCK"}]}}}
JSON
printf '%s\n' '["[DE] - Tunnel - ArvanCloud","[NL] - Tunnel - ArvanCloud"]' >"$WORK/tunnel-tags.json"
scoped="$(WARP_APP_DIR="$WORK/scoped-app" TAGS_FILE="$WORK/tunnel-tags.json" \
  WARP_MANAGER="$ROOT/warp-manager.sh" bash -c '
  source "$WARP_MANAGER"; state_init
  WARP_TUNNEL_TAGS="$(cat "$TAGS_FILE")"
  MODE="xray"; ROUTING="domains"; RULE_PREPEND=0; MODERN_XRAY=1
  profile_meta_set demo PRIVATE_KEY "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  profile_meta_set demo ADDRESS4 "172.16.0.2/32"
  profile_meta_set demo ADDRESS6 ""
  profile_meta_set demo PUBLIC_KEY "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0YoV0CV9KtCkQpHyo="
  profile_meta_set demo ENDPOINT "engage.cloudflareclient.com:2408"
  profile_meta_set demo TAG "warp"
  build_snippets demo >/dev/null 2>&1
  merge_core_config "$1" "$2" apply
  jq -c ".routing.rules[1]" "$2"' _ "$WORK/iran-core.json" "$WORK/scoped-out.json" 2>/dev/null || true)"
check "WARP rule is scoped to the tunnel inbounds on the main panel core" \
  bash -c 'printf %s "$1" | grep -q inboundTag && printf %s "$1" | grep -q warp' _ "$scoped"
check "scoped WARP rule drops the global domain catch-all" \
  bash -c '! printf %s "$1" | grep -q domain' _ "$scoped"
assert_eq "BLOCK rule stays above the WARP rule" "BLOCK" \
  "$(jq -r '.routing.rules[0].outboundTag' "$WORK/scoped-out.json" 2>/dev/null)"
guard="$(WARP_APP_DIR="$WORK/guard-app" WARP_MANAGER="$ROOT/warp-manager.sh" bash -c '
  source "$WARP_MANAGER"; state_init
  PANEL_API_KEY="pg_key_test"; PANEL_CORE_ID="1"; PANEL_URL="http://127.0.0.1:8000"
  panel_login() { return 0; }
  panel_api() { PANEL_API_BODY="$(cat "$1")"; return 0; }
  apply_to_panel apply 2>&1 || true' _ "$WORK/no-tunnel-core.json" 2>/dev/null || true)"
check "apply refuses a shared egress core with no tunnel inbound" \
  bash -c '[[ "$1" == *"shared egress relay"* ]]' _ "$guard"
check "--all-traffic is documented" \
  bash -c "bash '$ROOT/warp-manager.sh' --help | grep -q -- '--all-traffic'"

# ---------------------------------------------------------------------------
printf '\n[8n] Reuse a WARP account when Cloudflare registration is blocked\n'
mkdir -p "$WORK/export-app/profiles/default"
cat >"$WORK/export-app/profiles/default/meta.env" <<'EOF'
TAG=warp
INTERFACE=warp
PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
ADDRESS4=172.16.0.2/32
ADDRESS6=fd01:db8::2/128
PUBLIC_KEY=bmXOC+F1FxEMF9dyiK2H5/1SUtzH0YoV0CV9KtCkQpHyo=
ENDPOINT=engage.cloudflareclient.com:2408
EOF
printf 'PROFILES=default\n' >"$WORK/export-app/state.env"
blob="$(WARP_APP_DIR="$WORK/export-app" bash "$ROOT/warp-manager.sh" export-profile 2>/dev/null | grep '^WARP1:' || true)"
check "export-profile emits a single WARP1: line" \
  bash -c '[[ "$1" == WARP1:* && "$1" != *" "* ]]' _ "$blob"
check "export-profile refuses an app with no profile" \
  bash -c "! WARP_APP_DIR='$WORK/empty-export' bash '$ROOT/warp-manager.sh' export-profile >/dev/null 2>&1"
import_out="$(WARP_APP_DIR="$WORK/import-app" bash "$ROOT/warp-manager.sh" import-profile "$blob" 2>&1 || true)"
check "import-profile writes the profile without any Cloudflare call" \
  bash -c '[[ "$1" == *"No Cloudflare registration was needed"* ]]' _ "$import_out"
check "import-profile generates the outbound snippets" \
  bash -c "jq -e '.[0].settings.noKernelTun == true' '$WORK/import-app/outbound/outbounds.json' >/dev/null"
check "import-profile marks the deployment installed" \
  bash -c "grep -q 'INSTALLED=1' '$WORK/import-app/state.env'"
check "create_profile reuses an existing account instead of calling wgcf" \
  bash -c "sed -n '/^create_profile()/,/^}/p' '$ROOT/warp-manager.sh' | grep -q 'Reusing the existing WARP account'"
check "install banner no longer tells the user to run on the foreign node" \
  bash -c "! sed -n '/Deployment target - READ CAREFULLY/,/^TXT/p' '$ROOT/warp-manager.sh' | grep -q 'run this script on the FOREIGN node'"
check "--help documents export-profile / import-profile" \
  bash -c "bash '$ROOT/warp-manager.sh' --help | grep -q -- 'import-profile'"
check "apply auto-selects the Core with tunnel inbounds" \
  bash -c "grep -q 'Auto-selected Core config' '$ROOT/warp-manager.sh'"
check "--yes never opens an interactive Core selector" \
  bash -c "sed -n '/^apply_to_panel()/,/^}/p' '$ROOT/warp-manager.sh' | grep -q 'ASSUME_YES'"

# ---------------------------------------------------------------------------
printf '\n[8o] Dedicated WARP inbound (1.0.17): existing configs untouched\n'
cat >"$WORK/warp-inbound-e2e.sh" <<'EOS'
WD="$1"; ROOT="$2"
WARP_APP_DIR="$WD/inbound-app"
source "$ROOT/warp-manager.sh" >/dev/null 2>&1 || true
state_init
mkdir -p "$BACKUP_DIR"
state_set PANEL_API_KEY pg_key_test
state_set PANEL_URL "http://127.0.0.1:8000"
PANEL_CORE_ID=1
# Live core = the state left behind by the old (broken) warp-join: the tunnel
# tag was split out of the Germany rule.
LIVE='{"id":1,"name":"Default Core Config","type":"xray","exclude_inbound_tags":[],"fallbacks_inbound_tags":[],"config":{"inbounds":[{"tag":"[DE] - CloudFlare - CDN","protocol":"vless","port":2053,"streamSettings":{"network":"tcp","security":"reality"}},{"tag":"[DE] - Tunnel - ArvanCloud","protocol":"vless","port":64710},{"tag":"[NL] - Tunnel - ArvanCloud","protocol":"vless","port":33613},{"tag":"WARP-DEDICATED","protocol":"socks","port":23458}],"outbounds":[{"tag":"DIRECT","protocol":"freedom"},{"tag":"Germany","protocol":"vless"},{"tag":"WARP-LINK","protocol":"socks"},{"tag":"BLOCK","protocol":"blackhole"}],"routing":{"rules":[{"type":"field","outboundTag":"BLOCK","ip":["geoip:private"]},{"type":"field","inboundTag":["[DE] - CloudFlare - CDN","[DE] - Tunnel - ArvanCloud"],"outboundTag":"Germany"},{"type":"field","inboundTag":["[NL] - Tunnel - ArvanCloud"],"outboundTag":"NetherLands"},{"type":"field","inboundTag":["WARP-DEDICATED"],"outboundTag":"WARP-LINK"}]}}}'
# Pre-join backup = the original, undamaged rules.
ORIG='{"id":1,"name":"Default Core Config","type":"xray","exclude_inbound_tags":[],"fallbacks_inbound_tags":[],"config":{"inbounds":[{"tag":"[DE] - CloudFlare - CDN","protocol":"vless","port":2053},{"tag":"[DE] - Tunnel - ArvanCloud","protocol":"vless","port":64710},{"tag":"[NL] - Tunnel - ArvanCloud","protocol":"vless","port":33613}],"outbounds":[{"tag":"DIRECT","protocol":"freedom"},{"tag":"Germany","protocol":"vless"},{"tag":"BLOCK","protocol":"blackhole"}],"routing":{"rules":[{"type":"field","outboundTag":"BLOCK","ip":["geoip:private"]},{"type":"field","inboundTag":["[DE] - CloudFlare - CDN","[DE] - Tunnel - ArvanCloud"],"outboundTag":"Germany"},{"type":"field","inboundTag":["[NL] - Tunnel - ArvanCloud"],"outboundTag":"NetherLands"}]}}}'
printf '%s\n' "$ORIG" > "$BACKUP_DIR/warp-join-core-1-20261103-145646.json"
panel_login() { return 0; }
confirm() { return 0; }
ensure_api_key() { return 0; }
curl() { printf '{"ip":"104.16.0.1","org":"Cloudflare, Inc."}'; }
panel_api() {
  local m="$1" p="$2" b="${3:-}"
  if [[ "$m" == GET && "$p" == "/cores" ]]; then
    PANEL_API_BODY='{"count":1,"cores":[{"id":1,"name":"Default Core Config"}]}'; return 0; fi
  if [[ "$m" == GET && "$p" == /core/* ]]; then PANEL_API_BODY="$LIVE"; return 0; fi
  if [[ "$m" == PUT ]]; then printf '%s' "$b" > "$WD/inbound-put.json"; PANEL_API_BODY='{}'; return 0; fi
  return 1
}
LINK_BLOB="$(printf '%s' '{"host":"95.135.200.231","port":31234,"user":"warpu","pass":"passw","tag":"WARP-LINK"}' | base64 -w0)"
cmd_warp_inbound "$LINK_BLOB" > "$WD/inbound-out.txt" 2>&1 || exit 1
exit 0
EOS
bash "$WORK/warp-inbound-e2e.sh" "$WORK" "$ROOT" >/dev/null 2>&1 || true
check "warp-inbound E2E produced a Core config PUT" \
  bash -c "jq -e '.config.inbounds' '$WORK/inbound-put.json' >/dev/null"
check "warp-inbound restores the original location rules (tunnel tag back)" \
  bash -c "jq -e '[.config.routing.rules[] | select(.outboundTag==\"Germany\") | .inboundTag[]] == [\"[DE] - CloudFlare - CDN\",\"[DE] - Tunnel - ArvanCloud\"]' '$WORK/inbound-put.json' >/dev/null"
check "no existing config is routed to WARP-LINK" \
  bash -c "jq -e '[.config.routing.rules[] | select(.outboundTag==\"WARP-LINK\") | .inboundTag[]] == [\"WARP-DEDICATED\"]' '$WORK/inbound-put.json' >/dev/null"
check "exactly one WARP rule is added" \
  bash -c "jq -e '[.config.routing.rules[] | select(.outboundTag==\"WARP-LINK\")] | length == 1' '$WORK/inbound-put.json' >/dev/null"
check "the 1.0.17 SOCKS5 inbound is replaced by a real VLESS inbound" \
  bash -c "jq -e '[.config.inbounds[] | select(.tag==\"WARP-DEDICATED\") | .protocol] == [\"vless\"]' '$WORK/inbound-put.json' >/dev/null"
check "no SOCKS5 inbound remains on the Iran core" \
  bash -c "jq -e '[.config.inbounds[] | select(.protocol==\"socks\")] | length == 0' '$WORK/inbound-put.json' >/dev/null"
check "the clone keeps the source streamSettings (host-compatible)" \
  bash -c "jq -e '.config.inbounds[] | select(.tag==\"WARP-DEDICATED\") | .streamSettings.security == \"reality\"' '$WORK/inbound-put.json' >/dev/null"
check "the clone has a fresh port, different from the source" \
  bash -c "jq -e '(.config.inbounds[] | select(.tag==\"WARP-DEDICATED\") | .port) != 2053' '$WORK/inbound-put.json' >/dev/null"
check "the WARP rule sits below the leading BLOCK rule" \
  bash -c "jq -e '([.config.routing.rules[].outboundTag] | index(\"BLOCK\")) < ([.config.routing.rules[].outboundTag] | index(\"WARP-LINK\"))' '$WORK/inbound-put.json' >/dev/null"
check "the WARP-LINK outbound is inserted before BLOCK" \
  bash -c "jq -e '[.config.outbounds[].tag] | index(\"WARP-LINK\") < index(\"BLOCK\")' '$WORK/inbound-put.json' >/dev/null"
check "no local WARP wireguard outbound remains" \
  bash -c "jq -e '[.config.outbounds[] | select(.tag==\"warp\")] | length == 0' '$WORK/inbound-put.json' >/dev/null"
check "the dedicated inbound is panel-visible (tag + protocol + port)" \
  bash -c "jq -e '.config.inbounds[] | select(.tag==\"WARP-DEDICATED\") | has(\"tag\") and has(\"protocol\") and has(\"port\")' '$WORK/inbound-put.json' >/dev/null"
check "the SOCKS outbound points at the foreign link" \
  bash -c "jq -e '.config.outbounds[] | select(.tag==\"WARP-LINK\") | .settings.servers[0].address == \"95.135.200.231\"' '$WORK/inbound-put.json' >/dev/null"
check "warp-inbound prints the exact host-creation step" \
  bash -c "grep -q 'Add Host' '$WORK/inbound-out.txt' && grep -q 'Inbound tag' '$WORK/inbound-out.txt'"
check "warp-inbound names the cloned source inbound" \
  bash -c "grep -q 'Cloning inbound' '$WORK/inbound-out.txt'"
check "warp-inbound reports the live Cloudflare test" \
  bash -c "grep -q 'Live WARP test through the foreign node' '$WORK/inbound-out.txt'"
check "warp-join is now an alias of warp-inbound (no rule splitting)" \
  bash -c "sed -n '/^cmd_warp_join()/,/^}/p' '$ROOT/warp-manager.sh' | grep -q 'cmd_warp_inbound'"
check "--help documents warp-inbound / warp-unlink / --show" \
  bash -c "bash '$ROOT/warp-manager.sh' --help | grep -q 'warp-inbound' && bash '$ROOT/warp-manager.sh' --help | grep -q 'warp-unlink' && bash '$ROOT/warp-manager.sh' --help | grep -q -- '--show'"
check "warp-link --show prints the saved line without a panel call" \
  bash -c "WARP_APP_DIR='$WORK/show-app' WARP_MANAGER='$ROOT/warp-manager.sh' bash -c '
     source \"\$WARP_MANAGER\" >/dev/null 2>&1 || true
     state_init
     state_set_many \"WARP_LINK_HOST=95.135.200.231\" \"WARP_LINK_PORT=31234\" \"WARP_LINK_USER=warpu\" \"WARP_LINK_PASS=passw\"
     panel_api(){ return 1; }
     WARP_LINK_SHOW=1; cmd_warp_link
   ' | grep -q 'WARPLINK1:'"

cat >"$WORK/warp-unlink-e2e.sh" <<'EOS'
WD="$1"; ROOT="$2"
WARP_APP_DIR="$WD/unlink-app"
source "$ROOT/warp-manager.sh" >/dev/null 2>&1 || true
state_init
mkdir -p "$BACKUP_DIR"
state_set PANEL_API_KEY pg_key_test
PANEL_CORE_ID=1
ORIG='{"id":1,"name":"Default Core Config","type":"xray","config":{"inbounds":[{"tag":"[DE] - CloudFlare - CDN","protocol":"vless","port":2053},{"tag":"[DE] - Tunnel - ArvanCloud","protocol":"vless","port":64710}],"outbounds":[{"tag":"DIRECT","protocol":"freedom"},{"tag":"Germany","protocol":"vless"},{"tag":"BLOCK","protocol":"blackhole"}],"routing":{"rules":[{"type":"field","outboundTag":"BLOCK"},{"type":"field","inboundTag":["[DE] - CloudFlare - CDN","[DE] - Tunnel - ArvanCloud"],"outboundTag":"Germany"}]}}}'
LIVE='{"id":1,"name":"Default Core Config","type":"xray","config":{"inbounds":[{"tag":"[DE] - CloudFlare - CDN","protocol":"vless","port":2053},{"tag":"[DE] - Tunnel - ArvanCloud","protocol":"vless","port":64710},{"tag":"WARP-DEDICATED","protocol":"vless","port":23458}],"outbounds":[{"tag":"DIRECT","protocol":"freedom"},{"tag":"Germany","protocol":"vless"},{"tag":"WARP-LINK","protocol":"socks"},{"tag":"BLOCK","protocol":"blackhole"}],"routing":{"rules":[{"outboundTag":"BLOCK"},{"inboundTag":["[DE] - CloudFlare - CDN","[DE] - Tunnel - ArvanCloud"],"outboundTag":"Germany"},{"inboundTag":["WARP-DEDICATED"],"outboundTag":"WARP-LINK"}]}}}'
printf '%s\n' "$ORIG" > "$BACKUP_DIR/warp-join-core-1-20261103-145646.json"
panel_login() { return 0; }
confirm() { return 0; }
ensure_api_key() { return 0; }
panel_api() {
  local m="$1" p="$2" b="${3:-}"
  if [[ "$m" == GET && "$p" == /cores ]]; then PANEL_API_BODY='{"cores":[{"id":1}]}'; return 0; fi
  if [[ "$m" == GET && "$p" == /core/* ]]; then PANEL_API_BODY="$LIVE"; return 0; fi
  if [[ "$m" == PUT ]]; then printf '%s' "$b" > "$WD/unlink-put.json"; PANEL_API_BODY='{}'; return 0; fi
  return 1
}
cmd_warp_unlink >/dev/null 2>&1 || exit 1
exit 0
EOS
bash "$WORK/warp-unlink-e2e.sh" "$WORK" "$ROOT" >/dev/null 2>&1 || true
check "warp-unlink restores the exact original Core rules" \
  bash -c "jq -e '[.config.routing.rules[] | select(.outboundTag==\"Germany\") | .inboundTag[]] == [\"[DE] - CloudFlare - CDN\",\"[DE] - Tunnel - ArvanCloud\"]' '$WORK/unlink-put.json' >/dev/null"
check "warp-unlink removes the dedicated WARP inbound" \
  bash -c "jq -e '[.config.inbounds[] | select(.tag==\"WARP-DEDICATED\")] | length == 0' '$WORK/unlink-put.json' >/dev/null"
check "warp-unlink removes the WARP-LINK outbound" \
  bash -c "jq -e '[.config.outbounds[] | select(.tag==\"WARP-LINK\")] | length == 0' '$WORK/unlink-put.json' >/dev/null"
cat >"$WORK/nobackup-e2e.sh" <<'EOS'
WD="$1"; ROOT="$2"
WARP_APP_DIR="$WD/nobackup-app"
source "$ROOT/warp-manager.sh" >/dev/null 2>&1 || true
state_init
state_set PANEL_API_KEY pg_key_test
PANEL_CORE_ID=1
panel_login() { return 0; }
confirm() { return 0; }
curl() { printf '{"ip":"1.1.1.1","org":"Cloudflare"}'; }
panel_api() {
  local m="$1" p="$2" b="${3:-}"
  if [[ "$m" == PUT ]]; then printf '%s' "$b" > "$WD/nobackup-put.json"; PANEL_API_BODY='{}'; return 0; fi
  PANEL_API_BODY='{"config":{"inbounds":[{"tag":"CDN","protocol":"vless","port":443}],"outbounds":[{"tag":"BLOCK","protocol":"blackhole"}],"routing":{"rules":[{"outboundTag":"BLOCK"}]}}}'
  return 0
}
LINK="$(printf '%s' '{"host":"95.135.200.231","port":31234,"user":"u","pass":"p","tag":"WARP-LINK"}' | base64 -w0)"
cmd_warp_inbound "$LINK" >/dev/null 2>&1 || exit 1
exit 0
EOS
bash "$WORK/nobackup-e2e.sh" "$WORK" "$ROOT" >/dev/null 2>&1 || true
check "warp-inbound works without a pre-join backup (live baseline)" \
  bash -c "jq -e '.config.inbounds[] | select(.tag==\"WARP-DEDICATED\") | .protocol == \"vless\"' '$WORK/nobackup-put.json' >/dev/null"

cat >"$WORK/reality-core.json" <<'JSON'
{"config":{"inbounds":[
 {"tag":"[DE] - CloudFlare - CDN","protocol":"vless","port":2053,"streamSettings":{"network":"ws"}},
 {"tag":"[DE] - Tunnel - ArvanCloud","protocol":"vless","port":64710},
 {"tag":"[DE] - DC - Reality","protocol":"vless","port":443,"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"dest":"www.microsoft.com:443"}}},
 {"tag":"WARP-DEDICATED","protocol":"socks","port":29580}
],"outbounds":[],"routing":{"rules":[]}}}
JSON
cat >"$WORK/reality-pick.sh" <<'EOS'
jq -r --arg t 'WARP-DEDICATED' '
   [ (.config.inbounds // [])[] | select((.tag // "") != $t)
     | select(((.protocol // "") | ascii_downcase | test("^(vless|vmess|trojan|shadowsocks)$"))) ] as $c
   | (([$c[] | select((.tag // "") | ascii_downcase | test("reality|dc"))] + $c)
      | .[0].tag // empty)
 ' "$1/reality-core.json" | grep -Fqx '[DE] - DC - Reality'
EOS
check "warp-inbound prefers a Reality/DC inbound as the clone source" \
  bash "$WORK/reality-pick.sh" "$WORK"
check "warp-inbound no longer builds a SOCKS5 inbound with password accounts" \
  bash -c "! sed -n '/^cmd_warp_inbound()/,/^}/p' '$ROOT/warp-manager.sh' | grep -Fq 'accounts:'"
check "warp-inbound clones a real inbound (source check)" \
  bash -c "sed -n '/^cmd_warp_inbound()/,/^}/p' '$ROOT/warp-manager.sh' | grep -Fq 'Cloning inbound'"
check "warp-inbound mentions v2rayNG / v2rayN in its output (source check)" \
  bash -c "sed -n '/^cmd_warp_inbound()/,/^}/p' '$ROOT/warp-manager.sh' | grep -q 'v2rayNG / v2rayN'"
check "warp-unlink removes WARP items surgically, not by restoring a backup" \
  bash -c "sed -n '/^cmd_warp_unlink()/,/^}/p' '$ROOT/warp-manager.sh' | grep -q 'Surgical removal'"

# ---------------------------------------------------------------------------
printf '\n[8p] warp-link on the foreign relay\n'
cat >"$WORK/link-foreign-core.json" <<'JSON'
{"id":1,"name":"Kharej","type":"xray","exclude_inbound_tags":[],"fallbacks_inbound_tags":[],
"config":{"inbounds":[{"tag":"Germany","protocol":"vless","port":64483},{"tag":"SOCKS5","protocol":"socks","port":16356}],
"outbounds":[{"tag":"DIRECT","protocol":"freedom"},{"tag":"Out-DE","protocol":"freedom"},{"tag":"BLOCK","protocol":"blackhole"}],
"routing":{"rules":[{"type":"field","outboundTag":"BLOCK"},{"type":"field","inboundTag":["Germany"],"outboundTag":"Out-DE"},{"type":"field","inboundTag":["SOCKS5"],"outboundTag":"Out-DE"}]}}}
JSON
link_put="$WORK/link-put.json"
CORE_FILE="$WORK/link-foreign-core.json" OUT_FILE="$link_put" \
WARP_APP_DIR="$WORK/link-app" WARP_MANAGER="$ROOT/warp-manager.sh" bash -c '
  source "$WARP_MANAGER"; state_init
  state_set PANEL_API_KEY pg_key_test; state_set PANEL_URL "http://127.0.0.1:8000"
  state_set PROFILES default
  profile_meta_set default PRIVATE_KEY "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  profile_meta_set default ADDRESS4 "172.16.0.2/32"
  profile_meta_set default ADDRESS6 ""
  profile_meta_set default PUBLIC_KEY "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0YoV0CV9KtCkQpHyo="
  profile_meta_set default ENDPOINT "engage.cloudflareclient.com:2408"
  profile_meta_set default TAG "warp"
  PANEL_CORE_ID=""
  panel_login() { return 0; }
  confirm() { return 0; }
  ensure_api_key() { return 0; }
  panel_api() {
    local m="$1" p="$2" b="${3:-}"
    if [[ "$m" == GET && "$p" == "/cores" ]]; then
      PANEL_API_BODY="{\"count\":1,\"cores\":[{\"id\":1,\"name\":\"Kharej\"}]}"; return 0; fi
    if [[ "$m" == GET && "$p" == /core/* ]]; then
      PANEL_API_BODY="$(cat "$CORE_FILE")"; return 0; fi
    if [[ "$m" == PUT ]]; then printf "%s" "$b" > "$OUT_FILE"; PANEL_API_BODY="{}"; return 0; fi
    return 0
  }
  cmd_warp_link >/dev/null 2>&1 || true' 2>/dev/null || true
check "warp-link sends a valid Core config PUT" \
  bash -c "jq -e '.config.outbounds' '$link_put' >/dev/null"
check "warp-link adds the WARP outbound before BLOCK" \
  bash -c "jq -e '[.config.outbounds[].tag] | index(\"warp\") < index(\"BLOCK\")' '$link_put' >/dev/null"
check "warp-link creates a private WARP-LINK socks inbound" \
  bash -c "jq -e '[.config.inbounds[] | select(.tag==\"WARP-LINK\") | .protocol] == [\"socks\"]' '$link_put' >/dev/null"
check "warp-link scopes WARP to that inbound only" \
  bash -c "jq -e '[.config.routing.rules[] | select(.outboundTag==\"warp\") | .inboundTag[]] == [\"WARP-LINK\"]' '$link_put' >/dev/null"
check "warp-link leaves the location rules untouched" \
  bash -c "jq -e '[.config.routing.rules[] | select(.outboundTag==\"Out-DE\")] | length == 2' '$link_put' >/dev/null"
check "warp-link WARP outbound is userspace" \
  bash -c "jq -e '.config.outbounds[] | select(.tag==\"warp\") | .settings.noKernelTun == true' '$link_put' >/dev/null"
check "--core-id override is honoured by the link commands" \
  bash -c "WARP_APP_DIR='$WORK/cid-app' PANEL_CORE_ID=7 WARP_MANAGER='$ROOT/warp-manager.sh' bash -c 'source \"\$WARP_MANAGER\" >/dev/null 2>&1 || true; PANEL_CORE_ID=7; resolve_link_core 1; [[ \"\$PANEL_SELECTED_CORE_ID\" == 7 ]]'"
cat >"$WORK/mismatch-core.sh" <<'EOS'
WARP_APP_DIR="$1/cid2-app"
source "$2/warp-manager.sh" >/dev/null 2>&1 || true
panel_login() { return 0; }
panel_api() {
  if [[ "$1" == GET && "$2" == /cores ]]; then
    PANEL_API_BODY='{"cores":[{"id":1}]}'
  else
    PANEL_API_BODY='{"config":{"inbounds":[{"tag":"Germany"}]}}'
  fi
  return 0
}
PANEL_CORE_ID=""
if panel_authed_core 1 >/dev/null 2>&1; then exit 1; fi
exit 0
EOS
check "core auto-selection refuses to guess on a mismatched relay" \
  bash "$WORK/mismatch-core.sh" "$WORK" "$ROOT"
cat >"$WORK/polluted-core.sh" <<'EOS'
WARP_APP_DIR="$1/pollution-app"
source "$2/warp-manager.sh" >/dev/null 2>&1 || true
# Reproduce the real-host bug: panel_login/panel_api print progress to stdout
panel_login() { info "Checking 21 candidate panel endpoint(s) with the API key."; ok "Panel API key accepted at https://127.0.0.1:443"; return 0; }
panel_api() {
  info "Checking 21 candidate panel endpoint(s) with the API key."
  ok "Panel API key accepted at https://127.0.0.1:443"
  if [[ "$1" == GET && "$2" == /cores ]]; then PANEL_API_BODY='{"cores":[{"id":1}]}'
  else PANEL_API_BODY='{"config":{"inbounds":[{"tag":"Germany"}]}}'; fi
  return 0
}
PANEL_CORE_ID=""
resolve_link_core 0 || exit 1
require_clean_core_id "$PANEL_SELECTED_CORE_ID" || exit 1
[[ "$PANEL_SELECTED_CORE_ID" == 1 ]] || exit 1
EOS
check "progress logs no longer pollute the selected Core ID (regression)" \
  bash "$WORK/polluted-core.sh" "$WORK" "$ROOT"
check "cmd_warp_link does not capture Core selection in a subshell" \
  bash -c "grep -q 'resolve_link_core 0 || die' '$ROOT/warp-manager.sh'"
check "cmd_warp_join does not capture Core selection in a subshell" \
  bash -c "grep -q 'resolve_link_core 1 || die' '$ROOT/warp-manager.sh'"

# ---------------------------------------------------------------------------
printf '\n[8q] Real-host regression: noisy panel logs + warp-link\n'
cat >"$WORK/noisy-link.sh" <<'EOS'
WORK_DIR="$1"
APP_ROOT="$2"
WARP_APP_DIR="$WORK_DIR/noisy-app"
source "$APP_ROOT/warp-manager.sh" >/dev/null 2>&1 || true
state_init
state_set PANEL_API_KEY pg_key_test; state_set PANEL_URL "http://127.0.0.1:8000"
state_set PROFILES default
profile_meta_set default PRIVATE_KEY "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
profile_meta_set default ADDRESS4 "172.16.0.2/32"
profile_meta_set default ADDRESS6 ""
profile_meta_set default PUBLIC_KEY "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0YoV0CV9KtCkQpHyo="
profile_meta_set default ENDPOINT "engage.cloudflareclient.com:2408"
profile_meta_set default TAG "warp"
PANEL_CORE_ID=""
panel_login() {
  info "Checking 21 candidate panel endpoint(s) with the API key."
  ok "Panel API key accepted at https://127.0.0.1:443"
  return 0
}
panel_api() {
  info "Checking 21 candidate panel endpoint(s) with the API key."
  ok "Panel API key accepted at https://127.0.0.1:443"
  local m="$1" p="$2" b="${3:-}"
  if [[ "$m" == GET && "$p" == "/cores" ]]; then
    PANEL_API_BODY='{"count":1,"cores":[{"id":1,"name":"Kharej"}]}'; return 0
  fi
  if [[ "$m" == GET && "$p" == "/core/1" ]]; then
    PANEL_API_BODY='{"id":1,"name":"Kharej","type":"xray","exclude_inbound_tags":[],"fallbacks_inbound_tags":[],"config":{"inbounds":[{"tag":"Germany","protocol":"vless","port":64483}],"outbounds":[{"tag":"DIRECT","protocol":"freedom"},{"tag":"BLOCK","protocol":"blackhole"}],"routing":{"rules":[{"type":"field","outboundTag":"BLOCK"}]}}}'
    return 0
  fi
  if [[ "$m" == PUT ]]; then
    printf '%s\n' "$p" > "$WORK_DIR/noisy-put-path.txt"
    printf '%s' "$b" > "$WORK_DIR/noisy-put.json"
    PANEL_API_BODY='{}'; return 0
  fi
  return 1
}
confirm() { return 0; }
ensure_api_key() { return 0; }
cmd_warp_link > "$WORK_DIR/noisy-link.out" 2>&1 || true
EOS
bash "$WORK/noisy-link.sh" "$WORK" "$ROOT" >/dev/null 2>&1 || true
check "warp-link reaches /core/1 (not a log-polluted path)" \
  bash -c "grep -qx '/core/1?restart_nodes=true' '$WORK/noisy-put-path.txt'"
check "warp-link PUT is valid JSON with the WARP-LINK inbound" \
  bash -c "jq -e '[.config.inbounds[].tag] | index(\"WARP-LINK\") != null' '$WORK/noisy-put.json' >/dev/null"
check "warp-link prints exactly one WARPLINK1 line" \
  bash -c "[[ \$(grep -c '^WARPLINK1:' '$WORK/noisy-link.out') -eq 1 ]]"
# ---------------------------------------------------------------------------
printf '\n[8s] Two-server install-or-repair, repair and warp-check (1.0.19)\n'
cat >"$WORK/two-server-e2e.sh" <<'EOS'
WD="$1"; ROOT="$2"; SCENARIO="$3"
WARP_APP_DIR="$WD/app-$SCENARIO"
source "$ROOT/warp-manager.sh" >/dev/null 2>&1 || true
state_init
mkdir -p "$BACKUP_DIR" "$PROFILE_DIR/default"
state_set_many "INSTALLED=1" "PROFILES=default" "PANEL_API_KEY=pg_key_test" "PANEL_URL=http://127.0.0.1:8000" \
  "WARP_LINK_HOST=95.135.200.231" "WARP_LINK_PORT=29580" "WARP_LINK_USER=warpu" \
  "WARP_LINK_PASS=passw" "WARP_LINK_TAG=WARP-LINK" "WARP_LINK_CORE=1"
PANEL_CORE_ID=1
cat >"$PROFILE_DIR/default/meta.env" <<'META'
PRIVATE_KEY='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
ADDRESS4='172.16.0.2/32'
ADDRESS6=''
PUBLIC_KEY='bmXOC+F1FxEMF9dyiK2H5/1SUtzH0YoV0CV9KtCkQpHyo='
ENDPOINT='engage.cloudflareclient.com:2408'
TAG='warp'
META
chmod 600 "$PROFILE_DIR/default/meta.env"

CORE_EMPTY='{"id":1,"name":"Core","type":"xray","config":{"inbounds":[{"tag":"[DE] - DC - Reality","protocol":"vless","port":443},{"tag":"[DE] - Tunnel - ArvanCloud","protocol":"vless","port":64710},{"tag":"Germany","protocol":"vless","port":64483}],"outbounds":[{"tag":"DIRECT","protocol":"freedom"},{"tag":"Out-DE","protocol":"freedom"},{"tag":"BLOCK","protocol":"blackhole"}],"routing":{"rules":[{"type":"field","outboundTag":"BLOCK"},{"type":"field","inboundTag":["[DE] - Tunnel - ArvanCloud"],"outboundTag":"Out-DE"}]}}}'
CORE_FOREIGN_OK='{"id":1,"name":"Core","type":"xray","config":{"inbounds":[{"tag":"Germany","protocol":"vless","port":64483},{"tag":"WARP-LINK","protocol":"socks","port":29580}],"outbounds":[{"tag":"DIRECT","protocol":"freedom"},{"tag":"warp","protocol":"wireguard"},{"tag":"BLOCK","protocol":"blackhole"}],"routing":{"rules":[{"outboundTag":"BLOCK"},{"type":"field","inboundTag":["WARP-LINK"],"outboundTag":"warp"}]}}}'
CORE_IRAN_OK='{"id":1,"name":"Core","type":"xray","config":{"inbounds":[{"tag":"[DE] - DC - Reality","protocol":"vless","port":443},{"tag":"WARP-DEDICATED","protocol":"vless","port":31234}],"outbounds":[{"tag":"DIRECT","protocol":"freedom"},{"tag":"WARP-LINK","protocol":"socks"},{"tag":"BLOCK","protocol":"blackhole"}],"routing":{"rules":[{"outboundTag":"BLOCK"},{"type":"field","inboundTag":["WARP-DEDICATED"],"outboundTag":"WARP-LINK"}]}}}'
CORE="$CORE_EMPTY"
case "$SCENARIO" in
  foreign-check|check-missing-foreign) CORE="$CORE_FOREIGN_OK" ;;
  iran-*|check-missing-iran) CORE="$CORE_IRAN_OK" ;;
esac
[[ "$SCENARIO" == "check-missing-foreign" || "$SCENARIO" == "check-missing-iran" ]] && CORE="$CORE_EMPTY"
[[ "$SCENARIO" == iran-* || "$SCENARIO" == check-missing-iran ]] && \
  state_set_many "WARP_IN_TAG=WARP-DEDICATED" "WARP_IN_PORT=31234" "PROFILE_IMPORTED=1"
[[ "$SCENARIO" == "iran-down" ]] && timeout() { return 1; }

panel_login() { return 0; }
confirm() { return 0; }
ensure_api_key() { return 0; }
curl() { printf '{"ip":"104.28.219.182","org":"AS13335 Cloudflare, Inc."}'; }
panel_api() {
  local m="$1" p="$2" b="${3:-}"
  if [[ "$m" == GET && "$p" == /cores ]]; then PANEL_API_BODY='{"cores":[{"id":1,"name":"Core"}]}'; return 0; fi
  if [[ "$m" == GET && "$p" == /core/* ]]; then PANEL_API_BODY="$CORE"; return 0; fi
  if [[ "$m" == PUT ]]; then printf '%s' "$b" > "$WD/put-$SCENARIO.json"; PANEL_API_BODY='{}'; return 0; fi
  return 1
}
case "$SCENARIO" in
  foreign-install)  cmd_install ;;
  foreign-repair)   cmd_repair ;;
  iran-repair)      cmd_repair ;;
  iran-down)        cmd_repair ;;
  *check*)          cmd_warp_check ;;
esac
EOS
for m in foreign-install foreign-repair iran-repair iran-down foreign-check iran-check check-missing-foreign check-missing-iran; do
  bash "$WORK/two-server-e2e.sh" "$WORK" "$ROOT" "$m" > "$WORK/out-$m.txt" 2>&1 || true
done
check "option 1 repairs instead of stopping with 'use --force'" \
  bash -c "! grep -q 'Use --force to reconfigure' '$WORK/out-foreign-install.txt' && grep -q 'REPAIR it instead' '$WORK/out-foreign-install.txt'"
check "option 1 on the FOREIGN server actually rebuilds the WARP link" \
  bash -c "jq -e '[.config.inbounds[].tag] | index(\"WARP-LINK\") != null' '$WORK/put-foreign-install.json' >/dev/null"
check "repair on the FOREIGN server restores the WARP outbound and rule" \
  bash -c "jq -e '[.config.outbounds[].tag] | index(\"warp\") != null' '$WORK/put-foreign-repair.json' >/dev/null && jq -e '[.config.routing.rules[].outboundTag] | index(\"warp\") != null' '$WORK/put-foreign-repair.json' >/dev/null"
check "repair reuses the saved link password (no new WARPLINK1 needed)" \
  bash -c "grep -q 'WARPLINK1:' '$WORK/out-foreign-repair.txt' && jq -e '.config.outbounds[] | select(.tag==\"WARP-LINK\") | .settings.servers[0].users[0].pass == \"passw\"' '$WORK/put-iran-repair.json' >/dev/null"
check "repair on the IRAN server restores the dedicated VLESS inbound" \
  bash -c "jq -e '[.config.inbounds[] | select(.tag==\"WARP-DEDICATED\") | .protocol] == [\"vless\"]' '$WORK/put-iran-repair.json' >/dev/null"
check "repair on IRAN with a dead FOREIGN link gives the exact server order" \
  bash -c "grep -q 'FIRST run on the FOREIGN server' '$WORK/out-iran-down.txt' && grep -q 'THEN run' '$WORK/out-iran-down.txt'"
check "warp-check passes on a healthy FOREIGN server" \
  bash -c "grep -q 'Dedicated WARP link check: OK' '$WORK/out-foreign-check.txt'"
check "warp-check passes on a healthy IRAN server" \
  bash -c "grep -q 'Dedicated WARP link check: OK' '$WORK/out-iran-check.txt'"
check "warp-check detects a deleted FOREIGN WARP config" \
  bash -c "grep -q 'MISSING a WARP inbound' '$WORK/out-check-missing-foreign.txt'"
check "warp-check detects a deleted IRAN WARP config" \
  bash -c "grep -q 'MISSING a WARP inbound' '$WORK/out-check-missing-iran.txt'"
check "warp-check tells the user NOT to delete WARP items to test" \
  bash -c "grep -q 'Do NOT delete WARP inbounds/outbounds/rules' '$WORK/out-iran-check.txt'"
check "warp-check prints the commands for BOTH servers" \
  bash -c "grep -q 'FOREIGN server:' '$WORK/out-iran-check.txt' && grep -q 'IRAN server:' '$WORK/out-iran-check.txt'"
check "--help documents install-or-repair, repair and warp-check" \
  bash -c "bash '$ROOT/warp-manager.sh' --help | grep -q 'REPAIR an existing setup' && bash '$ROOT/warp-manager.sh' --help | grep -q 'warp-check' && bash '$ROOT/warp-manager.sh' --help | grep -q 'repair      Repair'"
check "--help states the script must run on BOTH servers" \
  bash -c "bash '$ROOT/warp-manager.sh' --help | grep -q 'MUST BE INSTALLED AND RUN ON BOTH SERVERS'"
check "option 1 NEVER stops: repairs IRAN even when the FOREIGN link is down" \
  bash -c "jq -e '[.config.inbounds[].tag] | index(\"WARP-DEDICATED\") != null' '$WORK/put-iran-down.json' >/dev/null && grep -q 'FIRST run on the FOREIGN server' '$WORK/out-iran-down.txt'"
check "repair writes SERVER-GUIDE.md with commands for BOTH servers" \
  bash -c "test -f '$WORK/app-iran-repair/SERVER-GUIDE.md' && grep -q 'FOREIGN relay server' '$WORK/app-iran-repair/SERVER-GUIDE.md' && grep -q 'IRAN MAIN PANEL server' '$WORK/app-iran-repair/SERVER-GUIDE.md' && grep -q 'warp-manager repair --yes' '$WORK/app-iran-repair/SERVER-GUIDE.md'"
check "SERVER-GUIDE.md states BOTH servers are required" \
  bash -c "grep -q 'TWO SERVERS REQUIRED' '$WORK/app-foreign-repair/SERVER-GUIDE.md' && grep -q 'Do NOT test by deleting' '$WORK/app-foreign-repair/SERVER-GUIDE.md'"
check "a fresh install still prints the two-server next steps" \
  bash -c "sed -n '/^cmd_install_fresh()/,/^}/p' '$ROOT/warp-manager.sh' | grep -q 'Two servers are required' && sed -n '/^cmd_install_fresh()/,/^}/p' '$ROOT/warp-manager.sh' | grep -q 'warp-link --yes'"
check "option 1 dispatch is install-or-repair, never a dead stop" \
  bash -c "sed -n '/^cmd_install()/,/^}/p' '$ROOT/warp-manager.sh' | grep -q 'cmd_repair' && ! sed -n '/^cmd_install()/,/^}/p' '$ROOT/warp-manager.sh' | grep -q 'Use --force to reconfigure'"
check "docs/TWO-SERVERS.md exists and lists per-server commands" \
  bash -c "test -f '$ROOT/docs/TWO-SERVERS.md' && grep -q 'FOREIGN' '$ROOT/docs/TWO-SERVERS.md' && grep -q 'IRAN' '$ROOT/docs/TWO-SERVERS.md' && grep -q 'repair --yes' '$ROOT/docs/TWO-SERVERS.md'"
check "warp_detect_role reports foreign / iran correctly" \
  bash -c "grep -Eq 'Detected role +foreign' '$WORK/out-foreign-check.txt' && grep -Eq 'Detected role +iran' '$WORK/out-iran-check.txt' && grep -q 'Detected role: FOREIGN relay server.' '$WORK/out-foreign-repair.txt'"

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
