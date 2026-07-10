# GFC Proxy Data Plane — Sing-box Architecture (Authoritative)

**Status:** Single source of truth for all GFC sing-box configuration (Client + Forward Node).  
**Scope:** GFC Client gateway (`kernel-split` production default) and GFC Forward Node.  
**Supersedes:** Conflicting sing-box descriptions in `GATEWAY_CORE.md`, `ARCHITECTURE.md`, and ad-hoc generator comments.

If generated `sing-box.json` differs from this document, **the generator is wrong** — not this document.

**Companion:** [`docs/NFT_ARCHITECTURE.md`](NFT_ARCHITECTURE.md) (mark, TUN ingress), [`docs/UNBOUND_ARCHITECTURE.md`](UNBOUND_ARCHITECTURE.md) (DNS).

---

## 1. Change control

| Action | Required |
|--------|----------|
| Add/remove/reorder route rules (kernel-split) | User approval + update this file |
| Add/remove/reorder forward node client-ingress route rules | User approval + update this file |
| Rename outbound / inbound tags | Architecture review + user approval |
| Enable TUN `auto_route` / `auto_redirect` on Client | **Forbidden** |
| Add `direct` to `proxy-prefer` urltest outbounds | **Forbidden** on open-WAN gateways |
| Move CN/IP split from nft to sing-box geo (kernel-split) | **Forbidden** |
| Change default VLESS/Reality constants | User approval + cross-node contract update |
| Use `route.user` for VLESS per-line routing on Forward Node | **Forbidden** — use `auth_user` |

---

## 2. Data plane principles (fixed)

### GFC Client — `GFC_ROUTING_SCHEME=kernel-split` (default, validated `v0.3.0`)

```
LAN / local process
  → nft classification (TO_CN / bypass / ext_const / mark 0x2023)
  → CN / private / bypass → WAN direct (never enters sing-box)
  → international → ip rule table 2022 → gfctun
  → sing-box inbound tun-in (gvisor)
  → route rules (bypass → direct; intl → proxy-prefer)
  → outbound proxy (VLESS Reality) bind_interface <wan>
  → Forward Node :8443
```

**Sing-box does not decide CN vs international IP split** in kernel-split. That is **nft only**.

### GFC Forward Node

```
Inbound (TPROXY iface)
  → nft TPROXY → sing-box tproxy-in
  → route → socks-* / direct
  → Internet

Client ingress (VLESS Reality)
  → inbound vless-reality-in
  → route.auth_user client-{lineId} → outbound client-{lineId} (SOCKS) or direct
  → route.final direct (unmatched / unknown user — never SOCKS)
```

**Validated (2026-07):** per-line egress MUST use `auth_user`, not `user`. Using `route.user` matches Linux process UID and silently misses all VLESS users; traffic then falls through to `final` (previously mis-set to first SOCKS outbound).

---

## 3. Routing schemes

| Scheme | Env | Client sing-box role | Status |
|--------|-----|----------------------|--------|
| `kernel-split` | `GFC_ROUTING_SCHEME=kernel-split` | TUN egress only; nft splits | **Production default** |
| `byst-redirect` | `GFC_ROUTING_SCHEME=byst-redirect` | redirect :11800 + TUN UDP | Legacy / validation |
| `tun-all` | (legacy gen-nft) | Full TUN + geo in sing-box | Legacy — not aligned |
| Idle | No activation / empty bundle | Empty inbounds, final direct | Aligned |

This document **normatively defines `kernel-split`** unless a section explicitly labels another scheme.

---

## 4. GFC Client — mandatory constants

| Constant | Value | Override |
|----------|-------|----------|
| TUN interface | `gfctun` | `GFC_TUN_INTERFACE` |
| TUN address | `172.19.0.1/30` | Approval required |
| TUN stack | `gvisor` | Approval required |
| TUN MTU | `1500` | Approval required |
| Policy mark | `0x2023` | `GFC_POLICY_MARK` |
| Policy table | `2022` | `GFC_POLICY_TABLE` |
| VLESS port | `8443` | Bundle node.port |
| VLESS flow | `xtls-rprx-vision` | Bundle |
| Reality SNI | `www.cloudflare.com` | Bundle vless.serverName |
| Clash API | `127.0.0.1:9090` | Active config only |
| Redirect port (byst only) | `11800` | `GFC_REDIRECT_PORT` |

WAN interface: **runtime discovery** — `GFC_WAN_IFACE` / netlink. Never hardcode `eth0` in JSON.

---

## 5. GFC Client — mandatory inbound tags

### kernel-split (production)

| Tag | Type | Required fields |
|-----|------|-----------------|
| `tun-in` | `tun` | `interface_name: gfctun`, `auto_route: false`, `strict_route: false`, `stack: gvisor` |

### byst-redirect (legacy)

| Tag | Type | Notes |
|-----|------|-------|
| `tcp-in` | `redirect` | `listen_port: 11800`, `sniff: false` |
| `tun-in` | `tun` | Same as kernel-split |

### Forbidden on Client TUN inbound

- `auto_route: true`
- `strict_route: true`
- `auto_redirect` (any form)
- `stack: system` without architecture review (routing loop risk with fwmark → gfctun)

---

## 6. GFC Client — mandatory outbound tags

### kernel-split — outbounds list order

| Order | Tag | Type | Purpose |
|-------|-----|------|---------|
| 1 | `direct-local` | `direct` | Loopback / no bind |
| 2 | `direct` | `direct` | `bind_interface: <wan>` — bypass & handshake path |
| 3 | `proxy` | `vless` | Primary VLESS Reality |
| 4 | `proxy-group` | `selector` | **Only if** multiple nodes in bundle |
| 5 | `proxy-prefer` | `urltest` | Health-check wrapper for TUN traffic |

Route rules reference `direct`, `proxy`, or `proxy-prefer` — **not** `direct-local` except implicit.

### VLESS outbound (`proxy`) — mandatory shape

```json
{
  "type": "vless",
  "tag": "proxy",
  "server": "<forward-node-ip>",
  "server_port": 8443,
  "uuid": "<from-bundle>",
  "flow": "xtls-rprx-vision",
  "bind_interface": "<wan-iface>",
  "tls": {
    "enabled": true,
    "server_name": "www.cloudflare.com",
    "utls": { "enabled": true, "fingerprint": "chrome" },
    "reality": {
      "enabled": true,
      "public_key": "<from-bundle>",
      "short_id": "<from-bundle>"
    }
  }
}
```

Must match Forward Node inbound Reality keys (control plane contract).

### `proxy-prefer` — mandatory semantics (validated behavior)

```json
{
  "type": "urltest",
  "tag": "proxy-prefer",
  "outbounds": ["proxy"],
  "url": "https://www.gstatic.com/generate_204",
  "interval": "1m",
  "tolerance": 100
}
```

| Rule | Rationale |
|------|-----------|
| `outbounds` contains **only** `proxy` (or `proxy-group`) | Open WAN: adding `direct` makes urltest pick faster direct → leaks proxy traffic to eth0 |
| No `direct` fallback inside urltest | Kernel already sent flow to TUN; sing-box must not second-guess |
| VLESS failure → connections **fail** | Acceptable trade-off vs silent direct leak; auto-failover needs external watchdog |

Override env: `GFC_PROXY_HEALTH_URL`, `GFC_PROXY_HEALTH_INTERVAL`.

**Explicit non-goal (current release):** automatic failover to WAN direct when VLESS is down.

---

## 7. GFC Client — mandatory route rules (`kernel-split`)

**Order is API.** First match wins.

| # | Match | Outbound | Notes |
|---|-------|----------|-------|
| 1 | `ip_cidr` bypass set | `direct` | Node IP + control plane + `GFC_*_BYPASS` env |
| 2 | `ip_is_private: true` | `direct` | RFC1918 inside TUN path |
| 3 | `ip_cidr` domestic DNS + `port: [53]` | `direct` | 223.5.5.5, 223.6.6.6, 119.29.29.29, 114.114.114.114 |
| 4 | `ip_cidr` intl DNS (`ext_const`) | `proxy-prefer` | Default 1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4; env `GFC_EXT_CONST_IPS` |
| 5 | catch-all | `proxy-prefer` | All other TUN traffic |

### `route` block

```json
{
  "auto_detect_interface": false,
  "default_interface": "<wan-iface>",
  "final": "direct",
  "rules": [ "... ordered as above ..." ]
}
```

- `final: direct` is **mandatory** for kernel-split (nft already filtered; unmatched TUN traffic should not exist).
- **No** `rule_set` / `geoip-cn` / `geosite-cn` in kernel-split active config.

### bypass_ip population (route rule #1)

Sources (union, dedupe):

- Forward node `node.address`
- `controlPlaneServers` from bundle
- Env: `GFC_POLICY_BYPASS_IPS`, `GFC_NODE_BYPASS`, `GFC_CP_BYPASS`, `SERVER_URL`, `SERVER_URL_FALLBACK`

Must stay consistent with nft `bypass_ip` set (same IPs, different layer).

---

## 8. GFC Client — experimental / management

Active (non-idle, non-byst) config includes:

```json
"experimental": {
  "cache_file": { "enabled": false },
  "clash_api": {
    "external_controller": "127.0.0.1:9090",
    "secret": ""
  }
}
```

Idle config: empty `inbounds`, single `direct` outbound, `final: direct` — no Clash API.

---

## 9. GFC Forward Node — mandatory tags

### TPROXY dataplane

| Tag | Type | Purpose |
|-----|------|---------|
| `tproxy-in` | `tproxy` | Transparent proxy ingress |
| `direct` | `direct` | WAN egress / bypass |
| `socks-N` | `socks` | Per-line SOCKS outbound |
| `dns-*` | `https` (DoH) | DNS via SOCKS detour when healthy |
| `dns-direct` | `https` (DoH) | Intl DNS via WAN when SOCKS down |
| `local-dns` | `local` | System resolver |

Route rule order: **bypass `ip_cidr` → direct** first; then sniff on `tproxy-in`; DNS hijack for TPROXY DNS.

### Client ingress only (`client-ingress` mode)

Production layout when the forward node serves **GFC Client gateways** via VLESS Reality only (no VyOS TPROXY `dataplane.rules`). Generator entry: `_render_client_ingress_only` in `gfc-platform/node-agent/node_agent/singbox.py`.

| Tag | Type | Purpose |
|-----|------|---------|
| `vless-reality-in` | `vless` | Client gateway connects here |
| `client-{lineId}` | `socks` | Per client line with `socks_profile_id` (tag equals VLESS `users[].name`) |
| `direct` | `direct` | Node WAN egress / bypass |

| Constant | Default |
|----------|---------|
| `listen_port` | `8443` |
| `server_name` | `www.cloudflare.com` |
| `flow` | `xtls-rprx-vision` |
| Reality `dest` | `www.cloudflare.com:443` |

#### VLESS user identity (control plane → sing-box)

| Field | Source |
|-------|--------|
| `users[].name` | `client-{line.id}` — database `Line.id`, **not** TID string |
| `users[].uuid` | `line.client_uuid` |
| SOCKS vs direct egress | `line.socks_profile_id` set → SOCKS outbound tag `client-{lineId}`; null → `direct` |

Client device binding (`device.line_id`) selects which `uuid` the gateway uses; forward node keeps **all** enabled client lines on that node in one inbound.

#### Mandatory route rule order (client-ingress-only)

**Order is API.** First match wins.

| # | Match | Outbound | Notes |
|---|-------|----------|-------|
| 1 | `ip_cidr` bypass set | `direct` | Node public IP + SOCKS host IPs from bundle |
| 2 | `inbound: vless-reality-in` + `auth_user: [client-{lineId}]` | `client-{lineId}` or `direct` | Per-line egress; `action: route` required (sing-box ≥ 1.11) |

#### Mandatory `route` block (client-ingress-only)

```json
{
  "auto_detect_interface": false,
  "default_interface": "<wan-iface>",
  "final": "direct",
  "rules": [ "... ordered as above ..." ]
}
```

| Field | Rule |
|-------|------|
| `final` | **Always** `direct`. Unmatched VLESS users must egress via node WAN, **never** silently proxy through another line's SOCKS. |
| `auto_detect_interface` | **Always** `false` for client-ingress-only. |
| `default_interface` | Runtime WAN from `resolve_snat_iface()` — env `GFC_SNAT_IFACE` or `ip -4 route show default` dev. **Never** hardcode `eth0` / `ens160` in generator output. |

#### `auth_user` vs `user` (critical)

| Route field | Matches | Use for VLESS per-line routing? |
|-------------|---------|--------------------------------|
| `auth_user` | Inbound authenticated username (`users[].name`, e.g. `client-2`) | **Yes — mandatory** |
| `user` | Linux process owner on local system | **No — forbidden** for client ingress |

Example per-line rule (validated):

```json
{
  "inbound": "vless-reality-in",
  "auth_user": ["client-2"],
  "action": "route",
  "outbound": "direct"
}
```

#### Reference shape (two client lines)

```json
{
  "route": {
    "auto_detect_interface": false,
    "default_interface": "<wan-iface>",
    "final": "direct",
    "rules": [
      {
        "ip_cidr": ["<node-public>/32", "<socks-host>/32"],
        "outbound": "direct"
      },
      {
        "inbound": "vless-reality-in",
        "auth_user": ["client-1"],
        "action": "route",
        "outbound": "client-1"
      },
      {
        "inbound": "vless-reality-in",
        "auth_user": ["client-2"],
        "action": "route",
        "outbound": "direct"
      }
    ]
  }
}
```

#### Mixed mode (TPROXY + client ingress)

When `dataplane.rules` and `clientIngress.users` coexist, append VLESS inbound and insert sniff on `vless-reality-in`; per-user rules still use **`auth_user`**. TPROXY `route` block keeps `auto_detect_interface: true` and its own `final` semantics; client-ingress-only block above applies to the VLESS-only deployment.

Generator: `gfc-platform/node-agent/node_agent/singbox.py` (`_vless_auth_user_route`, `_client_ingress_route_block`).

---

## 10. Cross-layer contracts

| Contract | Client | Forward Node |
|----------|--------|--------------|
| VLESS port | outbound `server_port: 8443` | inbound `listen_port: 8443` |
| Reality SNI | `www.cloudflare.com` | `server_name` / `serverNames[0]` |
| UUID / keys | From control plane bundle | `clientIngress.users` (`name` = `client-{lineId}`) |
| Per-line egress | N/A (always VLESS to node) | `auth_user` → `client-{lineId}` SOCKS or `direct` |
| Forward node IP | In nft `bypass_ip` + route bypass | In sing-box bypass `ip_cidr` + nft `bypass_ip` |
| Intl DNS IPs | nft `ext_const` + route rule #4 | N/A (node uses DoH in sing-box dns) |

---

## 11. Forbidden changes

AI / generators must **never** (without approval):

- Enable sing-box `auto_route` / `auto_redirect` on Client gateway
- Add `direct` to `proxy-prefer` outbounds (open-WAN gateways)
- Reintroduce GeoIP/GeoSite split in `kernel-split` active config
- Use `meta skuid` / process-based bypass in route rules instead of `ip_cidr` bypass
- Point VLESS `bind_interface` at `gfctun`
- Change `route.final` to `proxy` or `proxy-prefer` in kernel-split
- On Forward Node client-ingress: use `route.user` for VLESS per-line routing (must use `auth_user`)
- On Forward Node client-ingress: set `final` to a SOCKS outbound tag (`client-{lineId}`) when any SOCKS line exists
- On Forward Node client-ingress: set `auto_detect_interface: true` (must be `false`)
- Hardcode `default_interface` to a fixed NIC name (`eth0`, `ens160`, …) in generators
- Run sing-box-owned nftables that conflict with `inet gfc` tables
- Use deprecated Shadowsocks / legacy outbound schemas

---

## 12. Code generation requirements

Generated `sing-box.json` must:

- Pass `sing-box check -c`
- Use renderer: `gfc-client/internal/render/singbox/singbox.go` (Client)
- Use renderer: `gfc-platform/node-agent/node_agent/singbox.py` (Forward Node)
- Preserve outbound tag names and route rule order for kernel-split and client-ingress-only
- Forward client-ingress: emit `auth_user` rules; `final: direct`; WAN via `resolve_snat_iface()`
- Set `bind_interface` on VLESS and WAN-bound `direct` (Client)
- Write config `0640` owned root:`GFC_SINGBOX_USER` group (Client)
- Support idle vs active profiles via orchestrator (Client) / node-agent apply (Forward Node)

---

## 13. Implementation alignment

| Component | Generator | kernel-split | Notes |
|-----------|-----------|--------------|-------|
| Client active | `singbox.go` | Aligned | `v0.3.0` proxy-only urltest |
| Client tests | `singbox_route_test.go` | Aligned | |
| Forward TPROXY | `node_agent/singbox.py` | Aligned | |
| Forward client-ingress | `node_agent/singbox.py` | Aligned | `auth_user` + `final: direct` validated 2026-07 |
| `GATEWAY_CORE.md` | — | Aligned |
| `tun-all` / geo split | `singbox.go` non-kernel path | Legacy | Requires scheme label |
| Auto failover direct | — | **Not implemented** | By design in v0.3.0 |

---

## 14. Verification commands

### GFC Client (kernel-split)

```sh
# Config check
sing-box check -c /etc/gfc-client/sing-box.json

# kernel-split shape
python3 - <<'PY'
import json
c = json.load(open("/etc/gfc-client/sing-box.json"))
tun = next(i for i in c["inbounds"] if i.get("type")=="tun")
assert tun.get("auto_route") is False
assert tun.get("interface_name") == "gfctun"
pp = next(o for o in c["outbounds"] if o.get("tag")=="proxy-prefer")
assert pp["outbounds"] == ["proxy"] or pp["outbounds"] == ["proxy-group"]
assert c["route"]["final"] == "direct"
assert not c["route"].get("rule_set")
print("kernel-split OK")
PY

# Runtime
curl -s http://127.0.0.1:9090/proxies/proxy-prefer   # now: proxy
curl -s 'http://127.0.0.1:9090/proxies/proxy/delay?timeout=10000&url=https://www.gstatic.com/generate_204'

# Egress path — eth0 should show NODE:8443 for intl traffic, not target IP
sh /usr/share/gfc-client/deploy/check-vless.sh
```

### GFC Forward Node (client-ingress-only)

```sh
sing-box check -c /etc/gfc-node/sing-box.json

python3 - <<'PY'
import json
c = json.load(open("/etc/gfc-node/sing-box.json"))
route = c["route"]
assert route.get("final") == "direct", route.get("final")
assert route.get("auto_detect_interface") is False
vless = next(i for i in c["inbounds"] if i.get("tag") == "vless-reality-in")
user_rules = [
    r for r in route.get("rules", [])
    if r.get("inbound") == "vless-reality-in" and r.get("action") == "route"
]
assert user_rules, "missing vless per-user route rules"
for r in user_rules:
    assert "auth_user" in r and "user" not in r, r
    assert r["auth_user"][0].startswith("client-"), r
names = {u["name"] for u in vless["users"]}
assert names == {r["auth_user"][0] for r in user_rules}
print("forward client-ingress OK", sorted(names))
PY

# Runtime: client-2 should log [client-2] → outbound/direct, not client-1 SOCKS
tail -f /var/log/gfc-node/sing-box.log
```
