# Step-by-step: install and verify WARP (beginner guide)

This guide assumes no prior experience. Every command is copy-paste ready.
**You need TWO servers and the script must be installed and run on BOTH.**
Full per-server reference: [TWO-SERVERS.md](TWO-SERVERS.md).

* **FOREIGN relay server** - WARP terminates here. It keeps a `WARP-LINK` SOCKS
  inbound, the userspace `warp` outbound and one routing rule.
* **IRAN MAIN PANEL server** - all 12 user inbounds live here. It keeps ONE
  dedicated `WARP-DEDICATED` inbound (a normal VLESS/Reality config), one
  `WARP-LINK` SOCKS outbound and one routing rule.

Cloudflare WARP is filtered on Iranian hosts, so no WARP packet leaves Iran.
**Deleting the WARP inbound/outbound/routing rule on the FOREIGN server cuts
the WARP config on Iran.** Never test by deleting those items - use
`sudo warp-manager warp-check` instead.

Estimated time: 5-10 minutes.

---

## STEP 0 - Open TWO SSH windows

Open one SSH session to the **FOREIGN** server and one to the **IRAN MAIN PANEL**
server. Keep both open. Label them in your terminal so you never run a FOREIGN
command on the IRAN server by mistake.

---

## STEP 1 - Identify each server

Run on **both** servers:

```bash
hostname
whoami
ip -4 -o addr show scope global
```

The FOREIGN server shows the foreign public IPs; the IRAN server shows the Iran
IPs and hosts the panel. If you are unsure, stop and check with your provider
before continuing.

---

## STEP 2 - Install the script on BOTH servers

Run this **on each server**, exactly as written:

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw' 'https://api.github.com/repos/XiliService/Warp-Pasarguard/contents/install.sh?ref=arena/01417195-warp-pasarguard' | sudo bash -s -- --branch arena/01417195-warp-pasarguard
sudo warp-manager --version
```

Expected banner:

```
========================================================================
  PasarGuard WARP Manager  v1.0.19
========================================================================
```

---

## STEP 3 - Menu option 1 on BOTH servers

On each server run:

```bash
sudo warp-manager
```

and choose **1) Install / Repair WARP**.

Option 1 never just stops. On a fresh server it installs; on a server that
already has state it REPAIRS the existing setup - it never says "already
installed, use --force" and never removes anything. You can do the same without
the menu:

```bash
sudo warp-manager repair --yes
```

The other menu items are the same on both servers:

```
1) Install / Repair WARP
2) Remove / Uninstall WARP
3) Update Script
4) View Logs
5) Status / Health Check
6) Exit
```

---

## STEP 4 - FOREIGN server commands

Run in this order on the **FOREIGN** server:

```bash
sudo warp-manager update --yes
sudo warp-manager warp-link --yes
sudo warp-manager warp-link --show
sudo warp-manager warp-check
sudo warp-manager status
```

* `warp-link --yes` creates the `WARP-LINK` SOCKS inbound, the `warp` outbound
  and the scoped routing rule, then prints one `WARPLINK1:...` line.
* `warp-link --show` reprints that same line later without changing anything.
* The line contains the link password - keep it private, paste it only into
  your own terminal on the IRAN server.
* Allow the printed TCP port on the FOREIGN host firewall, ideally only from
  the Iran server IP. The node container uses host networking.
* `warp-check` verifies the port, the live Cloudflare path and the Core config
  **without changing anything**.

---

## STEP 5 - IRAN MAIN PANEL server commands

Run in this order on the **IRAN** server (first time only needs the pasted line):

```bash
sudo warp-manager update --yes
sudo warp-manager warp-inbound 'WARPLINK1:...' --yes
sudo warp-manager warp-check
sudo warp-manager status
```

Replace `WARPLINK1:...` with the whole line printed by the FOREIGN server. It
is saved in `state.env` (mode 0600), so later repairs do NOT need it again.

`warp-inbound` clones one of your existing VLESS/Reality inbounds as
`WARP-DEDICATED` (only its tag and port change), adds a `WARP-LINK` SOCKS
outbound before `BLOCK`, and adds exactly one routing rule for that inbound.
Every existing `cdn` / `direct` / `tunnel` inbound, outbound and rule stays
unchanged. Allow the printed TCP port of `WARP-DEDICATED` on the IRAN firewall.

---

## STEP 6 - Create the Host in the Panel UI

On the **IRAN** panel: `Hosts -> Add Host`

* `Inbound tag`: `WARP-DEDICATED`
* `Address`: the Iran server IP
* `Port`: the port printed by `warp-inbound`
* leave all other fields at their defaults

The inbound appears in the list immediately after the Core update. The
generated config works in v2rayNG / v2rayN and is the ONLY config that uses
WARP. Give it only to the users who need WARP.

---

## STEP 7 - Verify that WARP really works

On **BOTH** servers:

```bash
sudo warp-manager warp-check
```

Then open the new `WARP-DEDICATED` config in v2rayNG / v2rayN and visit
<https://ipinfo.io/json>. A Cloudflare WARP address such as
`104.28.x.x / AS13335 Cloudflare, Inc.` means the path works. The `cdn` /
`direct` / `tunnel` configs must still show their original foreign IPs.

`warp-check` also runs a live `socks5h://` test through the foreign link, so you
can confirm the path from the command line without deleting anything.

---

## STEP 8 - Repair after something was deleted (FOREIGN first)

No reinstall, no remove, no paste of the `WARPLINK1:` line:

```bash
# 1) FOREIGN server - FIRST
sudo warp-manager update --yes
sudo warp-manager repair --yes

# 2) IRAN server - SECOND
sudo warp-manager update --yes
sudo warp-manager repair --yes

# 3) BOTH servers
sudo warp-manager warp-check
```

`repair` detects which server it is on and rebuilds only that server's half
from the saved credentials. On the IRAN server it rebuilds its own config even
if the foreign link is temporarily down. Menu option 1 does exactly the same.

---

## STEP 9 - Day-to-day commands (run on the server you mean)

```bash
sudo warp-manager update --yes     # both servers
sudo warp-manager status           # both servers
sudo warp-manager logs             # both servers
sudo warp-manager warp-check       # both servers, non-destructive
sudo warp-manager repair --yes     # both servers, FOREIGN first
```

Each server also has `/opt/pasarguard-warp/SERVER-GUIDE.md` with these commands
locally, written by the script.

---

## Backup and rollback

* `sudo warp-manager backup` creates a full DB + panel + node backup with
  `RESTORE.md`. `sudo warp-manager restore /opt/pasarguard-warp/backups/full-...`
  restores files; the database part is manual via `RESTORE.md`.
* `install --yes` and `remove --yes` take a `pre-install` / `pre-remove` backup
  automatically.
* Every Core change writes a JSON backup to `/opt/pasarguard-warp/backups/`,
  including `warp-link-core-*`, `warp-inbound-core-*` and
  `warp-join-core-*`.
* `sudo warp-manager warp-unlink --yes` on the IRAN server removes the
  dedicated WARP inbound/outbound/rule surgically; then delete the Hosts you
  created for `WARP-DEDICATED` in the Panel UI.

## API key lifecycle

The script creates one dedicated Panel API key through the CLI (or the local
database), reuses it across versions and installs, and stores the raw key in
`state.env` with mode 0600. `sudo warp-manager key` shows/reuses it. No manual
key creation or paste in the Panel UI is needed.

## Safety notes

* Never delete WARP inbounds/outbounds/rules to test the link - use
  `warp-check`.
* Never run `apply` on the IRAN server for this deployment: a local WARP
  WireGuard outbound there breaks the `tunnel` configs.
* Outbound order on both sides is `DIRECT -> ... -> warp / WARP-LINK -> BLOCK`;
  the leading `BLOCK` routing rule stays above the WARP rule.
* All script output, menus and logs are in English.
