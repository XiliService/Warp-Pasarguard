# Troubleshooting

All checks below are available through `warp-manager status`,
`warp-manager warp-check` and `warp-manager logs`.

> **TWO SERVERS ARE REQUIRED.** The script must be installed and run on BOTH
> the FOREIGN relay and the IRAN main panel. Full per-server commands:
> [TWO-SERVERS.md](TWO-SERVERS.md) and
> `/opt/pasarguard-warp/SERVER-GUIDE.md` on each server.

## 1. SSH / server access lost after installing the kernel backend

Symptom: the session freezes right after `systemctl restart wg-quick@warp`.

Cause: `wg-quick` installed `0.0.0.0/0` into the main routing table because
`Table = off` was missing. This is the warning in the official PasarGuard
guide.

Recovery through the datacenter console (VNC / IPMI / rescue shell):

```bash
sudo systemctl disable --now wg-quick@warp
sudo ip route del 0.0.0.0/0 dev warp 2>/dev/null || true
sudo grep -n 'Table' /etc/wireguard/warp.conf   # must say: Table = off
```

Prevention: this tool always writes `Table = off`, records the default route
before setup, compares it afterwards, and rolls back automatically on any
change or error. `warp-manager status` explicitly audits the flag.

---

## 2. `cdn-cgi/trace` still shows the real server IP

Check in order:

1. `warp-manager status` -> is the installation active, and which backend?
2. Are you testing with a config that actually exits from the machine where
   WARP was installed? `tunnel` configs exit on the foreign node; `direct`
   configs exit in Iran. See `ARCHITECTURE.md`.
3. `routing.rules`: is the WARP rule present and above other catch-all rules?
4. `outbounds`: is the `warp` object present and is its tag spelled exactly
   as in the rule?
5. Xray backend: is `/dev/net/tun` exposed to the container, and was the
   container **recreated** (`docker compose up -d`, not `restart`)?
6. Kernel backend: `wg show warp latest-handshakes` should show a recent
   epoch; `journalctl -u wg-quick@warp -n 100` shows handshake errors.
7. UDP/2408 toward Cloudflare must be allowed by the host firewall and the
   datacenter. Some providers rate-limit or block WARP endpoints.

Verification command:

```bash
curl https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|loc|warp)='
```

Expected: `warp=on` (free) or `warp=plus` (WARP+), and a Cloudflare IP.

---

## 3. Xray reports errors for the WireGuard outbound

| Message | Cause / fix |
| --- | --- |
| `failed to create virtual tun interface` | `/dev/net/tun` missing inside the container; apply the compose patch and recreate the container |
| `invalid WireGuard secret key` | The key pasted into Core Settings is not the `PrivateKey` from `wgcf-profile.conf`; regenerate with `warp-manager install --force` |
| `failed to dial to dest` | DNS resolution of `engage.cloudflareclient.com` failed inside Xray, or UDP/2408 blocked. Use a numeric endpoint: `--endpoint 162.159.192.1:2408` |
| Memory growth over days | Xray older than 1.8.3; update Xray core (`pg-node core-update`) or switch to `--mode kernel` |
| Unknown `noKernelTun` / `remoteDNS` keys | Old Xray ignores unknown keys; generated config is still valid. Omit `--modern-xray` |

---

## 4. `sendThrough` / per-IP binding does not change the source IP

`sendThrough` is a general outbound field and Xray's WireGuard dialer honours
it through `internet.DialSystem`, but some older builds do not. Diagnose:

```bash
tcpdump -ni eth0 'udp port 2408' -nn
```

You should see one source IP per WARP account. If all packets use the primary
IP:

- upgrade Xray (`pg-node core-update`);
- or use `--mode kernel --binding per-ip`, which binds the source at the OS
  level with a `PostUp` host route and distinct Cloudflare endpoints;
- or fall back to `--binding single` and accept a single WARP egress.

Kernel per-IP mode requires a reachable default gateway; the tool detects it
and warns if the host route cannot be created.

---

## 5. `wgcf` problems

| Message | Fix |
| --- | --- |
| `Could not download wgcf` | Server cannot reach `github.com` / release assets; download manually and place the binary at `/opt/pasarguard-warp/bin/wgcf`, then rerun `--force` |
| `Checksum mismatch` | The download was corrupted or tampered with; the install aborts. Retry or set `--wgcf-version latest` |
| `register` fails / rate limited | Cloudflare's registration API is throttling the IP; wait and retry, or register on another machine and copy `wgcf-account.toml` into the profile directory |
| `warp=on` instead of `warp=plus` | Known Cloudflare bug for accounts that were previously connected. Register a fresh account, bind the license key, then generate immediately |
| Account device limit | A WARP account supports 5 devices. Create extra profiles (`--binding per-ip`) or re-register |

---

## 6. Panel API problems

| HTTP | Meaning |
| --- | --- |
| 401 | Wrong credentials or expired token. Check `PANEL_USER` / `PANEL_PASS` / `PANEL_TOKEN` |
| 403 | Admin lacks `cores:read` or `cores:update` permission; use a sudo admin |
| 404 | API docs disabled, wrong base URL, or a reverse-proxy path prefix. Use `--no-apply-panel` and paste the snippets manually |
| 422 | The Core payload shape differs (custom panel build). The tool keeps the original snapshot; restore it from `backups/` |
| TLS errors | Self-signed certificate: use `--insecure` (development only) |

The tool always saves `panel-core-<id>-<timestamp>.json` before writing, and
shows a diff summary with a confirmation prompt unless `--yes` is used.

---

## 7. Nothing happens for `cdn` / `direct` configs

Expected. WARP on the foreign node only affects traffic that leaves from the
foreign node. To cover `direct` configs, deploy WARP on the Iran server as a
separate installation (`--target panel`), preferably with the Xray backend,
and use a distinct tag (for example a separate Core config) so the two
deployments do not fight over the `warp` tag.

---

## 8. Useful commands

```bash
sudo warp-manager status
sudo warp-manager logs                 # log source submenu
sudo warp-manager logs --follow --lines 200
sudo journalctl -u wg-quick@warp -n 100 --no-pager
sudo wg show
sudo ip route show table main
sudo docker compose -f /opt/pg-node/docker-compose.yml logs --tail=100 node
sudo tcpdump -ni any 'udp port 2408' -nn
sudo warp-manager install --force      # re-register accounts and regenerate JSON
sudo warp-manager remove               # clean uninstall
```

---

## Panel API is unreachable from the VPS

`apply` now prints the exact curl error instead of a generic message, e.g.
`curl: (6) Could not resolve host` (DNS), `SSL certificate problem` (TLS) or
`Connection timed out` (firewall).

```bash
sudo warp-manager apply --panel-url https://panel.example.com \
  --panel-user admin --panel-pass 'PASSWORD' --yes --insecure
```

* `--insecure` disables TLS verification for self-signed certificates.
* If a `pasarguard/panel` container runs on the same host, `apply` lists its
  local endpoints. Add `--allow-local-panel` **only if that panel is the one
  that manages your users**.
* If the real panel is on another server that this VPS cannot reach, paste
  the generated `outbounds.json` and `routing-rules.json` into Core Settings
  from your browser instead.

---

## Manual paste (works when the panel API is unreachable)

An `HTTP 404` from `/api/admin/token` means the URL is not the panel API root
- it is not a password problem. Stop using the API and paste the snippets:

```bash
sudo warp-manager snippets
```

1. Copy the objects from `outbounds.json` into the `outbounds` array of the
   Core used by the **EXIT NODE**, after the existing first outbound.
2. Copy the objects from `routing-rules.json` to the TOP of `routing.rules`.
3. `balancers.json` is empty in single mode - nothing to paste.
4. Save, then tell the manager the manual step is done:

```bash
sudo warp-manager mark-applied --yes
sudo warp-manager status
```

---

## `ipinfo.io` still shows the server IP after adding WARP

Almost always a **rule order** problem. Inbound-based catch-all rules
(`Germany -> Out-DE`, `NetherLands -> Out-NL`, ...) have no domain filter, so
they match first and the WARP domains rule at the bottom is never reached.

* Move the WARP rule ABOVE those rules (keep any leading BLOCK rule above it).
* Check the outbound list too: `DIRECT` must remain first; `warp` belongs after
  the location outbounds and before `BLOCK`.

`warp-manager apply --panel-key pg_key_... --yes` rewrites both lists in the
correct order automatically and backs up the core config first.

---

## Need to roll back?

Every `install` and `remove` writes a full backup under
`/opt/pasarguard-warp/backups/full-*/`. Run
`warp-manager restore <dir>` for files and follow `RESTORE.md` for the
PostgreSQL/SQLite dump. Core Settings are also saved individually as
`panel-core-<id>-*.json` before every API apply.

---

## `warp-manager key` / `apply` says it cannot create a key

* Make sure a PostgreSQL container (`timescale`/`postgres`) is running and the
  script runs as root/sudo - the automatic fallback writes one row via
  `docker exec ... psql`.
* Take a backup first: `sudo warp-manager backup`.
* If you prefer the official route, pass `--panel-user USER --panel-pass PASS`
  once; the resulting key is then reused forever.
* Fallback of last resort: create a key in Panel -> API Keys and pass
  `--panel-key pg_key_...`.

## `warp-manager: command not found` after `remove`

Older versions removed the command on `remove --yes`. From 1.0.8 it is kept
unless `--uninstall-manager` is passed. If it is already gone, reinstall the
bootstrap (the backup directory and `warp-manager.sh` are always preserved):

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw' \
  'https://api.github.com/repos/XiliService/Warp-Pasarguard/contents/install.sh?ref=arena/01417195-warp-pasarguard' \
  | sudo bash -s -- --branch arena/01417195-warp-pasarguard --no-menu
```

---

## `Created dedicated API key` but `no panel endpoint answered`

The key was written to the panel database successfully; only the HTTP endpoint
was unreachable. From 1.0.10 the script probes Docker bridge IPs and uses
`nsenter` to reach the panel from inside its own container. Re-run:

```bash
sudo warp-manager update --yes
sudo warp-manager apply --yes
```

If it still fails, the log now lists every URL tried and the running
containers. Make sure the `pasarguard/panel` container is actually running.

---

## All panel endpoints fail (33/36 candidates), key was created in the DB

Do not remove or reinstall. From 1.0.11 the script runs curl **inside** the
`pasarguard/panel` container, which supports `UVICORN_UDS`, TLS, and
loopback-only listeners. Re-run:

```bash
sudo warp-manager update --yes
sudo warp-manager apply --yes
```

The log prints the container's `UVICORN_*` settings and the first HTTP reply.
Container discovery deliberately ignores `pgbouncer`, `pgadmin`,
`timescaledb`, and node containers (they caused timeout noise in earlier logs).

---

## All configs show ping -1 right after `apply`

Do not remove the WARP outbound by hand as a permanent fix - that disables WARP.
The cause was Xray choosing **kernel TUN** because the node has CAP_NET_ADMIN;
it installs global routes/ip rules and breaks every other inbound. From 1.0.12
the outbound uses `noKernelTun: true` (userspace), which cannot affect other
traffic.

```bash
sudo warp-manager update --yes
sudo warp-manager apply --yes
```

`apply` now rebuilds the snippets from the stored WARP profile and rolls the
Core config back automatically if a node reports an error. Manual rollback is
always available with `sudo warp-manager unapply --yes`.

Do not delete the separate `WireGuard` core in Core Settings: that is a
WireGuard server for your clients, not the WARP tunnel. The WARP tunnel is one
`wireguard` outbound inside the **Xray** core.

---

## Every config drops when WARP is applied

You are applying WARP to the **foreign relay** Core config. It has only 4
inbounds (`Germany`, `NetherLands`, `Poland`, `SOCKS5`); all 12 user configs
funnel into them, so any WARP rule affects everyone. Do not use `--all-traffic`.

Install/run the script on the **IRAN main panel server** instead. From 1.0.13
`apply` detects the `... Tunnel - ArvanCloud` inbounds there and scopes WARP to
those only, leaving `cdn` / `direct` configs on the three foreign IPs. The
foreign server must stay untouched.

---

## `wgcf register failed` / TLS handshake timeout to api.cloudflareclient.com

This happens when installing on an **Iranian** host: Cloudflare's WARP
*registration* API is filtered there, although the WireGuard UDP endpoint
(`engage.cloudflareclient.com:2408`) is usually reachable. The installer stops
before writing `outbound/*.json`, so a following `apply` reports
"Missing outbounds.json".

Do not retry `install`. The WARP account already exists on the foreign server
(it was created successfully there). Reuse it:

```bash
# On the FOREIGN server (one command, prints ONE WARP1: line):
sudo warp-manager update --yes
sudo warp-manager export-profile

# On the IRAN / MAIN PANEL server (paste that exact line between the quotes):
sudo warp-manager update --yes
sudo warp-manager import-profile 'WARP1:...'
sudo warp-manager apply --yes
sudo warp-manager status
```

`import-profile` writes the profile to `profiles/default/meta.env` (0600),
marks the deployment installed, and rebuilds the snippets with
`noKernelTun: true`. **No Cloudflare API call is made.** `install` also reuses
an existing/imported profile from now on instead of registering a new account.

The `WARP1:` line contains the WireGuard private key. Keep it private and
delete it from your terminal history afterwards.

---

## Tunnel configs disconnect as soon as WARP is applied on the Iran server

Cloudflare WARP is filtered on this host: `api.cloudflareclient.com` TLS
handshake times out and UDP 2408 to `engage.cloudflareclient.com` never
completes a handshake. The scoped `inboundTag` rule worked (only the tunnel
configs were affected, `cdn`/`direct` stayed up), but the WARP tunnel itself
cannot be established from Iran. Removing the WARP outbound/rule restores
pings, as observed.

Do not add a `wireguard` outbound to the Iran Core again. Use the dedicated
link instead, so WARP terminates on the foreign server while only the tunnel
configs are routed to it:

```bash
# FOREIGN server
sudo warp-manager update --yes
sudo warp-manager warp-link

# IRAN server
sudo warp-manager update --yes
sudo warp-manager warp-join 'WARPLINK1:...'
sudo warp-manager status
```

Both sides keep `BLOCK` as the trailing outbound and the leading routing rule.

---

## `warp-link` prints "Using Core config ==> Checking 21 candidate..." then "Could not read Core config"

This was a 1.0.15 bug: the Core ID was captured with `$(...)`, and the panel
progress lines written to stdout were captured together with the ID. The script
then tried `GET /core/<progress text + 1>` and failed.

From 1.0.16 the Core selection writes its result to a variable instead of
capturing stdout, validates that the ID is numeric, honours `--core-id`, and the
updater reports the branch that actually served the file. Do not remove or
reinstall anything; just update and rerun the two commands:

```bash
# FOREIGN server
sudo warp-manager update --yes
sudo warp-manager warp-link --yes

# IRAN / MAIN PANEL server
sudo warp-manager update --yes
sudo warp-manager warp-inbound 'WARPLINK1:...' --yes
```

If several Core configs exist and the selector cannot find one with (or
without) tunnel inbounds, it now stops with an explicit message instead of
picking the wrong one; pass `--core-id <number>` in that case.

---

## Tunnel configs break and I do not want ANY existing config to use WARP

`warp-join` in 1.0.15/1.0.16 rewrote the existing location rules (it removed
the `... Tunnel - ArvanCloud` tags from the `Germany` / `NetherLands` /
`Poland` rules). Any change to those rules breaks the tunnel configs, so this
approach is abandoned. Do not use `apply` on the Iran server either: a local
WARP WireGuard outbound there cannot reach Cloudflare and hangs the tunnel
configs.

From 1.0.17 the script created a **separate new inbound**; from 1.0.18 that inbound is a normal proxy config.  All 12
existing inbounds and their routing rules are restored from the pre-join Core
backup and left untouched; only the new `WARP-DEDICATED` inbound uses WARP via
the foreign node:

```bash
# FOREIGN server
sudo warp-manager update --yes
sudo warp-manager warp-link --show       # prints the saved WARPLINK1: line

# IRAN / MAIN PANEL server
sudo warp-manager update --yes
sudo warp-manager warp-inbound 'WARPLINK1:...' --yes
sudo warp-manager status
```

The command prints the inbound tag, protocol, cloned source and TCP port, plus
the exact Host fields. Create the Host in the Panel UI afterwards and allow
that TCP port on the Iran firewall. It also runs a live Cloudflare check
through the foreign link. To undo, run `sudo warp-manager warp-unlink --yes`.


---

## The dedicated inbound is SOCKS5; I cannot create a Host or use v2rayNG

That was 1.0.17. A raw `socks` inbound in the Core config cannot be used as a
PasarGuard Host and produces no usable v2rayNG / v2rayN config. PasarGuard
validates `inbound_tag` against the inbounds parsed from the Core configs
(`core_manager.get_inbounds()`), and builds subscription links from the
inbound's protocol.

From 1.0.18 `warp-inbound` **clones an existing VLESS/Reality inbound** (only
the tag and port change, `streamSettings` is preserved). The new tag appears
immediately in the Panel host form. Update both servers and rerun:

```bash
# FOREIGN server
sudo warp-manager update --yes
sudo warp-manager warp-link --show

# IRAN / MAIN PANEL server
sudo warp-manager update --yes
sudo warp-manager warp-inbound 'WARPLINK1:...' --yes
sudo warp-manager status
```

Then: `Hosts -> Add Host -> Inbound tag: WARP-DEDICATED`, address = Iran IP,
port = the port printed by the command, other fields at their defaults. The
old SOCKS5 inbound is replaced automatically. All existing configs stay
unchanged.


---

## Deleting WARP items on the FOREIGN server cuts the Iran WARP config

Symptom: to test whether the connection still works "without the inbound,
outbound and routing rule", those items were removed from the FOREIGN Core
config. The `WARP-DEDICATED` config on Iran immediately stopped working, while
`cdn` / `direct` / `tunnel` configs stayed healthy.

Cause: the Iran side is only the first half of the chain:

```
client -> WARP-DEDICATED (Iran) -> WARP-LINK SOCKS outbound (Iran)
       -> WARP-LINK SOCKS inbound (Foreign) -> warp outbound (Foreign)
       -> Cloudflare WARP -> Internet
```

If the FOREIGN inbound, outbound or rule disappears, the TCP connection from
Iran has nothing to talk to. This is expected behaviour, not a broken install.

**Do NOT test by deleting those items.** Use the non-destructive check on BOTH
servers:

```bash
sudo warp-manager warp-check
```

It verifies the TCP port, the live Cloudflare path and the Panel Core config,
and reports exactly which half is missing.

Recovery (no reinstall, no remove, no paste): **FOREIGN server FIRST**.

```bash
# 1) FOREIGN server
sudo warp-manager update --yes
sudo warp-manager repair --yes

# 2) IRAN server
sudo warp-manager update --yes
sudo warp-manager repair --yes

# 3) BOTH servers
sudo warp-manager warp-check
```

`repair` reuses the saved link credentials in `state.env` (same port, user and
password), so the `WARPLINK1:` line is not needed again. It detects which
server it is on and rebuilds only that server's half. On the IRAN server it
rebuilds its own config even if the foreign link is temporarily down, and
prints the exact commands for the other server.

---

## Option 1 must install OR repair, never just stop

From 1.0.19 the numbered menu is `1) Install / Repair WARP`. On a fresh server
option 1 runs the full install wizard; on a server that already has state it
**REPAIRS** the dedicated setup instead of printing "already installed, use
--force" and stopping. The same is available non-interactively:

```bash
sudo warp-manager repair --yes
sudo warp-manager warp-check
```

Run option 1 / `repair` / `warp-check` / `update` / `status` on **BOTH**
servers. See [TWO-SERVERS.md](TWO-SERVERS.md) for the complete per-server
command list.
