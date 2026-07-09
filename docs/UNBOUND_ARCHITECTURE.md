# GFC DNS Data Plane — Unbound Architecture (Authoritative)

**Status:** Single source of truth for all GFC Client local DNS / unbound configuration.  
**Scope:** GFC Client (ImmortalWrt / Ubuntu gateway) local DNS resolver.  
**Supersedes:** MosDNS / easymosdns descriptions in `GATEWAY_CORE.md`, `ARCHITECTURE.md`, and legacy `gfc-mosdns` init.

If generated runtime config differs from this document, **the generator is wrong** — not this document.

**Companion:** [`docs/NFT_ARCHITECTURE.md`](NFT_ARCHITECTURE.md) (DNS hijack, `ext_const`), [`docs/SINGBOX_ARCHITECTURE.md`](SINGBOX_ARCHITECTURE.md) (TUN 内国际 DNS IP 出站).

---

## 1. Change control

| Action | Required |
|--------|----------|
| Change listen port / interface ACL | User approval + update this file |
| Change domestic / intl upstream protocol or defaults | User approval + update this file |
| Move `forward-zone` inside `server:` block | **Forbidden** |
| Replace unbound with MosDNS / dnsmasq DNS / DoH in sing-box for LAN | **Forbidden** without architecture review |
| Hardcode deployment LAN CIDR in unbound | **Forbidden** |

---

## 2. DNS data plane principles (fixed)

### GFC Client — validated path (`v0.3.0`)

```
LAN client
  → DHCP option 6 = LAN gateway IP          (dnsmasq, port=0)
  → DNS query to gateway :53
  → nft gfc_dns_hijack (LAN → redirect :53)  [see NFT_ARCHITECTURE]
  → unbound (gfc-unbound) :53
       ├─ CN domain list → domestic upstream (UDP 53)
       └─ default "."   → international upstream (DoT 853)
  → returned A/AAAA to client

International DNS upstream IP (1.1.1.1, 8.8.8.8, …)
  → classified by nft ext_const → mark → gfctun → sing-box
  → NOT resolved by bypassing unbound
```

### Responsibility boundary

| Component | Responsibility | Must NOT |
|-----------|----------------|----------|
| **dnsmasq** | DHCP; advertise DNS = LAN gateway (`dhcp_option 6`) | Listen on :53; forward to 1053; cache DNS |
| **nft** | Hijack LAN :53 to local resolver; mark intl DNS IPs | Replace unbound split logic |
| **unbound** | Domain split; forward to upstream; cache | Policy routing; proxy; TUN |
| **sing-box** | Egress for TUN traffic (incl. intl DNS IP if marked) | LAN :53; DHCP |

---

## 3. Mandatory paths and service

| Item | Default | Notes |
|------|---------|-------|
| Main config | `/etc/unbound/unbound.conf` | Rendered from bundle template |
| CN forward include | `/etc/unbound/conf.d/cn.unbound.conf` | Copied from `share/unbound/conf.d/` |
| Domain insecure list | `/etc/unbound/domains-insecure.conf` | Copied from bundle |
| Init (OpenWrt) | `/etc/init.d/gfc-unbound` | **Not** stock `/etc/init.d/unbound` (UCI recursive) |
| Bundle template | `gfc-client/share/unbound/unbound.conf.template` | Single source for `server:` + default forward |
| Renderer | `gfc-client/internal/render/unbound/unbound.go` | Only approved mutation path |

Stock OpenWrt `unbound` (UCI, recursive from root) must remain **disabled**.

---

## 4. Mandatory `server:` block

```yaml
server:
    interface: 0.0.0.0
    port: 53
    do-ip4: yes
    do-ip6: no
    prefer-ip4: yes

    access-control: 127.0.0.0/8 allow
    access-control: 10.0.0.0/8 allow
    access-control: 172.16.0.0/12 allow
    access-control: 192.168.0.0/16 allow

    qname-minimisation: no
    forward-first: no          # implicit via forward-zone; never fall back to root recursion

    include: "/etc/unbound/domains-insecure.conf"
```

### Forbidden in `server:`

- `do-ip6: yes` without architecture review
- `interface: 127.0.0.1` only (must serve LAN via gateway :53)
- Any `forward-zone` / `stub-zone` **inside** `server:` (unbound ignores them → silent root recursion bug)

---

## 5. Mandatory forward architecture

Structure **below** `server:` block, in order:

```
1. include: "/etc/unbound/conf.d/cn.unbound.conf"   # per-zone domestic forward
2. forward-zone: name "."                           # default international
```

### 5.1 Domestic (CN domains)

- Source: `share/unbound/conf.d/cn.unbound.conf` (generated domain list).
- Upstream: **UDP 53** to domestic resolvers.
- Defaults: `223.5.5.5`, `119.29.29.29` (overridable via bundle `dns.domesticServer`).

### 5.2 International (default zone)

```yaml
forward-zone:
    name: "."
    forward-tls-upstream: yes
    forward-first: no
    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 1.0.0.1@853#cloudflare-dns.com
```

- Protocol: **DoT 853** (not plain UDP to 1.1.1.1 for default zone).
- `forward-first: no` — failure must **not** fall back to recursive root walk.
- Intl primary override: bundle `dns.intlServer` may replace first `forward-addr` only; second Cloudflare addr may be dropped when custom intl server set.

### 5.3 Alignment with nft `ext_const`

International resolver IPs used for **routing classification** (not unbound config) default:

`1.0.0.1`, `1.1.1.1`, `8.8.4.4`, `8.8.8.8` — env `GFC_EXT_CONST_IPS`.

These IPs are marked in **nft**, not bypassed in unbound. Unbound still forwards queries to them via DoT/default path as applicable.

---

## 6. OpenWrt / ImmortalWrt — dnsmasq contract

Unbound does **not** configure dnsmasq. Separate script: `configure-dnsmasq-dhcp.sh`.

| UCI key | Required value |
|---------|----------------|
| `dhcp.@dnsmasq[0].port` | `0` |
| `dhcp.@dnsmasq[0].noresolv` | `1` |
| `dhcp.@dnsmasq[0].server` | **deleted** (no `127.0.0.1#1053`) |
| `dhcp.@dnsmasq[0].cachesize` | `0` |
| `dhcp.lan.dhcp_option` | `6,<network.lan.ipaddr>` |

**Rationale:** `port=0` disables dnsmasq DNS service; without explicit option 6, LAN clients receive **no DNS**.

---

## 7. Platform path patches (OpenWrt only)

Renderer may patch paths if files exist:

| Key | Ubuntu default | OpenWrt candidates |
|-----|----------------|-------------------|
| `tls-cert-bundle` | `/etc/ssl/certs/ca-certificates.crt` | `/etc/ssl/cert.pem`, `/etc/ssl/cacert.pem` |
| `chroot` | (unset) | `""` (disable ImmortalWrt default chroot for checkconf) |
| `auto-trust-anchor-file` | `/var/lib/unbound/root.key` | **same** — never `/etc/unbound/root.key` under chroot |

`ensure-unbound-dirs.sh` / `EnsureTrustAnchorLayout()` create `/var/lib/unbound/root.key` and chroot mirror before `unbound-checkconf`.

No other silent rewrites.

---

## 8. Performance defaults (embedded)

| Key | Default | Change requires |
|-----|---------|-----------------|
| `num-threads` | `4` | Approval if > device CPU count |
| `msg-cache-size` | `128m` | Approval on <256MB RAM devices |
| `rrset-cache-size` | `256m` | Approval on <256MB RAM devices |
| `verbosity` | `1` | — |

---

## 9. Forbidden changes

AI / generators must **never** (without approval):

- Re-enable MosDNS / `gfc-mosdns` / `127.0.0.1#1053` dnsmasq forward
- Point LAN DNS to sing-box / fake-ip / DoH inbound
- Use `systemd-resolved` or `dnsmasq` as authoritative DNS on :53 alongside unbound
- Collapse CN list into single `local-zone` without forward-zone
- Enable QNAME minimisation without CDN regression test
- Replace DoT international forward with plain UDP 8.8.8.8 as default zone default

---

## 10. Code generation requirements

Generated / rendered unbound config must:

- Keep `forward-zone` blocks **outside** `server:`
- Preserve include paths as absolute under `/etc/unbound/`
- Be idempotent (`copyIfChanged` for static includes; full render for main conf)
- Pass `unbound-checkconf` when binary present (`GFC_SKIP_UNBOUND_CHECK=1` only on OpenWrt pre-install)
- Support bundle override of `dns.domesticServer` / `dns.intlServer` only — not ad-hoc template forks

---

## 11. Implementation alignment

| Component | Generator | Status |
|-----------|-----------|--------|
| Main template | `share/unbound/unbound.conf.template` | Aligned |
| Renderer | `internal/render/unbound/unbound.go` | Aligned |
| Init | `deploy/immortalwrt/package/files/etc/init.d/gfc-unbound` | Aligned |
| dnsmasq DHCP DNS | `deploy/immortalwrt/configure-dnsmasq-dhcp.sh` | Aligned (`v0.3.0`) |
| NFT DNS hijack | `gfc-routing.sh` / `lib-unbound-nft.sh` | Aligned (redirect :53) |
| Legacy MosDNS docs | `GATEWAY_CORE.md` | Aligned (references unbound) |
| Legacy share | `share/easymosdns/` | **Legacy** — not used in production path |

---

## 12. Verification commands

```sh
# Service
/etc/init.d/gfc-unbound status
/etc/init.d/dnsmasq status

# Port ownership — only unbound on :53
ss -ulnp | grep ':53 '

# Config structure
grep -E '^(server:|forward-zone:|include:)' /etc/unbound/unbound.conf
unbound-checkconf /etc/unbound/unbound.conf

# dnsmasq DHCP DNS
uci get dhcp.lan.dhcp_option
uci get dhcp.@dnsmasq[0].port    # expect 0

# Resolution
drill @127.0.0.1 taobao.com A
drill @127.0.0.1 google.com A

# nft DNS hijack still active
nft list table inet gfc_dns_hijack
```
