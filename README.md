# Warp-Pasarguard

A ready-to-install, menu-driven Bash tool that deploys **Cloudflare WARP** on a
**PasarGuard** panel / node infrastructure, generates the exact Core Settings
JSON the panel expects, and can push it through the PasarGuard API.

All script output, menus, logs, generated configs and documentation are in
**English**.

> Based on the official guide: <https://docs.pasarguard.org/en/learn/warp/>

---

## Table of contents

1. [Which server should run this script?](#1-which-server-should-run-this-script)
2. [Your topology, mapped to WARP](#2-your-topology-mapped-to-warp)
3. [Quick start](#3-quick-start)
4. [The menu](#4-the-menu)
5. [Backends](#5-backends)
6. [Multi-IP / multi-location (NL, DE, PL)](#6-multi-ip--multi-location-nl-de-pl)
7. [Panel configuration](#7-panel-configuration)
8. [Routing scopes](#8-routing-scopes)
9. [Non-interactive usage](#9-non-interactive-usage)
10. [Files and paths](#10-files-and-paths)
11. [Safety notes](#11-safety-notes)
12. [Update and removal](#12-update-and-removal)
13. [Requirements](#13-requirements)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. Which server should run this script?

**This is the single most important question.** WARP must be applied at the
point where the traffic **leaves the server toward the Internet** (the egress /
exit point). It is *not* necessarily the server that holds the users, and it is
*not* necessarily the server that hosts the panel database.

```
[ Clients ]
    |
    v
[ IRAN : MAIN PANEL ]  ---- node / tunnel link ---->  [ FOREIGN NODE : NL / DE / PL ]
  users, configs,                                      3 public IPs, 3 location outbounds
  Core Settings, DB                                   |
                                                       v
                                                  PUBLIC INTERNET
                                                  ^^^ WARP belongs HERE
```

| Config type in your panel | Where the traffic exits | Where WARP must take effect |
| --- | --- | --- |
| `tunnel` (Iran -> foreign node -> Internet) | **Foreign node (NL/DE/PL)** | **Foreign node** |
| `direct` (Iran -> Internet) | Iran server | Iran server (only if you want to cover it) |
| `cdn` (Iran -> CDN edge -> Internet) | CDN edge / foreign origin | WARP on the foreign node has a limited effect; WARP on the Iran server changes only the Iran leg |

### Practical answer for this setup

- For your **`tunnel` configs, run the script on the FOREIGN server**
  (the one with the three IPs). That is the machine whose Xray process
  actually opens the connection to Google / OpenAI / Spotify.
- The **Core Settings JSON lives on the MAIN panel in Iran**, but it is
  *executed* by the node. This is why the official guide says:
  - *Xray WireGuard backend*: no changes are needed on the node, the panel
    pushes the outbound automatically. The node container still needs
    `/dev/net/tun` access, which this tool patches in its `docker-compose.yml`.
  - *Kernel WireGuard backend (`wg-quick`)*: step 3 must be repeated **on the
    node**, i.e. the `/etc/wireguard/warp.conf` interface must exist on the
    foreign server too.
- Running the script **only on the Iran panel** will not change anything for
  the `tunnel` configs, because those connections never originate from Iran.
- Running the kernel backend on the Iran server is possible, but that server
  hosts the main panel and all users, so prefer the Xray backend there, or
  leave it alone.

The installer prints this guidance on screen and asks you to pick the target
(`exit`, `panel`, or `generator`). `generator` only produces the panel JSON
snippets and touches nothing on the host.

---

## 2. Your topology, mapped to WARP

You have one foreign server with three public IPs geolocated in the
Netherlands, Germany and Poland, three matching outbounds in the panel, and an
Iran main panel connected to that server through a node (your "tunnel").

Recommended deployment:

```
Foreign server (NL/DE/PL)          Iran server (MAIN PANEL)
--------------------------------  ---------------------------------------
warp-manager install                (nothing to install for tunnel configs)
  --mode xray                      Core Settings <- paste/apply generated JSON
  --target exit                    Panel API <- optional auto-apply
  --binding per-ip                 Users: cdn / direct / tunnel configs
docker-compose.yml patched
Xray outbound warp-nl / warp-de / warp-pl
```

With `--binding per-ip` the tool creates one WARP account per source IP and
sets Xray's `sendThrough` to that IP, so each tunnel leaves from its own
address. Cloudflare then selects the nearest point of presence for each source,
which keeps the three locations meaningful instead of collapsing them into a
single WARP egress. See [section 6](#6-multi-ip--multi-location-nl-de-pl).

A WARP account allows a maximum of **5 simultaneous devices** (official docs).
One account per IP plus a spare account is a good pattern for busy panels.

---

## 3. Quick start

```bash
# One-line bootstrap (installs /usr/local/bin/warp-manager)
curl -fsSL "https://raw.githubusercontent.com/XiliService/Warp-Pasarguard/main/install.sh?v=$RANDOM" | sudo bash

# Or from a local clone
sudo ./install.sh

# Open the numbered menu
sudo warp-manager
```

The bootstrap verifies the downloaded script with `bash -n` before installing
it, and keeps a copy in `/opt/pasarguard-warp/`.

If `main` is not yet available (for example while working on a feature
branch):

```bash
curl -fsSL "https://raw.githubusercontent.com/XiliService/Warp-Pasarguard/arena/01417195-warp-pasarguard/install.sh?v=$RANDOM" \
  | sudo bash -s -- --branch arena/01417195-warp-pasarguard
# or install fully offline from a clone:
sudo ./install.sh --local ./warp-manager.sh --no-menu
```

`raw.githubusercontent.com` is CDN-cached for a few minutes after a push. For
a guaranteed-fresh copy use the GitHub API raw endpoint instead (no auth
needed for a public repo):

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw' \
  'https://api.github.com/repos/XiliService/Warp-Pasarguard/contents/install.sh?ref=arena/01417195-warp-pasarguard' \
  | sudo bash -s -- --branch arena/01417195-warp-pasarguard
```

The installer itself tries `api.github.com` first (never CDN-cached), then the
raw CDN mirrors, and adds a cache-buster to every URL. `install.sh` works both
from a file and when streamed with `curl | bash -s` (where `BASH_SOURCE[0]` is
unset).

---

## 4. The menu

```
========================================================================
  PasarGuard WARP Manager  v1.0.15
========================================================================
  Host             ...
  Role             node | panel | panel+node | unknown
  Primary IP       ...
  Global IPs       3
  Installation     active (xray / exit)
------------------------------------------------------------------------

Main menu - select an option:
  1) Install / Configure WARP
  2) Remove / Uninstall WARP
  3) Update Script
  4) View Logs
  5) Status / Health Check
  6) Exit
```

| # | Option | What it does |
| --- | --- | --- |
| 1 | Install / Configure WARP | Wizard: target, backend, IP binding, routing scope, license key, endpoint; installs `wgcf`, registers WARP account(s), writes `/etc/wireguard` or patches Docker, generates panel JSON, optionally applies it via API |
| 2 | Remove / Uninstall WARP | Stops interfaces, restores `docker-compose.yml` from backup, removes WARP outbound/rules from the panel via API (if configured), deletes local profiles |
| 3 | Update Script | Downloads the newest `warp-manager.sh`, validates syntax, backs up the old one, installs atomically (`--check` only compares) |
| 4 | View Logs | Manager log, live log, `journalctl` for `wg-quick@*`, Docker compose logs, `wgcf status`, generated snippets |
| 5 | Status / Health Check | Environment, role, Xray version, TUN device, profiles, `Table = off` audit, WireGuard handshake age, panel snippets, Cloudflare `cdn-cgi/trace` through the WARP interface, overall health |

Every command is also available non-interactively (`warp-manager install`,
`warp-manager remove`, ...). Two extra CLI-only commands avoid a reinstall
when only the panel config needs to change:

```bash
sudo warp-manager apply --panel-url https://panel.example.com \
  --panel-user admin --panel-pass 'secret' --core-id 1 --yes
sudo warp-manager unapply --panel-url https://panel.example.com \
  --panel-user admin --panel-pass 'secret' --core-id 1 --yes
```

`apply` also re-checks `/dev/net/tun` on **every** node container on the host
(`out-node`, `main-node`, ...), then pushes the already-generated snippets into
Core Settings (useful when the API login failed during the first install).
`unapply` removes them. `warp-manager fix-compose --yes` only re-runs the TUN
part without touching the panel.

If the dashboard domain is not reachable from the VPS itself, use
`--insecure` (skips TLS verification) and check the printed curl error
(DNS / TLS / firewall). A panel container running on the same host can be
used explicitly with `--allow-local-panel`; the manager also discovers its
ports and prints them. Re-running `apply` never restarts node containers that
are already patched.

---

## 5. Backends

### `xray` (recommended)

Uses the native Xray `wireguard` outbound, as in the official guide. Requires
**Xray >= 1.8.3** (older builds have known memory leaks).

Generated outbound (abridged):

```json
{
  "tag": "warp",
  "protocol": "wireguard",
  "sendThrough": "203.0.113.10",
  "settings": {
    "secretKey": "<from wgcf-profile.conf>",
    "DNS": "1.1.1.1",
    "address": ["172.16.0.2/32", "2606:4700:110:.../128"],
    "peers": [{
      "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
      "endpoint": "engage.cloudflareclient.com:2408",
      "allowedIPs": ["0.0.0.0/0", "::/0"]
    }],
    "kernelMode": false,
    "mtu": 1280
  }
}
```

`--modern-xray` additionally emits `noKernelTun: true` and `remoteDNS` for
recent Xray releases that renamed those keys (unknown keys are ignored by
older builds, so both forms are safe).

Docker node containers need TUN permissions; the tool adds this to the node
service in `docker-compose.yml` (after a timestamped backup):

```yaml
    devices:
      - /dev/net/tun:/dev/net/tun
    security_opt:
      - seccomp=unconfined
      - systempaths=unconfined
      - apparmor=unconfined
```

### `kernel`

Creates `/etc/wireguard/warp.conf` (or `warp-<label>.conf` in per-IP mode),
enables `wg-quick@warp`, and generates a `freedom` outbound bound to that
interface:

```json
{
  "tag": "warp",
  "protocol": "freedom",
  "streamSettings": { "sockopt": { "tcpFastOpen": true, "interface": "warp" } }
}
```

**`Table = off` is mandatory** (the official guide warns that forgetting it
cuts off SSH access). The tool always writes it, verifies it in `status`, and
compares the default route before/after setup, rolling back automatically if
it changed. The `DNS =` line is intentionally omitted so `wg-quick` does not
overwrite the server's resolver.

The official guide explicitly requires repeating this step on the **node**.

---

## 6. Multi-IP / multi-location (NL, DE, PL)

`--binding per-ip` (or menu option 3) detects every global IPv4 on the host,
asks for a short label for each (`nl`, `de`, `pl`), and produces:

| Label | Source IP | WARP account | Outbound tag | Interface (kernel mode) | Endpoint (kernel mode) |
| --- | --- | --- | --- | --- | --- |
| nl | IP 1 | separate | `warp-nl` | `warp-nl` | distinct Cloudflare IP |
| de | IP 2 | separate | `warp-de` | `warp-de` | distinct Cloudflare IP |
| pl | IP 3 | separate | `warp-pl` | `warp-pl` | distinct Cloudflare IP |

- **Xray backend**: each outbound gets `sendThrough: <IP>`. Xray's WireGuard
  dialer uses that address as the source of the UDP socket toward Cloudflare.
- **Kernel backend**: each `warp-<label>.conf` gets a reversible
  `PostUp`/`PreDown` host route with `src <IP>` toward a **distinct** numeric
  Cloudflare endpoint, so the three WireGuard sockets do not fight over the
  same route. The main routing table is otherwise untouched.
- A random `routing.balancers` pool named `warp-pool` spreads the matching
  traffic over the three outbounds. If you prefer deterministic mapping,
  replace it with three rules scoped by `inboundTag` (see
  [`docs/PANEL-CONFIG.md`](docs/PANEL-CONFIG.md)).

`--binding single` (default) creates one account and one `warp` outbound. This
is simpler and is the right choice when you only need WARP for a handful of
domains rather than for a location-aware product.

---

## 7. Panel configuration

The tool never edits the panel database unless you explicitly enable the API
integration. Two paths are available:

### Manual (default)

Files appear in `/opt/pasarguard-warp/outbound/`:

| File | Destination in Core Settings |
| --- | --- |
| `outbounds.json` | `outbounds[]` |
| `routing-rules.json` | top of `routing.rules[]` |
| `balancers.json` | `routing.balancers[]` (per-IP mode only) |
| `README.txt` | exact paste order and warnings |
| `core-config-preview.json` | preview of the merged config when the API is used |

### API (optional)

```bash
sudo warp-manager install \
  --mode xray --target exit --binding per-ip \
  --panel-url https://panel.example.com \
  --panel-user admin --panel-pass 'secret' \
  --core-id 1 --yes
```

The tool uses the real panel endpoints:

| Step | Request |
| --- | --- |
| Login | `POST /api/admin/token` (form `username` / `password`) |
| List cores | `GET /api/cores` |
| Read core | `GET /api/core/{id}` |
| Write core | `PUT /api/core/{id}?restart_nodes=true` |

Before writing it saves a full backup of the core config to
`/opt/pasarguard-warp/backups/`, shows a diff summary, and asks for
confirmation. Merging is idempotent: existing objects tagged `warp*` and
rules pointing at `warp*` / `warp-pool` are replaced, everything else is kept.
`remove` performs the inverse operation.

Credentials are read from flags / environment variables and are never written
to disk. Use `--insecure` only for self-signed panel certificates.

> The panel API is reached from the machine running the script. If the script
> runs on the foreign node, use a panel URL reachable from that node, or run
> with `--no-apply-panel` and paste the snippets manually.

---

## 8. Routing scopes

`--routing domains` (default) adds one rule at the top of `routing.rules`:

```json
{
  "type": "field",
  "outboundTag": "warp",
  "domain": ["geosite:google", "openai.com", "ai.com",
             "ipinfo.io", "iplocation.net", "spotify.com"]
}
```

Override with `--domains geosite:google,geosite:openai,spotify.com`.

`--routing all` adds no rule and places the WARP outbound **first** in the
`outbounds` array, making it the default outbound for unmatched traffic. Use
this carefully: it also changes traffic generated by the node itself.

---

## 9. Non-interactive usage

```bash
# Recommended for the described topology (3 IPs -> 3 WARP accounts)
sudo warp-manager install --mode xray --target exit --binding per-ip \
  --labels nl,de,pl --yes

# Simple single-tunnel install on the exit node
sudo warp-manager install --mode xray --target exit --yes

# Kernel WireGuard bound to one specific IP
sudo warp-manager install --mode kernel --target exit --ip 203.0.113.10 --yes

# Only generate panel snippets, change nothing on the host
sudo warp-manager install --mode xray --target generator --dry-run

# WARP+ and a custom domain list
sudo warp-manager install --license 'XXXX-XXXX-XXXX' \
  --domains 'geosite:google,geosite:openai,spotify.com' --yes

# Diagnostics
warp-manager status
sudo warp-manager logs --lines 200
sudo warp-manager logs --follow
sudo warp-manager update --check
sudo warp-manager remove
```

`--dry-run` prints the complete plan and exits without touching the system.
`--yes` fills sensible defaults (target `exit`, backend `xray`, labels
`loc1..locN`) instead of prompting.

---

## 10. Files and paths

| Path | Purpose |
| --- | --- |
| `/usr/local/bin/warp-manager` | Symlink to the installed script |
| `/opt/pasarguard-warp/warp-manager.sh` | Installed copy (updated by option 3) |
| `/opt/pasarguard-warp/state.env` | Persisted settings (mode, target, profiles, ...) |
| `/opt/pasarguard-warp/profiles/<name>/` | `wgcf-account.toml`, `wgcf-profile.conf`, `meta.env` (mode 0600) |
| `/opt/pasarguard-warp/outbound/` | Generated JSON snippets for the panel |
| `/opt/pasarguard-warp/backups/` | Timestamped compose / script / panel-core backups |
| `/opt/pasarguard-warp/logs/warp-manager.log` | Manager log |
| `/opt/pasarguard-warp/bin/wgcf` | Pinned `wgcf` binary (SHA-256 verified against the release checksums) |
| `/etc/wireguard/warp*.conf` | Kernel backend interfaces (`Table = off`) |
| `/opt/pg-node/docker-compose.yml` | Node compose file, patched for TUN access |
| `/opt/pasarguard/docker-compose.yml` | Panel compose file (detected on the Iran server) |

---

## 11. Safety notes

- **`Table = off`** is written into every kernel interface and audited by
  `status`. Without it `wg-quick` replaces the default route and SSH is lost.
- The installer snapshots the default route and rolls back automatically if
  it changes. An `ERR`/`EXIT` trap stops any interface it created on failure.
- Every modified file (`docker-compose.yml`, core config, old script) is
  backed up before being touched.
- `wgcf` binaries are checked against the release `checksums.txt` when
  available; a mismatch aborts the install.
- WARP accounts are stored with mode `0600`/`0700` (private keys).
- `remove` never deletes an arbitrary outbound: it only removes objects whose
  tag starts with `warp` and rules that reference them or `warp-pool`.

---

## 12. Update and removal

```bash
sudo warp-manager update          # download, validate, back up, replace
sudo warp-manager update --check  # compare only
sudo warp-manager remove          # remove WARP, keep the manager
```

`update` tries `main` first, then the fallback branch, then a `github.com` raw
mirror for each. Override with `WARP_BRANCH`, `WARP_UPDATE_URL` or `--url`.
State, profiles and backups survive updates.

After `remove`, delete the outbound/rules manually in Core Settings if the API
integration was not used.

---

## 13. Requirements

- Debian / Ubuntu with `systemd`, `apt-get`, root access
- `bash >= 4`, `curl` (or `wget` for the bootstrap), `jq`, `iproute2`
- `wireguard-tools` for the kernel backend (installed automatically)
- Docker + Docker Compose for a containerised panel / node
- Xray >= 1.8.3 for the Xray backend
- Outbound access to `github.com` (wgcf binary) and `api.github.com`

---

## 14. Troubleshooting

| Symptom | Check |
| --- | --- |
| SSH dropped after kernel install | Use the datacenter console, run `sudo systemctl disable --now wg-quick@warp`; verify `Table = off` in `/etc/wireguard/warp.conf` |
| `warp=off` on `cdn-cgi/trace` | `warp-manager status` -> handshake age; `warp-manager logs` -> `journalctl -u wg-quick@warp`; check UDP/2408 is not blocked |
| Xray outbound fails inside Docker | Confirm `devices: /dev/net/tun` and the three `security_opt` entries, then recreate the container (`docker compose up -d`) |
| `sendThrough` seems ignored | Verify the source IP with `tcpdump -ni eth0 udp port 2408`; on older Xray builds switch to `--mode kernel` with per-IP binding |
| `wgcf register` fails | Cloudflare API unreachable / rate limited; retry, or use the interactive option to supply a WARP+ license |
| Panel API returns 401/403 | Admin needs `cores:read` and `cores:update` permissions; check `PANEL_URL` and SSL |
| Panel API returns 404 | The docs/API may be disabled or the URL needs the dashboard prefix; use `--no-apply-panel` and paste manually |
| Only `tunnel` configs work | Expected: WARP on the foreign node covers only traffic that exits there. `direct`/`cdn` configs need their own deployment |

See also [`docs/STEP-BY-STEP.md`](docs/STEP-BY-STEP.md) (complete beginner
walkthrough), [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md),
[`docs/PANEL-CONFIG.md`](docs/PANEL-CONFIG.md) and
[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

When the panel API is not reachable at all, skip it: `warp-manager snippets`
prints the exact JSON to paste into Core Settings, and
`warp-manager mark-applied --yes` records that the manual step is done.

---

## API key (recommended way to apply Core Settings)

Create a key in **Panel -> API Keys** with `cores:read` + `cores:update`
permissions (or "inherit permissions" on an owner account). It looks like
`pg_key_<uuid>`. The manager sends it as `X-Api-Key`; it never calls
`/api/admin/token`, so a broken login/404 on that route is irrelevant.

```bash
sudo warp-manager apply --panel-key pg_key_... --yes
```

The panel URL is optional: the manager probes the configured URL, the ports of
any local `pasarguard/panel` container, and common local ports, then uses the
first endpoint that returns a valid `/api/cores` response. The key is stored in
`/opt/pasarguard-warp/state.env` (mode 0600) for later `apply` / `unapply`.

## Ordering rules (important)

* **Outbounds:** the FIRST outbound is Xray's default for unmatched traffic.
  The manager keeps `DIRECT` first and inserts `warp` after the location
  outbounds but BEFORE any `BLOCK`/`blackhole` outbound (unless `routing=all`).
* **Routing rules:** Xray evaluates top-down and the FIRST match wins. The
  WARP domains rule must be ABOVE catch-all inbound rules such as
  `Germany -> Out-DE`; otherwise those rules win and WARP is never used.
  Leading `BLOCK`/security rules stay above the WARP rule.

---

## Full backup (automatic before every install / remove)

`warp-manager install` and `warp-manager remove` take a full snapshot first,
so a mistake is always reversible:

```bash
sudo warp-manager backup                       # take one explicitly
sudo warp-manager restore /opt/pasarguard-warp/backups/full-...   # files
```

Each backup contains:

* panel files (`/opt/pasarguard`, `/var/lib/pasarguard`, `.env`, certs),
* node directories (`/opt/out-node`, `/opt/main-node`, `/var/lib/pg-node`),
* `/etc/wireguard` and `/opt/pasarguard-warp` (profiles, keys, snippets),
* a **database dump** via `pg_dumpall` (or `pg_dump` / SQLite copy),
* resolved `docker compose config` output for every node,
* every Core configuration as JSON (when an API key is available),
* `MANIFEST.txt`, `RESTORE.md` and a standalone `restore.sh`.

`RESTORE.md` contains the exact `psql` command for the database step.
Backups are **never deleted** by `remove`, and the manager script is kept so
`restore` stays available after a full uninstall.

## Dedicated API key (created once, reused forever)

```bash
sudo warp-manager key
```

The manager asks for the admin username/password **once**, gets a session,
creates a key named `warp-manager` with inherited permissions via
`POST /api/api_key`, and stores the raw `pg_key_...` in `state.env` (0600).
On every later install/apply/update it verifies that key with a read-only
`GET /api/cores` and reuses it. Only if the key is missing or invalid does it
create a new one (stale dedicated keys are removed first).

You can skip the credentials entirely by passing an existing key:
`--panel-key pg_key_...`. Env admins (`SUDO_USERNAME`) cannot create API keys;
use a real owner/admin account or provide the key manually.

---

## Zero-credential key creation (1.0.9)

`warp-manager key`, `install` and `apply` no longer need you to paste a key or
even type an admin password when the panel database runs on the same host:

1. Reuse the saved `warp-manager` key (verified with a read-only `/api/cores`).
2. Otherwise try the official `POST /api/api_key` with admin credentials, if
   they are supplied (the password is never stored).
3. Otherwise insert exactly one row into `api_keys` via `docker exec psql`,
   using the panel's own documented `key_hash` format
   (`v1$<b64url(sha256[:16])>$sha256$<sha256hex>`), then verify the new key
   with `GET /api/cores` before using it.

The key is stored in `state.env` (0600) and reused by every later version.
Stale dedicated keys are removed before a new one is minted. A full backup is
recommended first: `sudo warp-manager backup`.

`remove --yes` keeps the `warp-manager` command by default; pass
`--uninstall-manager` only if you really want it gone.

## After a remove + reinstall

A reinstall registers a NEW WARP account, so the `warp` outbound you pasted
earlier contains an OLD private key. Run `sudo warp-manager apply --yes` once:
it rewrites the Core config with the current key, restores the correct
outbound/rule order, and keeps `DIRECT` first.

---

## Panel discovery when no host port is published (1.0.10)

Some PasarGuard deployments run the panel API inside a Docker network with no
published port, so `127.0.0.1:8000` and the domain both fail. `apply` now:

1. Reads `UVICORN_PORT` from the panel container's environment.
2. Probes the container's Docker bridge IP on common internal ports.
3. Falls back to `nsenter` into the panel container's network namespace, so
   `127.0.0.1:<port>` reaches the panel's own loopback even with no published
   port. The chosen container and transport are saved in `state.env` and reused
   by later runs.

`install_packages` now installs `util-linux` when `nsenter` is missing. If all
probes still fail, `apply` prints every URL it tried plus `docker ps` output so
the remaining problem is visible in the log.

Overrides: `WARP_PANEL_CONTAINER=NAME` and `WARP_PANEL_TRANSPORT=nsenter`.

---

## Reaching the panel API from inside its container (1.0.11)

PasarGuard has three official binding modes (`config.py` / `main.py`):

| Env | Listener | Why host probes fail |
| --- | --- | --- |
| `UVICORN_UDS` | Unix socket (no TCP at all) | Nothing listens on any port |
| `UVICORN_SSL_CERTFILE` + `KEYFILE` | HTTPS on `0.0.0.0:UVICORN_PORT` | Plain HTTP probes get no reply |
| neither | HTTP on `127.0.0.1:UVICORN_PORT` only | Bridge IP and host loopback cannot reach it |

`apply` now tries, in order:

1. Configured / saved URL, Docker-published ports, container bridge IPs, and
   common local ports.
2. Public domains from `VITE_BASE_API` / `PASSKEY_ORIGIN` / `ALLOWED_ORIGINS`,
   the host FQDN/IP, and `server_name` entries in nginx/Caddy configs.
3. **curl executed inside the panel container** (`docker exec`), using
   `UVICORN_UDS`, HTTPS on the TLS port, or HTTP on loopback. The official
   panel image ships curl for its own healthcheck, so this works even with a
   Unix socket. The chosen transport is saved to `state.env` and reused.
4. `nsenter` into the container's network namespace as a final fallback.

Failures now log every URL tried, the panel container's `UVICORN_*` values,
and the first HTTP reply received (not just the last network error).

Overrides: `WARP_PANEL_EXEC_UDS`, `WARP_PANEL_EXEC_SCHEME`,
`WARP_PANEL_EXEC_HOST`, `WARP_PANEL_EXEC_PORT`.

---

## Why an added WARP outbound can break every config (1.0.12)

Symptom: after `apply`, every client config shows `ping -1`; deleting the
`warp` outbound and its routing rule immediately restores them. The order was
correct - the outbound itself was the problem.

Xray's `wireguard` outbound has two modes. `KernelTunSupported()` returns true
as soon as the process has `CAP_NET_ADMIN`. Our compose patch adds exactly that
capability for `/dev/net/tun`, so with the legacy `kernelMode: false` field
(which recent Xray builds ignore) Xray defaults to **kernel TUN**: it creates a
kernel WireGuard link and installs addresses, routes, sysctls and policy
routing rules inside the node container. Those routes are global to the node and
hijack traffic for every other inbound, so all clients go down.

From 1.0.12 the generated outbound uses the current Xray schema:

```json
{
  "tag": "warp",
  "protocol": "wireguard",
  "settings": {
    "secretKey": "...", "address": ["172.16.0.2/32"],
    "peers": [{"publicKey": "...", "endpoint": "engage.cloudflareclient.com:2408",
               "allowedIPs": ["0.0.0.0/0", "::/0"]}],
    "mtu": 1280,
    "noKernelTun": true,
    "remoteDNS": ["1.1.1.1", "1.0.0.1"]
  }
}
```

`noKernelTun: true` selects Xray's built-in userspace TCP/IP stack. It needs no
kernel module, no TUN device, no NET_ADMIN, and cannot touch the node's routing
table. `--legacy-xray` restores the old fields for very old Xray builds only.

`apply` now also:

* Rebuilds `outbound/*.json` from the stored wgcf profile **every time**, so a
  script update fixes an already-installed deployment without reinstalling.
* Reads node health from `/api/nodes` before and after the change, and
  automatically PUTs the exact pre-apply Core config back if a node enters
  `error` state. `warp-manager unapply --yes` remains a manual rollback.

## The two PasarGuard cores

The `CoreType` enum is `xray | wg | mtproto | singbox`, and a panel may hold
several Core configs at once.

* **Xray core** (`Default Core Config`) - owns Inbounds, Outbounds, Routing,
  Balancers and DNS. This is the core the manager edits (core ID 1 in the
  default install).
* **WireGuard core** (`wg`) - a separate WireGuard **server** for clients. Its
  Interface tab (`wg0`, listen port 51820, `10.0.0.1/8`, private/public key)
  is the server-side tunnel that hands out client subnets. It is NOT the
  Cloudflare WARP client tunnel and must not be edited or deleted.

Cloudflare WARP here is a third thing: a single `wireguard` **outbound inside
the Xray core**, selecting which domains leave through Cloudflare. It does not
create a new panel core.

---

## Which server? (1.0.13 - corrected)

Run `warp-manager` on the **IRAN main panel server**, not on the foreign
egress relay.

The Iran Core config has 12 separate inbounds (`... CloudFlare - CDN`,
`... DC - Reality`, `... Tunnel - ArvanCloud`). The foreign relay core has only
4 inbounds (`Germany`, `NetherLands`, `Poland`, `SOCKS5`): all 12 user configs
are merged into those 3 location inbounds. A WARP rule on the foreign core
therefore applies to **every** user, which is why all configs dropped.

From 1.0.13 `apply`:

* Finds the `... Tunnel ...` inbound tags in the target Core config.
* Writes the WARP rule with `inboundTag: [those tags]` and **no** global
  `domain` catch-all, inserted just below the leading `BLOCK` rule.
* Refuses to apply to a Core config with no tunnel inbound (a shared egress
  relay), with an explicit English error. `--all-traffic` overrides it.
* Keeps the userspace `noKernelTun: true` WARP outbound, node-health check and
  automatic rollback.

The WARP decision still belongs on the Iran server, but from 1.0.15 the WARP
tunnel itself terminates on the foreign server; see "Dedicated WARP link" below.

See `docs/ARCHITECTURE.md` section 2.1 for the full two-core topology.

---

## Reusing a WARP account on a host that cannot reach Cloudflare (1.0.14)

`api.cloudflareclient.com` (the wgcf registration API) is often blocked on
Iranian hosts, so `install` fails there with a TLS handshake timeout. The
account can be created once on the foreign server and reused on the main panel
server:

```bash
sudo warp-manager export-profile                        # foreign server
sudo warp-manager import-profile 'WARP1:...'            # main panel server
```

**Important (1.0.15):** on hosts where the WireGuard UDP endpoint is also
filtered, do **not** run `apply` after importing: the WARP tunnel cannot be
established from Iran and the tunnel configs hang. Use the dedicated WARP link
below instead.

`export-profile` prints one `WARP1:<base64>` line containing only the profile
metadata (`meta.env` - private key, WARP addresses, peer public key, endpoint).
`import-profile` validates it, writes it with mode 0600, sets
`INSTALLED/MODE/ROUTING/PROFILES`, and regenerates the snippets. There is no
Cloudflare API call and no new WARP account. `create_profile()` now reuses any
existing valid `meta.env` instead of calling `wgcf register` again.

The install banner also no longer says "run on the foreign node"; it explains
the corrected two-Core topology from `docs/ARCHITECTURE.md` section 2.1.

---

## Dedicated WARP link (1.0.15)

WARP UDP to Cloudflare is filtered on Iranian hosts, so a `wireguard` outbound
in the Iran Core hangs the tunnel configs. WARP must terminate on the **foreign**
server, but a global rule there would capture every config (all 12 user configs
merge into 3 inbounds). A private SOCKS link solves both:

```bash
# FOREIGN server (has a working WARP profile):
sudo warp-manager update --yes
sudo warp-manager warp-link          # prints ONE WARPLINK1: line

# IRAN / MAIN PANEL server:
sudo warp-manager update --yes
sudo warp-manager warp-join 'WARPLINK1:...'
```

`warp-link` adds a private SOCKS inbound `WARP-LINK`, the userspace WARP
outbound (before `BLOCK`), and a routing rule scoped to that inbound only.
`warp-join` adds the matching SOCKS outbound (before `BLOCK`) and splits the
`... Tunnel - ArvanCloud` tags out of the existing location rules, so only
those configs use WARP. `cdn` / `direct` keep `Germany` / `NetherLands` /
`Poland` and the three foreign IPs.

Both commands take a Core backup first, are idempotent, and refuse to guess if
several Core configs exist without a tunnel/relay match. The `WARPLINK1:` line
contains the link password: keep it private.

`status` no longer reports "Account file missing" for an imported WARP profile.
