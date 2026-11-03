# Two servers are required

**The script MUST be installed and run on BOTH servers.** Installing it on only
one server does not work. This is the single most important rule of this
deployment:

* **FOREIGN relay server** (`vps-2l1iwbeu`, `95.135.200.231`) - WARP itself
  terminates here. It owns the `WARP-LINK` SOCKS inbound, the userspace `warp`
  WireGuard outbound and the routing rule that sends that inbound to WARP.
* **IRAN MAIN PANEL server** (`Main-IR`, `91.223.61.183`) - all 12 user
  inbounds live here. It owns ONE dedicated `WARP-DEDICATED` inbound (a clone
  of a real VLESS/Reality inbound), one `WARP-LINK` SOCKS outbound pointing at
  the foreign server, and one routing rule scoped to that inbound.

Cloudflare WARP is filtered on the Iranian host, so no WireGuard/WARP packet
ever leaves Iran. Iran only opens a plain TCP connection to the foreign relay.
**Deleting the WARP inbound, outbound or routing rule on the FOREIGN server
immediately cuts the WARP config on Iran**, while `cdn` / `direct` / `tunnel`
configs keep working. That is expected: the two halves form one path.

> Do NOT test the link by deleting those items. Use
> `sudo warp-manager warp-check` on BOTH servers instead - it verifies the TCP
> port, the live Cloudflare path and the Panel Core config without changing
> anything.

---

## 1. Install the script on BOTH servers (one time)

Run this **on each server**, exactly as written:

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw' 'https://api.github.com/repos/XiliService/Warp-Pasarguard/contents/install.sh?ref=arena/01417195-warp-pasarguard' | sudo bash -s -- --branch arena/01417195-warp-pasarguard
sudo warp-manager
```

The numbered menu is the same on both servers:

```
1) Install / Repair WARP
2) Remove / Uninstall WARP
3) Update Script
4) View Logs
5) Status / Health Check
6) Exit
```

**Option 1 never just stops.** On a fresh server it installs WARP; on a server
that already has state it REPAIRS the existing dedicated setup instead of
reinstalling or asking for `--force`. You can also run `sudo warp-manager
repair --yes` directly.

---

## 2. FOREIGN relay server - exact commands

```bash
sudo warp-manager update --yes
sudo warp-manager                       # menu option 1
sudo warp-manager warp-link --yes        # creates the link, prints WARPLINK1:
sudo warp-manager warp-link --show       # reprint the saved line, changes nothing
sudo warp-manager warp-check             # non-destructive health check
sudo warp-manager status
sudo warp-manager logs
```

What must stay in the FOREIGN Core config (deleting any of them breaks Iran's
WARP config):

* inbound `WARP-LINK` (SOCKS5, private port, user/password),
* outbound `warp` (userspace `noKernelTun: true`, inserted before `BLOCK`),
* one routing rule `inboundTag: ["WARP-LINK"] -> warp`, below the leading
  `BLOCK` rule.

Allow that TCP port on the FOREIGN host firewall, ideally only from the Iran IP
`91.223.61.183`. The node containers use host networking, so the port is on
the host.

---

## 3. IRAN MAIN PANEL server - exact commands

```bash
sudo warp-manager update --yes
sudo warp-manager                       # menu option 1
sudo warp-manager warp-inbound 'WARPLINK1:...' --yes   # first time only
sudo warp-manager warp-check             # non-destructive health check
sudo warp-manager status
sudo warp-manager logs
```

The `WARPLINK1:...` line is printed by `warp-link` on the FOREIGN server. It
contains the link password, so keep it private and paste it only into your own
terminal. It is saved in `state.env` (mode 0600), so later repairs do not need
it again.

What must stay in the IRAN Core config:

* inbound `WARP-DEDICATED` (a clone of one of the existing VLESS/Reality
  inbounds; only its tag and port change),
* outbound `WARP-LINK` (SOCKS to the foreign relay, inserted before `BLOCK`),
* one routing rule `inboundTag: ["WARP-DEDICATED"] -> WARP-LINK`, below the
  leading `BLOCK` rule.

All other `cdn` / `direct` / `tunnel` inbounds, outbounds and routing rules are
left unchanged. Allow the printed TCP port of `WARP-DEDICATED` on the IRAN host
firewall.

### Create the Host in the Panel UI

`Hosts -> Add Host -> Inbound tag: WARP-DEDICATED`, address = Iran server IP,
port = the port printed by `warp-inbound`, other fields at their defaults. The
inbound appears in the Panel list immediately after the Core update. The
generated config works in v2rayNG / v2rayN and is the ONLY config that uses
WARP.

---

## 4. Repair after anything was deleted (run in THIS order)

No reinstall, no remove, no copy-paste of the `WARPLINK1:` line: the saved
credentials are reused.

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

`repair` detects which server it is running on, rebuilds only that server's
half from the saved state, and prints the commands for the other server. On the
IRAN server it rebuilds its own config even if the foreign link is temporarily
down, so nothing is left half-configured. Menu option 1 does exactly the same
thing.

To completely remove the dedicated WARP setup later, run
`sudo warp-manager warp-unlink --yes` on the IRAN server, then delete the Hosts
you created for `WARP-DEDICATED` in the Panel UI.

---

## 5. Quick reference

| Need | FOREIGN server | IRAN server |
| --- | --- | --- |
| Install script | yes | yes |
| Run menu option 1 | yes | yes |
| `warp-link` / `warp-inbound` | `warp-link` | `warp-inbound` |
| `update --yes` | yes | yes |
| `repair --yes` (foreign first) | yes | yes |
| `warp-check` | yes | yes |
| `status` / `logs` | yes | yes |
| Panel Host creation | no | yes |

Both servers also get `/opt/pasarguard-warp/SERVER-GUIDE.md`, written by the
script, with these commands locally available.

---

## 6. Why the WARP config on Iran stops when FOREIGN items are deleted

```
client -> WARP-DEDICATED inbound (Iran)
       -> WARP-LINK SOCKS outbound (Iran)  --TCP-->  WARP-LINK SOCKS inbound (Foreign)
       -> warp outbound (Foreign) -> Cloudflare WARP -> Internet
```

The Iran side is only the first half of the chain. If the FOREIGN inbound,
outbound or rule disappears, the TCP connection from Iran has nothing to talk
to, so the `WARP-DEDICATED` config fails while all other configs stay healthy.
`warp-check` reports exactly which half is missing, and `repair --yes` on each
server restores it.

See also `docs/ARCHITECTURE.md`, `docs/STEP-BY-STEP.md` and
`docs/TROUBLESHOOTING.md`.
