# Troubleshooting

All checks below are available through `warp-manager status` and
`warp-manager logs`.

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

Older versions removed the command on `remove --yes`. From 1.0.9 it is kept
unless `--uninstall-manager` is passed. If it is already gone, reinstall the
bootstrap (the backup directory and `warp-manager.sh` are always preserved):

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw' \
  'https://api.github.com/repos/XiliService/Warp-Pasarguard/contents/install.sh?ref=arena/01417195-warp-pasarguard' \
  | sudo bash -s -- --branch arena/01417195-warp-pasarguard --no-menu
```
