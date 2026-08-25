# GFC Network Data Plane — NFT Architecture (Authoritative)

**Status:** Single source of truth for all GFC nftables rules.  
**Scope:** GFC Client (ImmortalWrt / Ubuntu gateway) and GFC Forward Node.  
**Supersedes:** Any conflicting nft descriptions in `GFC_GATEWAY_CORE.md`, `ARCHITECTURE.md`, generator comments, or AI-generated shortcuts.

**Companion:** [`docs/UNBOUND_ARCHITECTURE.md`](UNBOUND_ARCHITECTURE.md) · [`docs/SINGBOX_ARCHITECTURE.md`](SINGBOX_ARCHITECTURE.md) · [`docs/BYPASS_MODE.md`](BYPASS_MODE.md)

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

Packet flow is fixed. Only the **user ingress interface** and **match conditions** change with `proxy_mode`. Tables, chains, marks, and hook priorities do not change.

**Gateway (`proxy_mode=gateway`, default):**

```
LAN (customer + management)
 ↓
PREROUTING (ct mark)        chain: prerouting_mangle_ct
 ↓
PREROUTING (classification) chain: prerouting_mangle_route
 ↓
FORWARD                     chain: gfc_forward
 ↓
WAN / gfctun

Local process:
OUTPUT → policy routing → WAN / gfctun
```

**Bypass (`proxy_mode=bypass`) — ratified Option B:**

```
Customer hosts (GW = GFC WAN IP; saddr ∈ @customer_hosts) → WAN
Management hosts → LAN (independent subnet; never bridged to WAN; mini-gateway retained)
 ↓
PREROUTING (ct mark / classify) — same chains; WAN matches require saddr @customer_hosts
 ↓
FORWARD → WAN (China / non-proxy) or gfctun (international)

Local process:
OUTPUT → policy routing → WAN / gfctun   (identical to gateway)
```

LAN remains an independent management network for the life of the device. In bypass, LAN keeps **mini-gateway** capability (management hosts may use GFC as default gateway for domestic + cross-border).

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
User packet (gateway: iif LAN; bypass customer: iif WAN + saddr @customer_hosts):
  PREROUTING  ct mark = 0x2023 (only for matched user traffic)
       ↓
  meta mark (sync from ct mark where applicable; TO_CN / RFC1918 leave meta mark 0)
       ↓
  FORWARD
       ↓
  conntrack
       ↓
  OUTPUT (local) / policy route (fwmark 0x2023 → table 2022 → gfctun)
```

- Never replace ct mark with meta mark only.
- Never remove conntrack synchronization.
- Always keep **ct mark** and **meta mark** synchronized per the reference rules below.
- Bypass: never assign user ct mark to `fib daddr type { local, broadcast, multicast }`, `iifname gfctun`, or WAN packets whose `saddr` is outside `@customer_hosts`.

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
| `nat` | `inet` | SNAT / masquerade. Gateway: all `oif WAN`. Bypass: **only** `ip saddr <lan_subnet>` (management mini-gateway). |
| `gfc_dns_hijack` | `inet` | DNS redirect to local `:53`. Gateway: `iif LAN`. Bypass: `iif LAN` plus `iif WAN` + `saddr @customer_hosts` (with local-dest skip). |
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
| `customer_hosts` | `ipv4_addr`, interval | **Bypass only.** Sources allowed to be marked / DNS-hijacked on WAN. Populated from **device Web UI** (not control plane). |

`ext` must support runtime updates and survive reloads. Never replace with static-only rules.

**Population:** `TO_CN` from deployment China IP list; `bypass_ip` from control-plane bundle (forward node, controller, China DNS, health check, Reality handshake target, etc.). Do not hardcode deployment IPs in generators — use runtime configuration. `@customer_hosts` is local authoritative config written only via the device Web when entering bypass.

---

## 9. GFC Client — reference rules

Interfaces and CIDRs below use **example names** (`eth0`, `br-lan`, `192.168.1.0/24`). Generators must discover WAN/LAN at runtime (UCI / netlink / env). Never hardcode `eth0` / `192.168.1.0/24` as the only supported layout.

Placeholders:

| Token | Gateway | Bypass |
|-------|---------|--------|
| `<wan_iface>` | WAN device | Same; holds customer-assigned IP |
| `<lan_iface>` | Customer LAN / `br-lan` | **Management-only** LAN; never bridged to WAN |
| `<lan_subnet>` | Customer LAN CIDR | Management CIDR (mini-gateway SNAT source) |
| `@customer_hosts` | unused | Device-Web CIDR/host set (sources that use GFC as GW) |
| `<tun_iface>` | `gfctun` | `gfctun` |

`split` vs `global` applies to **both** proxy modes: `global` omits `@TO_CN return` in prerouting/output classify.

### 9.1 Gateway vs bypass — delta

| Item | Gateway (§9.2) | Bypass (§9.3, Option B) |
|------|----------------|-------------------------|
| User ingress | `iifname <lan_iface>` | Customer: `iif WAN` + `saddr @customer_hosts`. Management: keep `iif LAN` (mini-gateway). |
| WAN mark strategy | N/A | **Option B** — never mark all WAN new connections |
| `output_mangle_route` | As listed | **Identical** |
| Sets / marks / hooks / chain names | As listed | Same + set `customer_hosts` |
| Policy routing `0x2023` → `2022` → `gfctun` | On | **On** (disabling is a bug) |
| `inet nat` masquerade | `oifname <wan_iface>` | `oifname <wan_iface> ip saddr <lan_subnet>` only |
| DNS hijack | `iif LAN` | `iif LAN` + `iif WAN` + `@customer_hosts` (+ local return) |
| `gfc_forward` new-conn sync | `ip saddr <lan_subnet>` | `<lan_subnet>` **and** `@customer_hosts` |
| Customer WAN SNAT | Yes (via full masq) | **Forbidden** |
| WAN+LAN bridge | Optional | **Forbidden** |
| `rp_filter` on WAN | Strict OK | Loose (`2`) required for China hairpin |
| Mode switch write path | Device Web | Device Web **only**; control plane read-only |
| Switch safety | — | Confirm-within-timeout or rollback |

### 9.2 Gateway mode — reference rules

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

### 9.3 Bypass mode — reference rules (Option B, ratified 2026-08-20)

Same tables, chains, and mark `0x00002023` as §9.2. Differences are **match conditions**, set `customer_hosts`, and **one extra** `output_mangle_route` return for `@customer_hosts` (customer sources may be public WAN IPs; do not assume RFC1918). Remaining OUTPUT rules match §9.2.

Non-nft companions (mandatory with these rules):

- `net.ipv4.ip_forward=1`
- `net.ipv4.conf.<wan_iface>.rp_filter=2` (and `all.rp_filter=2` if it would override)
- Default route via customer-provided gateway on WAN
- Do not run a DHCP **server** toward the customer WAN L2
- Device Web must collect: bypass IP/mask/gateway + `@customer_hosts` before apply; empty set → refuse switch
- Confirm-within-timeout rollback after mode apply (especially WAN static)

```nft
# 1. NAT — masquerade management LAN only (mini-gateway).
#    Forbidden: bare oifname wan masquerade (customer hairpin SNAT → mark loops).
add table inet nat
add chain inet nat postrouting { type nat hook postrouting priority srcnat; policy accept; }
add rule inet nat postrouting oifname "<wan_iface>" ip saddr <lan_subnet> masquerade

# 2. DNS hijack — LAN unchanged; WAN only for @customer_hosts
add table inet gfc_dns_hijack
add chain inet gfc_dns_hijack prerouting { type nat hook prerouting priority dstnat; policy accept; }
add rule inet gfc_dns_hijack prerouting iifname "<lan_iface>" udp dport 53 redirect to :53
add rule inet gfc_dns_hijack prerouting iifname "<lan_iface>" tcp dport 53 redirect to :53
add rule inet gfc_dns_hijack prerouting iifname "<wan_iface>" ip saddr @customer_hosts udp dport 53 fib daddr type local return
add rule inet gfc_dns_hijack prerouting iifname "<wan_iface>" ip saddr @customer_hosts tcp dport 53 fib daddr type local return
add rule inet gfc_dns_hijack prerouting iifname "<wan_iface>" ip saddr @customer_hosts udp dport 53 redirect to :53
add rule inet gfc_dns_hijack prerouting iifname "<wan_iface>" ip saddr @customer_hosts tcp dport 53 redirect to :53

# 3. Main classification table
add table inet gfc

# 4–8. Sets — identical to gateway, plus customer_hosts
add set inet gfc TO_CN { type ipv4_addr; flags interval; }
add set inet gfc TO_RFC1918 { type ipv4_addr; flags interval; }
add element inet gfc TO_RFC1918 { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }
add set inet gfc bypass_ip { type ipv4_addr; flags interval; }
add set inet gfc ext { type ipv4_addr; size 262144; timeout 2h; }
add set inet gfc ext_const { type ipv4_addr; }
add element inet gfc ext_const { 1.0.0.1, 1.1.1.1, 8.8.4.4, 8.8.8.8 }
add set inet gfc customer_hosts { type ipv4_addr; flags interval; }
# elements from device Web (CIDRs/hosts that use GFC as default gateway)

# 9. prerouting_mangle_ct — Option B (not mark-all-WAN-new)
add chain inet gfc prerouting_mangle_ct { type filter hook prerouting priority mangle; policy accept; }
add rule inet gfc prerouting_mangle_ct iifname "<tun_iface>" return
add rule inet gfc prerouting_mangle_ct fib daddr type { local, broadcast, multicast } return
add rule inet gfc prerouting_mangle_ct iifname "<lan_iface>" ct mark set 0x00002023 accept
add rule inet gfc prerouting_mangle_ct iifname "<wan_iface>" ip saddr @customer_hosts ct state { established, related } return
add rule inet gfc prerouting_mangle_ct iifname "<wan_iface>" ip saddr @customer_hosts ct mark set 0x00002023 accept

# 10. prerouting_mangle_route
add chain inet gfc prerouting_mangle_route { type filter hook prerouting priority filter; policy accept; }
add rule inet gfc prerouting_mangle_route iifname "<tun_iface>" return
add rule inet gfc prerouting_mangle_route fib daddr type { local, broadcast, multicast } return
# management LAN mini-gateway — identical matches to §9.2
add rule inet gfc prerouting_mangle_route iifname "<lan_iface>" ip daddr { 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
add rule inet gfc prerouting_mangle_route iifname "<lan_iface>" ip daddr <lan_subnet> return
add rule inet gfc prerouting_mangle_route iifname "<lan_iface>" udp dport { 53, 67, 68, 123 } return
add rule inet gfc prerouting_mangle_route iifname "<lan_iface>" ip daddr @bypass_ip return
add rule inet gfc prerouting_mangle_route iifname "<lan_iface>" ip daddr @ext_const ct mark 0x00002023 meta mark set ct mark return
add rule inet gfc prerouting_mangle_route iifname "<lan_iface>" ip daddr @TO_CN return
add rule inet gfc prerouting_mangle_route iifname "<lan_iface>" ct mark 0x00002023 meta mark set ct mark
# customer WAN — same classify order; require saddr @customer_hosts
add rule inet gfc prerouting_mangle_route iifname "<wan_iface>" ip saddr @customer_hosts ip daddr { 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
add rule inet gfc prerouting_mangle_route iifname "<wan_iface>" ip saddr @customer_hosts ip daddr @customer_hosts return
add rule inet gfc prerouting_mangle_route iifname "<wan_iface>" ip saddr @customer_hosts udp dport { 53, 67, 68, 123 } return
add rule inet gfc prerouting_mangle_route iifname "<wan_iface>" ip saddr @customer_hosts ip daddr @bypass_ip return
add rule inet gfc prerouting_mangle_route iifname "<wan_iface>" ip saddr @customer_hosts ip daddr @ext_const ct mark 0x00002023 meta mark set ct mark return
add rule inet gfc prerouting_mangle_route iifname "<wan_iface>" ip saddr @customer_hosts ip daddr @TO_CN return
add rule inet gfc prerouting_mangle_route iifname "<wan_iface>" ip saddr @customer_hosts ct mark 0x00002023 meta mark set ct mark

# 11. gfc_forward
add chain inet gfc gfc_forward { type filter hook forward priority filter; policy accept; }
add rule inet gfc gfc_forward ct state established,related accept
add rule inet gfc gfc_forward ct state new ip saddr <lan_subnet> ct mark set meta mark
add rule inet gfc gfc_forward ct state new ip saddr @customer_hosts ct mark set meta mark
add rule inet gfc gfc_forward accept

# 12. output_mangle_route — §9.2 plus bypass customer return (before catch-all mark)
add chain inet gfc output_mangle_route { type route hook output priority filter; policy accept; }
add rule inet gfc output_mangle_route meta mark != 0x00000000 return
add rule inet gfc output_mangle_route tcp dport 212 return
add rule inet gfc output_mangle_route ip daddr @TO_RFC1918 return
add rule inet gfc output_mangle_route ip daddr 127.0.0.0/8 return
add rule inet gfc output_mangle_route ip daddr @customer_hosts return
add rule inet gfc output_mangle_route ip daddr @TO_CN return
add rule inet gfc output_mangle_route ip daddr @bypass_ip counter return
add rule inet gfc output_mangle_route meta mark set 0x00002023
add rule inet gfc output_mangle_route ct mark set meta mark
```

**Bypass Option B — why these guards exist:**

| Guard | Stops |
|-------|--------|
| `saddr @customer_hosts` on WAN | Marking/hijacking unrelated WAN neighbors, ISP gateway, non-GFC clients |
| OUTPUT `ip daddr @customer_hosts return` | Local unbound/ICMP replies to **public** customer IPs policy-routed into `gfctun` |
| `iifname <tun_iface> return` | TUN replies re-classified into TUN |
| `fib daddr type { local, broadcast, multicast } return` | VLESS/SSH/LuCI/unbound replies marked `0x2023` |
| WAN `established,related` return (customer only) | Re-marking existing customer flows |
| No customer WAN masquerade | China replies forced through GFC |
| LAN mini-gateway + restricted masq | Ops laptop on LAN can test domestic + cross-border |

**Proxy mode switch contract (product):**

| Rule | Value |
|------|-------|
| Write path for `proxy_mode` | **Device Web only** |
| Control plane | Read / report only; must not force bypass at commissioning |
| Apply model | Single orchestrated apply (not ad-hoc script pile); validate then generate nft/WAN/sysctl |
| Safety net | Confirm within timeout or automatic rollback to previous mode/WAN |

### Client business rules (never proxy)

Controller, forward node, China DNS, SSH (port **212**), LAN local, RFC1918, China IP (`TO_CN`), health check, Reality handshake — enforced at nft layer via `bypass_ip` and `TO_CN`.

**Forbidden:** skuid-based bypass for sing-box or DNS daemons as a substitute for `bypass_ip` or `TO_CN`.

### Routing mode (`split` vs `global`)

Traffic mode is configured per device as `routingScheme` in the control-plane config bundle (`split` | `global`). The client writes `/etc/gfc-client/routing-mode.json` (`{"mode":"split"|"global"}`) and regenerates nft rules.

| Mode | `@TO_CN return` in `prerouting_mangle_route` / `output_mangle_route` | IP traffic |
|------|------------------------------------------------------------------------|------------|
| `split` (default) | **Present** — China IP stays on WAN | CN direct; international → mark → gfctun |
| `global` | **Omitted** — China IP gets mark `0x2023` | All public IP (except bypass) → gfctun → VLESS |

**Unchanged in both routing modes:** `bypass_ip`, RFC1918, LAN CIDR (and bypass `@customer_hosts`), DNS/DHCP/NTP port returns, `ext_const`, fwmark → table `2022` → `gfctun`, DNS hijack → unbound `:53`. LAN DNS resolution (domestic/international upstream split in unbound) is **not** tied to routing mode. `split`/`global` is orthogonal to `proxy_mode` gateway/bypass.

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

### Client (gateway and bypass)

```
fwmark 0x2023 → table 2022 → default dev gfctun
```

Bypass must **enable** this rule. Disabling policy routing in `proxy_mode=bypass` is a bug.
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
- Support bypass `@customer_hosts` from device Web config (never hardcode; never reuse management `<lan_subnet>` as a substitute for customer hosts)
- Support runtime-generated sets (especially `ext`, `bypass_ip`, and bypass `customer_hosts`)

Generated code must **never** simplify or replace this architecture with alternate schemes (e.g. `gfc_client_mangle`, `classify`-only chains, skuid bypass, or mark `0x1` for TPROXY on forward nodes).

---

## 16. Implementation alignment

| Component | Generator | Status |
|-----------|-----------|--------|
| GFC Client (kernel-split) | `gfc-client/deploy/gen-nft-policy.py` | Gateway aligned. Bypass §9.3 **not implemented**. |
| GFC Client (ImmortalWrt) | `gfc-client/deploy/immortalwrt/gfc-routing.sh` | Gateway aligned. Bypass §9.3 **not implemented**. |
| GFC Client DNS hijack | `gfc-client/deploy/lib-unbound-nft.sh` | Gateway aligned (LAN only). Bypass WAN+customer **not implemented**. |
| GFC Client NAT | `gfc-client/deploy/apply-network.sh` | Gateway aligned (full WAN masq). Bypass management-only masq **not implemented**. |
| GFC Client bypass `proxy_mode` | generators + device Web | Spec ratified §9.3; code pending chat 「确认修改」 on named files |
| Forward Node | `gfc-platform/node-agent/node_agent/nft_render.py` | Aligned |
| Forward Node policy routes | `gfc-platform/node-agent/node_agent/routes.py` | Aligned (`0x100` / `0x1`) |

**Not aligned (legacy — requires separate approval to change or remove):**

- `GFC_ROUTING_SCHEME=tun-all` / `byst-redirect` in `gen-nft-policy.py` (scheme A/C)
- `inet gfc_client_filter` in `apply-network.sh` (INPUT/FORWARD firewall — out of nft data-plane scope)
- Current `proxy_mode=bypass` path that **disables** mangle/policy routing (`lib-policy-routing.sh` / `GATEWAY_CORE.md`) — contradicts §9.3 / §14

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

# Bypass — also expect customer_hosts set and WAN DNS rules
nft list set inet gfc customer_hosts
nft list table inet gfc_dns_hijack

# Forward node — expect: ip gfc-nat, inet gfc with full prerouting order
nft list table inet gfc
nft list table ip gfc-nat
ip rule list
ip route show table 100
```

---

*Document version: 2026-08-20. Maintained by project owner. AI agents must read this file before any nft-related code change.*
