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

The important consequence: **the Core Settings JSON is authored on the Iran
panel, but it is executed by Xray on the foreign server.** A WireGuard WARP
outbound therefore makes its UDP connection to Cloudflare from the foreign
server, not from Iran.

## 3. Decision table

| Goal | Run `warp-manager` on | Backend | Notes |
| --- | --- | --- | --- |
| Cover `tunnel` configs (recommended) | **Foreign node** | `xray` | Panel pushes the outbound automatically; patch the node container's `docker-compose.yml` for TUN |
| Cover `tunnel` configs, Xray too old for WireGuard outbound | **Foreign node** | `kernel` | `/etc/wireguard/warp.conf` must exist on the node as well (official guide: repeat step 3 on the node) |
| Cover `direct` configs | Iran main panel server | `xray` | Riskier host: it carries the dashboard and all users |
| Cover `cdn` configs | Usually the origin behind the CDN | `xray` | WARP changes only the leg that actually leaves that machine |
| Only produce JSON snippets | Any machine (or a laptop) | any | `--target generator --dry-run`, no host changes |

Running the script on the Iran panel and expecting the `tunnel` configs to use
WARP is the most common mistake. The Iran Xray process forwards those
connections to the node; it does not open the final socket.

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
