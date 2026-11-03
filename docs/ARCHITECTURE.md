# Architecture: where WARP belongs in a multi-node PasarGuard deployment

This document explains the decision that the installer asks you to make in
**Install -> Deployment target**. Everything here is English by design.

## 1. Terminology

| Term | Meaning in this repository |
| --- | --- |
| **Main panel** | The PasarGuard instance that owns the database, users, Core Settings and the dashboard. In the reference deployment it runs in Iran. |
| **Node** | A worker that receives a generated Xray config from the main panel and executes it. In the reference deployment it runs on the foreign server. |
| **Egress / exit point** | The machine whose IP opens the TCP/UDP connection to the public Internet. |
| **tunnel config** | A config whose traffic travels `client -> Iran panel -> node link -> foreign server -> Internet`. The "tunnel" here is the node link, not WARP. |
| **direct config** | A config whose traffic exits directly from the Iran server. |
| **cdn config** | A config whose traffic enters through a CDN edge; the origin leg may still terminate on a specific server. |

## 2. The reference topology

```
                         +--------------------------------+
                         |  IRAN : MAIN PANEL             |
                         |  - all users                   |
                         |  - Core Settings (Xray JSON)   |
                         |  - cdn / direct / tunnel cfgs  |
                         +---------------+----------------+
                                         | gRPC node link (62050)
                                         | TLS certificate, API key
                                         v
+-------------------------------------------------------------------------+
|  FOREIGN SERVER (one machine, 3 public IPs)                              |
|  - PasarGuard node container (network_mode: host, NET_ADMIN)             |
|  - 203.0.113.10  -> Netherlands outbound                                 |
|  - 203.0.113.11  -> Germany outbound                                    |
|  - 203.0.113.12  -> Poland outbound                                     |
|  - Xray executes the config pushed by the panel                          |
+-------------------------------+-----------------------------------------+
                                |
                                v
                        PUBLIC INTERNET
                        (Google, OpenAI, Spotify, ...)
```

## 2.1 The two Core configs (confirmed from a real deployment)

There are **two Core configs**, and they are not interchangeable:

| | IRAN main panel core | FOREIGN relay core |
| --- | --- | --- |
| Inbounds | 12, one per config category (`[DE] - CloudFlare - CDN`, `[DE] - DC - Reality`, `[DE] - Tunnel - ArvanCloud`, ...) | 4: `Germany`, `NetherLands`, `Poland`, `SOCKS5` |
| Outbounds | `DIRECT`, `Germany`, `NetherLands`, `Poland` (vless to the foreign inbounds), `BLOCK` | `DIRECT`, `Out-DE`, `Out-NL`, `Out-PL` (freedom bound to the 3 IPs), `BLOCK` |
| Routing | maps each **inbound tag** to a location outbound | maps each of the 3 location inbounds to an IP outbound |

All 12 user configs are merged into just **3 inbounds** by the time they reach
the foreign relay. Therefore the foreign core **cannot tell a `tunnel` config
from a `cdn` or `direct` config**. Any WARP rule added there captures every
user, which is exactly why every config drops when WARP is applied on the
foreign server.

## 3. Decision table (corrected)

| Goal | Run `warp-manager` on | Backend | Notes |
| --- | --- | --- | --- |
| Cover **only `tunnel` configs** (recommended) | **IRAN main panel server** | `xray` | The script finds the `... Tunnel ...` inbound tags and scopes the WARP rule to them. All other configs keep their foreign IP. |
| Cover `direct` configs | IRAN main panel server | `xray` | Same core, different inbound tags |
| Cover `cdn` configs | IRAN main panel server | `xray` | Same core, different inbound tags |
| Only produce JSON snippets | Any machine (or a laptop) | any | `--target generator --dry-run`, no host changes |

**Answer to "which server?": BOTH, with different jobs.** The WARP *decision*
belongs on the Iran main panel (only there are the 12 configs distinguishable),
but the WARP *tunnel* belongs on the foreign server, because Cloudflare WARP is
filtered on the Iranian host (`api.cloudflareclient.com` times out and UDP 2408
does not complete a handshake). Putting a `wireguard` outbound in the Iran
Core makes exactly the tunnel configs hang; putting a global WARP rule in the
foreign Core affects every config.

## 3.1 Dedicated WARP link (1.0.18)

A private SOCKS link joins the two Core configs, so WARP is used by the tunnel
configs only:

```
  Iran core:  [DE/NL/PL] - Tunnel - ArvanCloud  --                                                   -> socks outbound WARP-LINK
  Iran core:  [DE/NL/PL] - CDN / DC - Reality ----> Germany / NetherLands / Poland (unchanged)
                                                          |
                                   TCP (private port, user/pass)
                                                          v
  Foreign core: inbound WARP-LINK (socks) -> rule inboundTag=[WARP-LINK] -> warp
  Foreign core: Germany / NetherLands / Poland -> Out-DE / Out-NL / Out-PL (unchanged)
                                                          |
                                                          v
                                     Cloudflare WARP -> Internet
```

* `warp-manager warp-link` on the **foreign** server creates the SOCKS inbound,
  the userspace WARP outbound, and a rule scoped to that inbound. It prints one
  `WARPLINK1:` line with host/port/user/pass.
* `warp-manager warp-inbound 'WARPLINK1:...'` on the **Iran** server creates ONE
  brand-new `WARP-DEDICATED` inbound by **cloning an existing VLESS/Reality
  inbound** (only its tag and port change) and routes only that inbound to the
  foreign link. No existing inbound, outbound or routing rule is modified.
* It is a normal proxy inbound, not SOCKS5: `core_manager` builds the Panel's
  inbound list from the Core config, so the new tag is immediately selectable
  when creating a Host, and the subscription generates a config that works in
  v2rayNG / v2rayN.
* `cdn` / `direct` / `tunnel` configs therefore keep their original rules and
  the three foreign IPs. No other config, node or inbound is touched.

### 3.2 Why the 1.0.15/1.0.16 "split tunnel rules" approach was wrong

`warp-join` (1.0.15/1.0.16) removed the tunnel inbound tags from the existing
`Germany` / `NetherLands` / `Poland` location rules and put them into a new
WARP-LINK rule. That **changed the tunnel configs themselves**, which was
exactly what the user did not want, and made them stop working. From 1.0.17
`warp-join` is only an alias for `warp-inbound`; `warp-inbound` restores the
original rules from the pre-join Core backup before adding the dedicated
inbound. `warp-unlink` restores that same backup to undo everything.

`warp-manager apply` still refuses a shared egress Core with no tunnel inbound
unless `--all-traffic` is given.

## 4. What each backend changes

### Xray WireGuard outbound

```
wgcf register/generate  ->  private key, WARP addresses
        |
        v
Core Settings (panel DB)  --push-->  node Xray process
                                        |
                                        +-- wireguard outbound (userspace TUN)
                                        +-- UDP to engage.cloudflareclient.com:2408
                                        +-- /dev/net/tun exposed by docker-compose
```

- No kernel VPN, no `wg-quick`, no routing table change on the host.
- Works with `network_mode: host` node containers.
- Requires Xray >= 1.8.3; older builds leak memory.
- The official guide says no node changes are needed because the panel pushes
  the config; the container permission lines are still required.

### Kernel WireGuard

```
wgcf register/generate  ->  /etc/wireguard/warp.conf (Table = off)
        |                            |
        |                            +-- wg-quick@warp (systemd)
        |                            +-- UDP socket to Cloudflare
        v
Core Settings -> freedom outbound with sockopt.interface = "warp"
```

- `SO_BINDTODEVICE` on the freedom outbound pushes matching traffic into the
  WireGuard interface.
- `Table = off` is non-negotiable: otherwise `wg-quick` hijacks the default
  route and SSH is lost.
- Must be installed on **every** egress node.

## 5. Three IPs, three locations

A single WARP account produces a single Cloudflare egress, so all three
location outbounds would look identical to the outside world. To keep them
distinct, `--binding per-ip` creates one WARP account per source IP:

```
warp-nl  sendThrough = 203.0.113.10   -> Cloudflare PoP near NL
warp-de  sendThrough = 203.0.113.11   -> Cloudflare PoP near DE
warp-pl  sendThrough = 203.0.113.12   -> Cloudflare PoP near PL
                    |
                    v
        routing.balancers: warp-pool (random)
                    |
                    v
        rule: domain list -> balancerTag "warp-pool"
```

`sendThrough` is a general Xray outbound field. Xray's WireGuard dialer calls
`internet.DialSystem` with the request context, and the dispatcher places the
`sendThrough` address in that context as the outbound gateway; the resulting
UDP socket is bound to that source IP. Verify with:

```bash
tcpdump -ni eth0 'udp port 2408'
```

For the kernel backend the equivalent is a reversible host route toward a
distinct numeric Cloudflare endpoint with `src <IP>` in `PostUp`, cleaned up
by `PreDown`.

If you need deterministic mapping instead of a random pool, replace the
balancer with three rules scoped by `inboundTag` (see `PANEL-CONFIG.md`).

## 6. Config flow through the panel API

```
POST /api/admin/token            -> Bearer token
GET  /api/cores                  -> choose the Core used by the EXIT NODE
GET  /api/core/{id}              -> full snapshot -> local backup
jq merge                         -> replace warp* outbounds/rules/balancers
                                    keep everything else untouched
PUT  /api/core/{id}?restart_nodes=true
                                 -> panel notifies nodes and hot-applies
                                    routing/outbound changes where possible
```

The merge is idempotent and reversible: `warp-manager remove` performs the
inverse filter. A full snapshot of the previous core config is always saved
under `/opt/pasarguard-warp/backups/`.

## 7. Why WARP does not replace the node tunnel

WARP is an **outbound** applied after Xray has accepted a connection. The
node link between Iran and the foreign server is how the connection reaches
the foreign Xray in the first place. Both are useful and independent:

- the node link hides the foreign server behind the Iran entry point and lets
  one panel manage several locations;
- WARP changes the *exit* IP for selected destinations, which is what bypasses
  Google / OpenAI / Spotify IP restrictions.

Installing WARP on the Iran server therefore does not "improve" the tunnel;
it only changes the exit of configs that actually leave from Iran.


## 3.3 Why a SOCKS5 inbound was not usable (1.0.17)

1.0.17 added a raw `socks` inbound to the Iran Core config. PasarGuard's
`GET /api/host/` creation validates `inbound_tag` against
`core_manager.get_inbounds()` (built from Core configs), and the subscription
generates client links from the inbound's protocol. A `socks` inbound produces
no usable v2rayNG / v2rayN config and no normal Host, so the user could not
create a host with it. From 1.0.18 the dedicated inbound is a clone of a real
proxy inbound; `warp-inbound` also replaces any leftover 1.0.17 SOCKS inbound.


## 4. Both servers must run the script (1.0.19)

WARP terminates on the FOREIGN relay; the IRAN main panel only carries the
dedicated `WARP-DEDICATED` inbound and a `WARP-LINK` SOCKS outbound. Deleting
the FOREIGN WARP inbound/outbound/routing rule cuts the Iran WARP config. Menu
option 1 (`Install / Repair WARP`) installs on a fresh server and repairs on a
configured one; `warp-manager repair --yes` and `warp-manager warp-check` are
the non-destructive equivalents and must be run on BOTH servers (FOREIGN
first). Full per-server commands: [TWO-SERVERS.md](TWO-SERVERS.md) plus
`/opt/pasarguard-warp/SERVER-GUIDE.md` written locally by the script.
