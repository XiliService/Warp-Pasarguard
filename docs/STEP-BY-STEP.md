# Step-by-step: install and verify WARP (beginner guide)

This guide assumes no prior experience with the tool. Every command is
copy-paste ready. Run everything on the **EXIT NODE** (the foreign server with
the NL / DE / PL IPs), unless a step explicitly says otherwise.

Estimated time: 5-10 minutes.

---

## STEP 0 - Prepare two SSH sessions

Open **two** SSH windows to the foreign server. Keep the second one idle as a
safety net. Also make sure you know how to reach the datacenter console (VNC /
rescue shell) for that VPS.

The `xray` backend used in this guide does **not** change the server routing
table, so SSH will not drop. The precaution is still good practice.

---

## STEP 1 - Confirm you are on the correct server

```bash
hostname
whoami
ip -4 -o addr show scope global
docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null || true
ls -d /opt/pg-node /opt/pasarguard 2>/dev/null || true
```

Expected:

- several global IPv4 addresses (your three locations);
- a container such as `pg-node` running `pasarguard/node`;
- `/opt/pg-node` exists.

If you instead see `/opt/pasarguard` and no node container, you are on the
**Iran main panel**. Stop and reconnect to the foreign server: WARP for
`tunnel` configs belongs on the machine where traffic leaves to the Internet.

---

## STEP 2 - Check prerequisites

```bash
sudo -i                      # become root, or prefix each command with sudo
cat /etc/os-release | head -5
command -v curl jq docker ip
curl -fsSI https://api.github.com | head -1
curl -fsSI https://github.com | head -1
docker exec pg-node xray version 2>/dev/null | head -2 || true
```

Expected: Debian/Ubuntu, all tools present, HTTP 200/301 from GitHub, and an
Xray version of **1.8.3 or higher**. If Xray is older, upgrade the core first
(`pg-node core-update`) or choose the `kernel` backend in STEP 6.

---

## STEP 3 - Install the manager

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw' \
  'https://api.github.com/repos/XiliService/Warp-Pasarguard/contents/install.sh?ref=arena/01417195-warp-pasarguard' \
  | sudo bash -s -- --branch arena/01417195-warp-pasarguard
```

What the command means:

| Part | Meaning |
| --- | --- |
| `curl -fsSL` | download silently, fail on HTTP errors, follow redirects |
| `-H 'Accept: application/vnd.github.raw'` | ask GitHub API for the raw file, not the JSON metadata |
| `\| sudo bash -s -- ...` | run the downloaded script as root; `-s` means "read the script from the pipe" |
| `--branch ...` | download `warp-manager.sh` from the same branch |

Expected output:

```
  PasarGuard WARP Manager - Bootstrap Installer v1.0.9
==> Trying https://api.github.com/repos/.../contents/warp-manager.sh?ref=...
==> Installed: /opt/pasarguard-warp/warp-manager.sh
==> Command  : /usr/local/bin/warp-manager
==> Done.
```

The bootstrap may open the menu automatically. If it does, press `0`/`6` to
exit for now, or simply continue with STEP 4.

Verify the installation:

```bash
which warp-manager
warp-manager --version          # PasarGuard WARP Manager 1.0.9
ls -l /usr/local/bin/warp-manager
```

If `warp-manager: command not found`, re-read the installer output. The usual
cause is an old cached `install.sh`; use the API URL above (not
`raw.githubusercontent.com`).

---

## STEP 4 - Look at the current state (before doing anything)

```bash
sudo warp-manager status
```

Expected before installation:

```
  Detected role          node
  Global IPv4 addresses  3
  Installation           not installed
  ...
WARN No WARP profiles registered.
WARN Overall health: 1 item(s) need attention.
```

The warning is normal at this point: nothing is installed yet.

---

## STEP 5 - Rehearse with a dry run (changes nothing)

```bash
sudo warp-manager install --mode xray --target exit \
  --binding single --routing domains --yes --dry-run
```

You will see the deployment-target explanation, then an "Installation plan"
and `Dry-run complete. No changes were made.`. Nothing is downloaded or
written. This is a safe way to see what the real install will do.

---

## STEP 6 - Real installation through the menu

```bash
sudo warp-manager
```

You will see:

```
  1) Install / Configure WARP
  2) Remove / Uninstall WARP
  3) Update Script
  4) View Logs
  5) Status / Health Check
  6) Exit
```

Type `1` and press **Enter**. Then answer the wizard in this order:

| # | Prompt on screen | What to type |
| --- | --- | --- |
| 1 | `Where does the traffic you want to cover EXIT the Internet?` | `1` + Enter (EXIT NODE) |
| 2 | `Select the WARP backend:` | `1` + Enter (Xray native WireGuard) |
| 3 | `Select the binding strategy:` | `1` + Enter for the simplest setup, or `3` + Enter for one tunnel per IP |
| 4 | `Label for <IP> (e.g. nl, de, pl) ...` (only if you chose `3`) | `nl`, then `de`, then `pl`, each followed by Enter |
| 5 | `Which traffic should use WARP?` | `1` + Enter (selected domains only) |
| 6 | `Domain list (comma separated) [Enter = default]:` | just **Enter** (uses the documented list) |
| 7 | `WARP+ license key (optional, Enter to skip):` | just **Enter** |
| 8 | `WARP endpoint [engage.cloudflareclient.com:2408]:` | just **Enter** |
| 9 | `Panel API base URL to auto-apply config (optional ...):` | just **Enter** for now (manual paste in STEP 8), or paste `https://panel.example.com` to let the tool configure the panel |
| 10 | `Proceed with this plan? [y/N]:` | `y` + Enter |
| 11 | `Select the service that runs Xray on this host:` (only if several services) | choose `node` |
| 12 | `Restart the node container now to apply the new permissions? [y/N]:` | `y` + Enter |
| 13 | `Apply this change to the panel now? [y/N]:` (only if you entered a panel URL in step 9) | `y` + Enter after reading the diff summary |

If you entered a panel URL, two extra prompts appear: admin username and admin
password (the password is hidden while typing), and a list of Core
configurations to choose from. Select the Core assigned to the foreign node.

### What happens in the background

```
apt-get install (missing packages)
  -> download wgcf, verify SHA-256 against the release checksums
  -> wgcf register --accept-tos   (creates a Cloudflare WARP account)
  -> wgcf generate               (creates wgcf-profile.conf)
  -> write JSON snippets to /opt/pasarguard-warp/outbound/
  -> ensure /dev/net/tun exists
  -> patch /opt/pg-node/docker-compose.yml (with a backup)
  -> docker compose config validation, then recreate the container
```

`wgcf register` talks to Cloudflare and can take 5-30 seconds. Do not press
Ctrl+C. Finish with:

```
==> Installation complete
```

### One-line alternative (no menus)

```bash
sudo warp-manager install --mode xray --target exit \
  --binding per-ip --labels nl,de,pl --yes
```

---

## STEP 7 - Verify the files on the node

```bash
sudo ls -la /opt/pasarguard-warp/outbound/
sudo cat /opt/pasarguard-warp/outbound/README.txt
sudo jq . /opt/pasarguard-warp/outbound/outbounds.json | head -40
sudo cat /opt/pasarguard-warp/outbound/routing-rules.json
sudo grep -A4 'devices:' /opt/pg-node/docker-compose.yml
docker ps --format '{{.Names}}\t{{.Status}}'
```

Expected: `outbounds.json`, `routing-rules.json`, `balancers.json`, `README.txt`;
a `warp` (or `warp-nl` / `warp-de` / `warp-pl`) outbound with your WARP private
key, `/dev/net/tun:/dev/net/tun` in compose, and the node container running
with a recent "Up" time (it was recreated).

---

## STEP 8 - Configure the panel (skip if STEP 6 step 9 used the API)

1. Open the PasarGuard dashboard in your browser (this is the **Iran** main
   panel - the dashboard URL, not SSH).
2. Go to **Core Settings**.
3. Select the Core configuration assigned to the **foreign node**.
4. Switch the config editor to JSON/raw mode.
5. Copy the objects from `/opt/pasarguard-warp/outbound/outbounds.json` into
   the `outbounds` array. Put them **after** the existing first outbound.
6. Copy objects from `routing-rules.json` to the **top** of `routing.rules`.
7. In per-IP mode, also copy `balancers.json` into `routing.balancers`.
8. Click **Save**. The panel pushes the config to the node.

To copy the files comfortably from the server:

```bash
sudo cat /opt/pasarguard-warp/outbound/outbounds.json
sudo cat /opt/pasarguard-warp/outbound/routing-rules.json
sudo cat /opt/pasarguard-warp/outbound/balancers.json
```

Confirm the node received the change:

```bash
docker exec pg-node sh -c 'grep -rl "warp" /var/lib/pg-node/generated/ 2>/dev/null | head'
# or simply check the Core Settings page after saving
```

See `docs/PANEL-CONFIG.md` for complete JSON examples.

### If the installer printed `WARN Could not authenticate`

The install itself still succeeded, but the **panel config was NOT applied**,
so WARP is not active yet. Either paste the snippets manually as described
above, or fix the credentials and push them without reinstalling:

```bash
# Diagnose the login (HTTP 401 = wrong credentials, 404 = wrong URL)
curl -i -X POST -H 'Accept: application/json' \
  --data-urlencode 'username=admin' --data-urlencode 'password=YOUR_PASSWORD' \
  https://panel.example.com/api/admin/token

# Then apply the snippets that are already on disk
sudo warp-manager apply --panel-url https://panel.example.com \
  --panel-user admin --panel-pass 'YOUR_PASSWORD' --core-id 1 --yes
```

`PANEL_URL` must be the dashboard root (do **not** append `/api`). The admin
account needs `cores:read` and `cores:update` permissions. Use `--insecure`
only for self-signed certificates. `warp-manager unapply` reverses the change.
`apply` also patches `/dev/net/tun` into every node container on the host, so
it is the single command that finishes an interrupted install.

The manager log is a **history**, not current state. Lines from earlier failed
attempts stay in the file; only the last few lines describe the present state.
Use `warp-manager status` for the current state.

---

## STEP 9 - Test that WARP actually works

### 9.1 Health check on the server

```bash
sudo warp-manager status
```

Look for:

```
  Xray version     26.10.21 (minimum 1.8.3)
  TUN device       available
  Installed         yes
  Backend           xray
  Target            exit
  Binding           single
  Routing           domains
  Profiles          default            (or nl de pl)
  Last panel apply  never
OK    /opt/pasarguard-warp/outbound/outbounds.json
OK    Docker compose patched: /opt/pg-node/docker-compose.yml
OK Overall health: OK
```

`Last panel apply  never` means the snippets were generated but **not pushed to
the panel** - WARP is not yet carrying traffic. `Overall health: OK` only
checks local files, so it is NOT proof that WARP is active.

### 9.2 Logs (menu option 4)

```bash
sudo warp-manager logs
```

| Type | To see |
| --- | --- |
| `1` | manager log, last 80 lines |
| `5` | `wgcf status` for each WARP account (account type, device count) |
| `6` | the generated panel snippets |
| `4` | node container logs (Xray startup, WireGuard errors) |

### 9.3 Xray / container check

```bash
cd /opt/pg-node && sudo docker compose logs --tail=100 node
sudo tcpdump -ni any 'udp port 2408' -nn    # Ctrl+C to stop; shows WARP packets
```

### 9.4 The real test, from a client

1. On your phone/PC, connect with one of the **`tunnel`** configs from the
   panel (v2rayNG, NekoRay, Streisand, ...).
2. Open <https://ipinfo.io/json> in the browser. `ip` should be a **Cloudflare**
   address (`104.28.x.x`, `172.66.x.x`, `162.158.x.x`, ...) and `org` should
   mention Cloudflare - **not** your foreign server IP.
3. Also try the services that previously blocked your IP: Google, OpenAI,
   Spotify, and <https://ipinfo.io/>.

**If `routing=all` was chosen**, <https://www.cloudflare.com/cdn-cgi/trace>
will additionally show:

```
warp=on          (or warp=plus with a WARP+ key)
ip=...           a Cloudflare address
loc=...          a Cloudflare PoP
```

**If `routing=domains` was chosen**, `www.cloudflare.com` is NOT in the
default domain list, so that page will show `warp=off`. That is correct, not
a failure. To see `warp=on` there, add `cloudflare.com` to the rule's
`domain` array (or temporarily use `routing=all`).

### 9.5 Negative control (important)

Repeat 9.4 with a **`direct`** config. <https://ipinfo.io/json> must show your
real foreign server IP again. That confirms the difference really comes from
WARP and not from something else.

---

## STEP 10 - If the test fails

| Symptom | Command / fix |
| --- | --- |
| `warp=off` / real IP still visible | Re-check STEP 8 (was the correct Core saved?), then `sudo warp-manager logs` -> option 4 |
| `failed to create virtual tun interface` | `ls -l /dev/net/tun`, re-apply the compose patch, `cd /opt/pg-node && sudo docker compose up -d` |
| `warp-manager: command not found` | Re-run STEP 3 with the API URL |
| `Could not download wgcf` | Download the binary manually to `/opt/pasarguard-warp/bin/wgcf`, `chmod +x`, then `sudo warp-manager install --force` |
| Compose validation failed | `cd /opt/pg-node && sudo docker compose config`; fix indentation; a backup is in `/opt/pasarguard-warp/backups/` |
| Xray older than 1.8.3 | `pg-node core-update`, or reinstall with `--mode kernel` |
| SSH dropped | Only possible with the kernel backend; use the datacenter console and `sudo systemctl disable --now wg-quick@warp` |

Full table: `docs/TROUBLESHOOTING.md`.

---

## STEP 11 - Day-to-day commands

```bash
sudo warp-manager              # menu
sudo warp-manager status       # health check
sudo warp-manager logs         # logs submenu
sudo warp-manager update --check
sudo warp-manager update       # update the tool itself
sudo warp-manager remove       # uninstall WARP
```

After `remove`, also delete the `warp` outbound/rule from Core Settings if you
pasted them manually (the API path removes them automatically).

Backups of every modified file live in `/opt/pasarguard-warp/backups/`.
WARP private keys live in `/opt/pasarguard-warp/profiles/` with mode 0600 -
never share those files.

---

## Backup and rollback

A full backup (files + database + Core configs) is taken automatically before
every `install` and every `remove`. To take one manually:

```bash
sudo warp-manager backup
sudo warp-manager status          # shows the last backup path
```

To roll back files: `sudo warp-manager restore <backup-dir>` (see
`RESTORE.md` inside the backup for the database step). Backups are never
removed by `remove`.

## API key lifecycle

`sudo warp-manager key` creates a dedicated `warp-manager` API key once and
reuses it in all future versions. The install wizard asks for the admin
username/password only the first time; the password is never stored.
