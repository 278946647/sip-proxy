# GFC Network Data Plane — NFT Architecture (Authoritative)

**Status:** Single source of truth for all GFC nftables rules.  
**Scope:** GFC Client (ImmortalWrt / Ubuntu gateway) and GFC Forward Node.  
**Supersedes:** Any conflicting nft descriptions in `GFC_GATEWAY_CORE.md`, `ARCHITECTURE.md`, generator comments, or AI-generated shortcuts.

**Companion:** [`docs/UNBOUND_ARCHITECTURE.md`](UNBOUND_ARCHITECTURE.md) · [`docs/SINGBOX_ARCHITECTURE.md`](SINGBOX_ARCHITECTURE.md)

If generated runtime rules differ from this document, **the generator is wrong** — not this document.

---

## 1. Change control

| Action | Required |
|--------|----------|
| Add/remove/reorder a rule | User explicit approval in chat or issue |
| Rename table / chain / set | Architecture review + user approval |
| Change mark values or hook priority | User approval + update this file first |
| Replace `bypass_ip` / `TO_CN` with skuid bypass | **Forbidden** |

See also: `.cursor/rules/nft-no-change-without-approval.mdc`

---

## 2. Data plane principles (fixed — do not alter)

### GFC Client

```
LAN
 ↓
PREROUTING (ct mark)        chain: prerouting_mangle_ct
 ↓
PREROUTING (classification) chain: prerouting_mangle_route
 ↓
FORWARD                     chain: gfc_forward
 ↓
WAN

Local process:
OUTPUT → policy routing → WAN / gfctun
```

### GFC Forward Node

```
Inbound (TPROXY iface)
 ↓
TPROXY → sing-box → SOCKS → Reality → Internet

Local egress:
OUTPUT → policy routing → WAN
```

No implementation may change this packet flow.

**IPv4:** Current validated rules use `ip` / `inet` with IPv4 matches. IPv6 requires architecture review before changes.

---

## 3. Mark lifecycle (Client — mandatory)

```
LAN packet:
  PREROUTING  ct mark = 0x2023
       ↓
  meta mark (sync from ct mark where applicable)
       ↓
  FORWARD
       ↓
  conntrack
       ↓
  OUTPUT
       ↓
  Policy route (table 2022 → gfctun)
```

- Never replace ct mark with meta mark only.
- Never remove conntrack synchronization.
- Always keep **ct mark** and **meta mark** synchronized per the reference rules below.

---

## 4. Mark values (defaults)

| Role | Mark | Policy table |
|------|------|----------------|
| Client — proxy traffic | `0x00002023` | `2022` → `gfctun` |
| Forward Node — local egress | `0x00000001` | `1` → default via WAN |
| Forward Node — TPROXY traffic | `0x00000100` | `100` → local default dev `lo` |

Override only via explicit deployment configuration; values must stay consistent within one deployment.

All `fwmark` references in policy routing use hexadecimal notation (`0x` prefix).

---

## 5. Hook priority (mandatory order)

```
DNS Hijack     dstnat   priority -100
       ↓
Connection Mark mangle  priority -150   (client: prerouting_mangle_ct)
       ↓
Classification filter  priority 0      (client: prerouting_mangle_route)
       ↓
Forward        filter
       ↓
Output route   route hook output, priority filter
```

Changing hook priority is prohibited without user approval and an update to this file.

---

## 6. GFC Client — mandatory tables

| Table | Family | Purpose |
|-------|--------|---------|
| `nat` | `inet` | SNAT / masquerade on WAN |
| `gfc_dns_hijack` | `inet` | LAN DNS redirect to local resolver (:53) |
| `gfc` | `inet` | Classification, forward sync, output routing |

Do not merge tables. Do not rename tables.

---

## 7. GFC Client — mandatory chains

| Chain | Hook | Priority | Type |
|-------|------|----------|------|
| `postrouting` | postrouting | srcnat | in table `inet nat` |
| `prerouting` | prerouting | dstnat (-100) | in table `inet gfc_dns_hijack` |
| `prerouting_mangle_ct` | prerouting | mangle (-150) | in table `inet gfc` |
| `prerouting_mangle_route` | prerouting | filter (0) | in table `inet gfc` |
| `gfc_forward` | forward | filter | in table `inet gfc` |
| `output_mangle_route` | output | route / filter | in table `inet gfc` |

Chain names are API. Never rename.

---

## 8. GFC Client — mandatory sets

| Set | Properties | Purpose |
|-----|------------|---------|
| `TO_CN` | `ipv4_addr`, interval | China IP — always direct WAN |
| `TO_RFC1918` | `ipv4_addr`, interval | Private / LAN — never proxy |
| `bypass_ip` | `ipv4_addr`, interval | Highest-priority whitelist — never proxy |
| `ext` | `ipv4_addr`, **timeout**, dynamic add/delete | International / proxy destinations |
| `ext_const` | `ipv4_addr` | Fixed international DNS upstream IPs |

`ext` must support runtime updates and survive reloads. Never replace with static-only rules.

**Population:** `TO_CN` from deployment China IP list; `bypass_ip` from control-plane bundle (forward node, controller, China DNS, health check, Reality handshake target, etc.). Do not hardcode deployment IPs in generators — use runtime configuration.

---

## 9. GFC Client — reference rules

Interfaces and CIDRs below use **example names** (`eth0`, `br-lan`, `192.168.1.0/24`). Generators must discover WAN/LAN at runtime (UCI / netlink / env). Never hardcode `eth0` / `192.168.1.0/24` as the only supported layout.

```nft
# 1. NAT — SNAT / masquerade
add table inet nat
add chain inet nat postrouting { type nat hook postrouting priority srcnat; policy accept; }
add rule inet nat postrouting oifname "<wan_iface>" masquerade

# 2. DNS hijack (LAN → local :53)
add table inet gfc_dns_hijack
add chain inet gfc_dns_hijack prerouting { type nat hook prerouting priority dstnat; policy accept; }
add rule inet gfc_dns_hijack prerouting iifname "<lan_iface>" udp dport 53 redirect to :53
add rule inet gfc_dns_hijack prerouting iifname "<lan_iface>" tcp dport 53 redirect to :53

# 3. Main classification table
add table inet gfc

# 4. TO_CN
add set inet gfc TO_CN { type ipv4_addr; flags interval; }
# elements loaded at runtime from China IP list

# 5. TO_RFC1918
add set inet gfc TO_RFC1918 { type ipv4_addr; flags interval; }
add element inet gfc TO_RFC1918 { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }

# 6. bypass_ip
add set inet gfc bypass_ip { type ipv4_addr; flags interval; }
# elements loaded at runtime from deployment config

# 7. ext (dynamic, timeout)
add set inet gfc ext { type ipv4_addr; size 262144; timeout 2h; }

# 8. ext_const
add set inet gfc ext_const { type ipv4_addr; }
add element inet gfc ext_const { 1.0.0.1, 1.1.1.1, 8.8.4.4, 8.8.8.8 }

# 9. prerouting_mangle_ct
add chain inet gfc prerouting_mangle_ct { type filter hook prerouting priority mangle; policy accept; }
add rule inet gfc prerouting_mangle_ct iifname "<lan_iface>" ct mark set 0x00002023 accept

# 10. prerouting_mangle_route
add chain inet gfc prerouting_mangle_route { type filter hook prerouting priority filter; policy accept; }
add rule inet gfc prerouting_mangle_route iifname "<lan_iface>" ip daddr { 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
add rule inet gfc prerouting_mangle_route iifname "<lan_iface>" ip daddr <lan_subnet> return
add rule inet gfc prerouting_mangle_route iifname "<lan_iface>" udp dport { 53, 67, 68, 123 } return
add rule inet gfc prerouting_mangle_route iifname "<lan_iface>" ip daddr @bypass_ip return
add rule inet gfc prerouting_mangle_route iifname "<lan_iface>" ip daddr @ext_const ct mark 0x00002023 meta mark set ct mark return
add rule inet gfc prerouting_mangle_route iifname "<lan_iface>" ip daddr @TO_CN return
add rule inet gfc prerouting_mangle_route iifname "<lan_iface>" ct mark 0x00002023 meta mark set ct mark

# 11. gfc_forward
add chain inet gfc gfc_forward { type filter hook forward priority filter; policy accept; }
add rule inet gfc gfc_forward ct state established,related accept
add rule inet gfc gfc_forward ct state new ip saddr <lan_subnet> ct mark set meta mark
add rule inet gfc gfc_forward accept

# 12. output_mangle_route
add chain inet gfc output_mangle_route { type route hook output priority filter; policy accept; }
add rule inet gfc output_mangle_route meta mark != 0x00000000 return
add rule inet gfc output_mangle_route tcp dport 212 return
add rule inet gfc output_mangle_route ip daddr @TO_RFC1918 return
add rule inet gfc output_mangle_route ip daddr 127.0.0.0/8 return
add rule inet gfc output_mangle_route ip daddr @TO_CN return
add rule inet gfc output_mangle_route ip daddr @bypass_ip counter return
add rule inet gfc output_mangle_route meta mark set 0x00002023
add rule inet gfc output_mangle_route ct mark set meta mark
```

### Client business rules (never proxy)

Controller, forward node, China DNS, SSH (port **212**), LAN local, RFC1918, China IP (`TO_CN`), health check, Reality handshake — enforced at nft layer via `bypass_ip` and `TO_CN`.

**Forbidden:** skuid-based bypass for sing-box or DNS daemons as a substitute for `bypass_ip` or `TO_CN`.

### Routing mode (`split` vs `global`)

Traffic mode is configured per device as `routingScheme` in the control-plane config bundle (`split` | `global`). The client writes `/etc/gfc-client/routing-mode.json` (`{"mode":"split"|"global"}`) and regenerates nft rules.

| Mode | `@TO_CN return` in `prerouting_mangle_route` / `output_mangle_route` | IP traffic |
|------|------------------------------------------------------------------------|------------|
| `split` (default) | **Present** — China IP stays on WAN | CN direct; international → mark → gfctun |
| `global` | **Omitted** — China IP gets mark `0x2023` | All public IP (except bypass) → gfctun → VLESS |

**Unchanged in both modes:** `bypass_ip`, RFC1918, LAN CIDR, DNS/DHCP/NTP port returns, `ext_const`, fwmark → table `2022` → `gfctun`, DNS hijack → unbound `:53`. LAN DNS resolution (domestic/international upstream split in unbound) is **not** tied to routing mode.

**Global mode requirements:** `bypass_ip` must include forward-node and control-plane IPs (bundle `node.address` + `controlPlaneServers`) so VLESS can establish on WAN.

---

## 10. GFC Forward Node — mandatory tables

| Table | Family | Purpose |
|-------|--------|---------|
| `gfc-nat` | `ip` | WAN SNAT / masquerade |
| `gfc` | `inet` | TPROXY prerouting + output routing |

Do not merge tables. Do not rename tables.

---

## 11. GFC Forward Node — mandatory chains

| Chain | Hook | Notes |
|-------|------|-------|
| `postrouting` | postrouting | in table `ip gfc-nat` |
| `prerouting` | prerouting | rule order: **bypass → WAN return → TPROXY** |
| `output` | output | local egress mark + ct sync |

---

## 12. GFC Forward Node — mandatory sets

| Set | Purpose |
|-----|---------|
| `bypass_ip` | Whitelist — never TPROXY |

---

## 13. GFC Forward Node — reference rules

```nft
# 1. NAT
add table ip gfc-nat
add chain ip gfc-nat postrouting { type nat hook postrouting priority srcnat; policy accept; }
add rule ip gfc-nat postrouting oifname "<wan_iface>" masquerade

# 2. Main table
add table inet gfc

# 3. bypass_ip
add set inet gfc bypass_ip { type ipv4_addr; flags interval; }
# elements loaded at runtime

# 4. prerouting — order is mandatory
add chain inet gfc prerouting { type filter hook prerouting priority mangle; policy accept; }
add rule inet gfc prerouting meta mark 0x00000100 return
add rule inet gfc prerouting ip daddr { 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/8 } return
add rule inet gfc prerouting ip daddr @bypass_ip return
add rule inet gfc prerouting iifname "<wan_iface>" return
add rule inet gfc prerouting iifname "<tproxy_iface>" meta l4proto tcp meta mark set 0x00000100 tproxy ip to :12345 accept
add rule inet gfc prerouting iifname "<tproxy_iface>" meta l4proto udp meta mark set 0x00000100 tproxy ip to :12345 accept

# 5. output
add chain inet gfc output { type route hook output priority mangle; policy accept; }
add rule inet gfc output meta mark != 0x00000000 return
add rule inet gfc output tcp dport 212 return
add rule inet gfc output ip daddr { 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/8 } return
add rule inet gfc output ip daddr @bypass_ip return
add rule inet gfc output meta mark set 0x00000001
add rule inet gfc output ct mark set meta mark
add rule inet gfc output oifname "<wan_iface>" return
```

WAN masquerade must remain enabled.

---

## 14. Policy routing (mandatory)

### Client

```
fwmark 0x2023 → table 2022 → default dev gfctun
```

### Forward Node — local egress

```
fwmark 0x1 → table 1 → default dev <wan_iface>
```

### Forward Node — TPROXY reply path

```
fwmark 0x100 → table 100 → local default dev lo
```

Never modify table numbers or auto-create random tables without approval.

---

## 15. Code generation requirements

Generated nft code must:

- Keep chain order and rule order within each chain
- Preserve comments where present in reference templates
- Be idempotent (safe to re-apply)
- Support dynamic interfaces and LAN subnet
- Support runtime-generated sets (especially `ext` and `bypass_ip`)

Generated code must **never** simplify or replace this architecture with alternate schemes (e.g. `gfc_client_mangle`, `classify`-only chains, skuid bypass, or mark `0x1` for TPROXY on forward nodes).

---

## 16. Implementation alignment

| Component | Generator | Status |
|-----------|-----------|--------|
| GFC Client (kernel-split) | `gfc-client/deploy/gen-nft-policy.py` | Aligned (`inet gfc` architecture) |
| GFC Client (ImmortalWrt) | `gfc-client/deploy/immortalwrt/gfc-routing.sh` | Aligned for `kernel-split` |
| GFC Client DNS hijack | `gfc-client/deploy/lib-unbound-nft.sh` | Aligned (LAN prerouting only) |
| GFC Client NAT | `gfc-client/deploy/apply-network.sh` | Aligned (`inet nat`) |
| Forward Node | `gfc-platform/node-agent/node_agent/nft_render.py` | Aligned |
| Forward Node policy routes | `gfc-platform/node-agent/node_agent/routes.py` | Aligned (`0x100` / `0x1`) |

**Not aligned (legacy — requires separate approval to change or remove):**

- `GFC_ROUTING_SCHEME=tun-all` / `byst-redirect` in `gen-nft-policy.py` (scheme A/C)
- `inet gfc_client_filter` in `apply-network.sh` (INPUT/FORWARD firewall — out of nft data-plane scope)

---

## 17. Verification commands

```sh
# Client — expect tables: nat, gfc_dns_hijack, gfc
nft list tables
nft list table inet gfc
nft list chain inet gfc prerouting_mangle_ct
nft list chain inet gfc prerouting_mangle_route
nft list chain inet gfc gfc_forward
nft list chain inet gfc output_mangle_route

# Forward node — expect: ip gfc-nat, inet gfc with full prerouting order
nft list table inet gfc
nft list table ip gfc-nat
ip rule list
ip route show table 100
```

---

*Document version: 2026-07-03. Maintained by project owner. AI agents must read this file before any nft-related code change.*
