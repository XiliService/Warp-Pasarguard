# PasarGuard Core Settings: exact JSON to paste

All snippets are generated for you in `/opt/pasarguard-warp/outbound/`.
This document explains what each file does and how to apply it manually.

## 0. Pick the right Core config

Core Settings can contain several configurations (one per node / backend).
Open the dashboard -> **Core Settings** and select the Core that is assigned
to the **node whose traffic should use WARP** (for `tunnel` configs: the
foreign NL/DE/PL node). Editing a Core assigned to the Iran server will not
affect the tunnel configs.

If `--panel-url` was supplied, the tool does all of this through the API and
shows a diff summary before writing.

---

## 1. Single WARP tunnel, selected domains

`outbounds.json`:

```json
[
  {
    "tag": "warp",
    "protocol": "wireguard",
    "settings": {
      "secretKey": "<PRIVATE_KEY from wgcf-profile.conf>",
      "DNS": "1.1.1.1",
      "address": ["172.16.0.2/32", "2606:4700:110:xxxx:xxxx:xxxx:xxxx:xxxx/128"],
      "peers": [
        {
          "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "endpoint": "engage.cloudflareclient.com:2408",
          "allowedIPs": ["0.0.0.0/0", "::/0"]
        }
      ],
      "kernelMode": false,
      "mtu": 1280
    }
  }
]
```

Paste the object at the **end** of the `outbounds` array (keep your existing
first outbound first, otherwise WARP becomes the default).

`routing-rules.json` -> paste at the **top** of `routing.rules`:

```json
[
  {
    "type": "field",
    "outboundTag": "warp",
    "domain": ["geosite:google", "openai.com", "ai.com",
               "ipinfo.io", "iplocation.net", "spotify.com"]
  }
]
```

For the **kernel** backend replace the outbound with:

```json
{
  "tag": "warp",
  "protocol": "freedom",
  "streamSettings": { "sockopt": { "tcpFastOpen": true, "interface": "warp" } }
}
```

Save. The panel pushes the new config to the node; recent node versions
hot-apply outbound/routing changes without restarting Xray.

---

## 2. All traffic through WARP

Select `--routing all` (or the corresponding menu option). No routing rule is
generated; instead place the WARP outbound **first** in `outbounds`, so it
becomes the default outbound for unmatched traffic.

Warning: this also affects traffic initiated by the node itself (API calls,
geofile downloads, telemetry). Prefer the domain-scoped version.

---

## 3. Three IPs / three locations

With `--binding per-ip --labels nl,de,pl` the tool generates three outbounds:

```json
[
  { "tag": "warp-nl", "sendThrough": "203.0.113.10", "protocol": "wireguard", ... },
  { "tag": "warp-de", "sendThrough": "203.0.113.11", "protocol": "wireguard", ... },
  { "tag": "warp-pl", "sendThrough": "203.0.113.12", "protocol": "wireguard", ... }
]
```

`balancers.json` -> paste into `routing.balancers`:

```json
[
  {
    "tag": "warp-pool",
    "selector": ["warp-nl", "warp-de", "warp-pl"],
    "strategy": { "type": "random" }
  }
]
```

`routing-rules.json` -> paste at the top of `routing.rules`:

```json
[
  {
    "type": "field",
    "balancerTag": "warp-pool",
    "domain": ["geosite:google", "openai.com", "ai.com",
               "ipinfo.io", "iplocation.net", "spotify.com"]
  }
]
```

### Deterministic mapping instead of a balancer

If each location has its own inbound (or its own user group), replace the
balancer and the rule above with three rules:

```json
[
  {
    "type": "field",
    "inboundTag": ["inbound-nl"],
    "outboundTag": "warp-nl",
    "domain": ["geosite:google", "geosite:openai"]
  },
  {
    "type": "field",
    "inboundTag": ["inbound-de"],
    "outboundTag": "warp-de",
    "domain": ["geosite:google", "geosite:openai"]
  },
  {
    "type": "field",
    "inboundTag": ["inbound-pl"],
    "outboundTag": "warp-pl",
    "domain": ["geosite:google", "geosite:openai"]
  }
]
```

Inbound tags come from the panel's inbound list; `inboundTag` selectors can
also be combined with `user` selectors when the panel keys users by numeric
ID. Do not create three catch-all rules with empty `domain` arrays: only the
first one would ever match.

---

## 4. Docker node container (Xray backend)

On the node, add the following under the service that runs Xray (the tool
does this automatically with a backup):

```yaml
services:
  node:
    image: pasarguard/node:latest
    network_mode: host
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    security_opt:
      - seccomp=unconfined
      - systempaths=unconfined
      - apparmor=unconfined
```

Then recreate the container (a restart is not enough for `devices`):

```bash
cd /opt/pg-node
docker compose up -d
docker compose config >/dev/null   # syntax check
```

`kernel` backend does not need this, but the `wg-quick@warp` unit must run on
the same host as Xray.

---

## 5. Verification

From a client using a `tunnel` config:

```bash
curl https://www.cloudflare.com/cdn-cgi/trace
# expect warp=on (or warp=plus) and a Cloudflare egress IP
curl https://ipinfo.io/json
```

On the exit node:

```bash
warp-manager status
warp-manager logs
tcpdump -ni eth0 'udp port 2408'      # WARP handshake packets
wg show warp latest-handshakes         # kernel backend only
```

---

## 6. Rollback

1. Remove the WARP object(s) from `outbounds`.
2. Remove the WARP rule(s) from `routing.rules` and `warp-pool` from
   `routing.balancers`.
3. Save; the panel notifies the nodes.
4. If the API integration was used, `warp-manager remove` performs steps 1-3
   automatically. A full pre-change snapshot is stored in
   `/opt/pasarguard-warp/backups/panel-core-<id>-<timestamp>.json`.

Restoring from a snapshot through the API:

```bash
jq '{ name: .name, config: .config, type: .type,
      exclude_inbound_tags: .exclude_inbound_tags,
      fallbacks_inbound_tags: .fallbacks_inbound_tags }' \
   /opt/pasarguard-warp/backups/panel-core-1-YYYYmmdd-HHMMSS.json \
   > /tmp/restore.json

curl -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     --data-binary @/tmp/restore.json \
     "https://panel.example.com/api/core/1?restart_nodes=true"
```
