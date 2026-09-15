# GFC ImmortalWrt OEM 固件 — 构建操作手册

> **状态 / 卡点 / 踩坑：** [`FIRMWARE-BUILD-HANDOFF.md`](FIRMWARE-BUILD-HANDOFF.md)  
> **Cursor 规则：** [`.cursor/rules/gfc-firmware-build.mdc`](../../../.cursor/rules/gfc-firmware-build.mdc)  
> **包版本（源码）：** `gfc-client` 以 `package/Makefile` 的 `PKG_VERSION`-`rPKG_RELEASE` 与构建机 manifest 为准（当前 **2.1.0-r1**；**试编不升号**）  
> **最后更新：** 2026-09-15（OEM 强制 `kmod-veth`；预装 WireGuard / OpenVPN 用户态，非当前数据面）

本手册面向**构建机操作人员**：按目录、命令、模块、验收步骤操作即可产出可刷盘镜像。

---

## 1. 目标与产物

| 项 | 内容 |
|----|------|
| 目标 | ImmortalWrt x86_64 OEM 镜像，刷盘即用：DHCP/NAT/DNS、Web 激活、代理数据面 |
| 主产物 | `immortalwrt-x86-64-generic-ext4-combined-efi.img.gz` |
| GFC 试编副本 | `gfc-build-<gitsha>-client-…img.gz`（默认；**不是**产品版本） |
| GFC 正式发布副本 | 仅 `GFC_PUBLISH_RELEASE=1` 时：`gfc-os-v{产品}-client-{ver}-r{N}-….img.gz` + `.sha256` |
| 清单 | `immortalwrt-x86-64-generic.manifest`（**必须含** `gfc-client`、`luci-app-gfc`） |
| 刷机介质 | **仅用**最新时间戳的 `*ext4*combined*efi*.img.gz`（勿用旧未压缩 `.img`）；对外发货用 `gfc-os-v*` |

---

## 2. 构建机目录与环境

```text
/opt/gfc/
  sip-proxy/                 # 本仓库（git）
    gfc-client/deploy/immortalwrt/   # OEM 脚本、package、选包、手册
  immortalwrt/               # ImmortalWrt 源码树（编译根）
  dist/gfc-os-v1/            # 可选：发布拷贝
```

| 变量 | 典型值 |
|------|--------|
| `IMT_SRC` | `/opt/gfc/immortalwrt` |
| `GFC_REPO` | `/opt/gfc/sip-proxy/gfc-client` |
| 用户 | **`gfcbuild`**（勿混用 root 编） |
| Go | `/usr/local/go` **1.22+** |
| `GOFLAGS` | `-buildvcs=false`（必设） |
| OS | Ubuntu 22.04 |

```bash
export PATH=/usr/local/go/bin:$PATH
export IMT_SRC=/opt/gfc/immortalwrt
export GFC_REPO=/opt/gfc/sip-proxy/gfc-client
export GOFLAGS=-buildvcs=false
```

---

## 3. 一键重建（推荐）

构建机 **192.168.0.185**，用户 **`gfcbuild`**。仓库在 `/opt/gfc/sip-proxy`；ImmortalWrt 树在 `/opt/gfc/immortalwrt`。  
**禁止**从 `192.168.1.222:/root/sip-proxy` 打 OEM。试编 **不要** `GFC_SKIP_KERNEL_REFRESH=1`、**不要** `GFC_PUBLISH_RELEASE=1`、**不要** bump `PKG_RELEASE`。

```bash
# 在能 ssh 到构建机的机器上（或本机就是 185）：
# ssh gfcbuild@192.168.0.185

cd /opt/gfc/sip-proxy
git pull
# 若曾用 root 编过：
# sudo chown -R gfcbuild:gfcbuild /opt/gfc/sip-proxy /opt/gfc/immortalwrt

export PATH=/usr/local/go/bin:$PATH
export IMT_SRC=/opt/gfc/immortalwrt
export GFC_REPO=/opt/gfc/sip-proxy/gfc-client
export GOFLAGS=-buildvcs=false

# 必须从 sip-proxy 同步后的 gfc-client 打 OEM（GFC_REPO 指向 gfc-client）
bash "$GFC_REPO/deploy/immortalwrt/scripts/rebuild-gfc-image.sh"
```

脚本会：注册/校验 feed、合并 `gfc-packages.config`、校验 packageinfo、编包（含 **kmod-veth** / WireGuard / OpenVPN）、装 rootfs、同步 ORIG、打镜像、查 manifest。缺 `veth.ko` / `wireguard.ko` / `openvpn` 会 **构建失败**。

---

## 4. 构建成功验收（必须）

在 **gfcbuild @ 192.168.0.185**、编完后立刻跑。`ORIG` 必须查 `root.orig-x86`（镜像从 ORIG 打包）。  
**禁止：** 只看到 ipk 就宣布成功；只查 `root-x86` 不查 ORIG；试编成功就 bump 版本号。

```bash
export IMT_SRC=/opt/gfc/immortalwrt
export GFC_REPO=/opt/gfc/sip-proxy/gfc-client
MANIFEST="$IMT_SRC/bin/targets/x86/64/immortalwrt-x86-64-generic.manifest"
ORIG="$IMT_SRC/build_dir/target-x86_64_musl/root.orig-x86"

cd /opt/gfc/sip-proxy
git rev-parse --short HEAD
grep PKG_RELEASE "$GFC_REPO/deploy/immortalwrt/package/Makefile"
# 试编期望仍为 PKG_RELEASE:=1（2.1.0-r1）；不得因本批升号

# ---- 1) 本批新增：透明 veth + 未来 VPN ----
echo "=== NEW: transparent veth + future VPN ==="
grep -E '^(kmod-veth|kmod-dummy|kmod-nft-netdev|kmod-wireguard|kmod-udptunnel4|kmod-udptunnel6|kmod-crypto-lib-chacha20poly1305|kmod-crypto-lib-curve25519|wireguard-tools|openvpn-openssl) ' "$MANIFEST"
find "$ORIG/lib/modules" \( -name 'veth.ko' -o -name 'veth.ko.gz' -o -name 'veth.ko.xz' \) | head -1
find "$ORIG/lib/modules" \( -name 'dummy.ko' -o -name 'dummy.ko.gz' -o -name 'dummy.ko.xz' \) | head -1
find "$ORIG/lib/modules" \( -name 'nft_fwd_netdev.ko' -o -name 'nft_fwd_netdev.ko.gz' -o -name 'nft_fwd_netdev.ko.xz' \) | head -1
find "$ORIG/lib/modules" \( -name 'wireguard.ko' -o -name 'wireguard.ko.gz' -o -name 'wireguard.ko.xz' \) | head -1
ls -la "$ORIG/usr/bin/wg" "$ORIG/usr/sbin/wg" 2>/dev/null || true
ls -la "$ORIG/usr/sbin/openvpn" "$ORIG/usr/bin/openvpn" 2>/dev/null || true

# ---- 2) r16 / 数据面必要包（此前基线，不得漏）----
echo "=== BASELINE: r16 + dataplane ==="
grep -E '^(gfc-client|luci-app-gfc|luci-base|luci-theme-bootstrap|luci-mod-admin-full) ' "$MANIFEST"
grep -E '^(dropbear|openssh-client|openssh-keygen|autossh|uhttpd|rpcd|odhcpd) ' "$MANIFEST"
grep -E '^(sing-box|unbound-daemon|unbound-checkconf|dnsmasq-full|nftables-json|kmod-tun|kmod-nft-core) ' "$MANIFEST"
grep -E '^(tc-tiny|kmod-sched-core|kmod-ifb|kmod-tcp-bbr|kmod-sched|libcap-bin|ip-full) ' "$MANIFEST"
grep -E '^(resize2fs|parted|partx-utils|losetup|curl|wget-ssl|tcpdump) ' "$MANIFEST"

# ---- 3) ORIG 二进制 / firstboot（镜像真实内容）----
echo "=== ORIG binaries ==="
ls -la "$ORIG/sbin/tc" "$ORIG/usr/libexec/tc-tiny" 2>/dev/null || true
ls -la "$ORIG/usr/sbin/dropbear" "$ORIG/usr/libexec/ssh-openssh" "$ORIG/usr/bin/ssh" 2>/dev/null || true
test -x "$ORIG/usr/sbin/resize2fs" -o -x "$ORIG/sbin/resize2fs"
test -f "$ORIG/etc/uci-defaults/95-gfc-rootpt-resize"
test -f "$ORIG/etc/uci-defaults/96-gfc-rootfs-resize"
test -f "$ORIG/etc/uci-defaults/99-gfc-firstboot"
test -x "$ORIG/etc/init.d/gfc-lan-dhcp"
test -f "$ORIG/etc/rc.common"

# ---- 4) 一次扫完：缺任何一行即失败 ----
python3 - <<'PY'
import os, glob, sys
imt = os.environ.get("IMT_SRC", "/opt/gfc/immortalwrt")
manifest = os.path.join(imt, "bin/targets/x86/64/immortalwrt-x86-64-generic.manifest")
orig = os.path.join(imt, "build_dir/target-x86_64_musl/root.orig-x86")
need = [
    "gfc-client", "luci-app-gfc", "luci-base", "luci-theme-bootstrap", "luci-mod-admin-full",
    "dropbear", "openssh-client", "openssh-keygen", "autossh", "uhttpd", "rpcd",
    "sing-box", "unbound-daemon", "unbound-checkconf", "dnsmasq-full", "nftables-json",
    "kmod-tun", "kmod-nft-core", "kmod-nft-netdev", "kmod-dummy", "kmod-veth",
    "tc-tiny", "kmod-sched-core", "kmod-ifb", "kmod-tcp-bbr", "kmod-sched",
    "libcap", "libcap-bin", "ca-bundle", "ip-full",
    "resize2fs", "parted", "partx-utils", "losetup",
    "curl", "wget-ssl", "tcpdump", "iftop", "bmon",
    "odhcpd-ipv6only",
    "kmod-wireguard", "kmod-udptunnel4", "kmod-udptunnel6",
    "kmod-crypto-lib-chacha20poly1305", "kmod-crypto-lib-chacha20", "kmod-crypto-lib-poly1305",
    "kmod-crypto-lib-curve25519", "kmod-crypto-kpp", "kmod-crypto-hash",
    "wireguard-tools", "openvpn-openssl",
]
text = open(manifest, encoding="utf-8", errors="replace").read().splitlines()
have = set()
for line in text:
    pkg = line.split()[0] if line.strip() else ""
    have.add(pkg)
missing = [p for p in need if p not in have]
if "odhcpd-ipv6only" in missing and any(x.startswith("odhcpd") for x in have):
    missing = [p for p in missing if p != "odhcpd-ipv6only"]
if missing:
    print("MISSING from manifest:", " ".join(missing))
    sys.exit(1)
print("manifest OK:", len(need), "required names present")

def find_ko(name):
    for root, _, files in os.walk(os.path.join(orig, "lib/modules")):
        for f in files:
            if f == name or f.startswith(name + "."):
                return os.path.join(root, f)
    return None
for ko in ("veth.ko", "dummy.ko", "nft_fwd_netdev.ko", "wireguard.ko",
           "libchacha20poly1305.ko"):
    p = find_ko(ko)
    if not p:
        print("MISSING ORIG kmod:", ko)
        sys.exit(1)
    print("ORIG kmod OK:", p)
curve_any = None
for ko in ("libcurve25519-generic.ko", "libcurve25519.ko", "curve25519-x86_64.ko"):
    curve_any = find_ko(ko)
    if curve_any:
        print("ORIG kmod OK:", curve_any)
        break
if not curve_any:
    print("MISSING ORIG kmod: curve25519 (generic/lib/x86_64)")
    sys.exit(1)
bins = [
    ("openvpn", ["usr/sbin/openvpn", "usr/bin/openvpn"]),
    ("wg", ["usr/bin/wg", "usr/sbin/wg"]),
    ("dropbear", ["usr/sbin/dropbear", "usr/bin/dropbear"]),
]
for label, rels in bins:
    ok = any(os.access(os.path.join(orig, r), os.X_OK) for r in rels)
    if not ok:
        print("MISSING ORIG bin:", label)
        sys.exit(1)
    print("ORIG bin OK:", label)
print("OEM package check passed")
PY

# ---- 5) 镜像产物 ----
ls -lt "$IMT_SRC/bin/targets/x86/64/"*ext4*combined*efi*.img.gz | head -5
ls -lt "$IMT_SRC/bin/targets/x86/64/"gfc-build-*.img.gz | head -3
cd "$IMT_SRC/bin/targets/x86/64"
# 必须在本目录跑 -c（相对路径）；文件名随 git sha 变化
ls gfc-build-*.img.gz.sha256
sha256sum -c gfc-build-*.img.gz.sha256
```

期望：python 打印 `OEM package check passed`；manifest 同时有 **kmod-veth** 与 **openvpn-openssl** / **wireguard-tools**；ORIG 有 `veth.ko` + `wireguard.ko` + `openvpn`。

---

## 5. 刷机与现场 E2E

1. 拷贝最新 `*ext4*combined*efi*.img.gz` 到刷机介质并刷盘。  
2. 上电后按 HANDOFF §4 P1 / 下表验收：

| 检查 | 期望 |
|------|------|
| `opkg list-installed \| grep gfc-client` | `1.1.0-r20`（或当前 PKG） |
| `grep downloads.immortalwrt.org /etc/opkg/distfeeds.conf` | 有官方源、无 vsean |
| `opkg list-installed \| grep kmod-tcp-bbr` | 已安装 |
| `sysctl -n net.ipv4.tcp_congestion_control` | `bbr` |
| `uci get network.wan.device` | 首块物理网卡（如 eth0） |
| br-lan `list ports` | 末块物理网卡（如 eth1） |
| LAN PC DHCP | 无需手动 `dnsmasq restart`（hotplug + `gfc-lan-dhcp`） |
| `uci get dhcp.@dnsmasq[0].force` | `1` |
| `uci get dhcp.@dnsmasq[0].dns_redirect` | `0` |
| `nft list tables` | `nat`、`gfc_dns_hijack`、`gfc`；**无** `dnsmasq` |
| Web | `http://<LAN>/gfc/activate.html` |
| 激活后 | `gfctun` 存在；**一条** `fwmark 0x2023 lookup 2022` |
| SSH | 端口 **212**；密码 **`Wgh@125434`** |
| 限速 | `opkg list-installed \| grep tc-tiny`；`ls /sbin/tc /usr/libexec/tc-tiny` |
| 磁盘扩容 | 首启会**自动重启 1～2 次**；之后 `df -h /` 接近物理盘；日志 `/etc/gfc-client/expand-rootfs.log` |

---

## 6. 固件内容模块（装进镜像什么）

### 6.1 GFC 应用（feed `gfc`）

| 包 / 组件 | 作用 |
|-----------|------|
| `gfc-client` | `gfc-api` / `gfc-agent` / `gfc-bootstrap` + deploy 脚本 + 首启/hotplug |
| `luci-app-gfc` | LuCI 集成与门户辅助 |

### 6.2 数据面与系统包（`gfc-packages.config`）

| 包 | 作用 |
|----|------|
| `sing-box` | 代理引擎（TUN `gfctun`） |
| `unbound-daemon` + `unbound-checkconf` | LAN DNS（`:53`；dnsmasq 仅 DHCP） |
| `dnsmasq-full` | DHCP only（`port=0`、`force=1`） |
| `nftables-json` + `kmod-nft-core` + `kmod-tun` | nft + TUN |
| `kmod-nft-netdev` + `kmod-dummy` + **`kmod-veth`** | 透明偷流：netdev fwd + DNS VIP + **veth RX**（无模块则 MAC-punt 回退；产品主路径必须有 `veth.ko`） |
| `kmod-wireguard` + `kmod-udptunnel4/6` + `wireguard-tools` | **预装**未来隧道；**不**作为当前数据面、**不** enable |
| `kmod-crypto-lib-chacha20poly1305` + `kmod-crypto-lib-curve25519`（及 chacha20/poly1305/kpp/hash） | WireGuard 加密库；OEM **禁止 oldconfig**，必须显式 `=y`，否则 ipkg-build 报缺 `libchacha20poly1305.ko` / `curve25519-x86_64.ko` |
| `openvpn-openssl` | **预装**未来隧道（OpenSSL 变体）；**不** enable；无 `luci-app-openvpn` |
| `libcap-bin` | sing-box 非 root 能力（setcap） |
| `ip-full` | 策略路由等 |
| `tc-tiny` + `kmod-sched-core` + `kmod-ifb` | HTB 带宽限速（**无** `kmod-sched-htb`）；二进制在 `/usr/libexec/tc-tiny`，`/sbin/tc` 为 ALTERNATIVES |
| `resize2fs` + `parted` + `partx-utils` | 首启扩 root（`resize2fs`/`partx-utils`=base；**`parted`=packages feed**，勿用 `package/utils/parted`） |
| `ca-bundle`、`curl`、`wget-ssl`、`tcpdump`、`iftop`、`bmon`、`autossh` | 运维 / 远程 |
| `luci-base` | Web 管理（拥有 `/www/index.html`） |

### 6.3 首启与运行时脚本（设备上）

| 路径 | 作用 |
|------|------|
| `/etc/uci-defaults/95-gfc-rootpt-resize` | 扩 root **分区**后重启（OpenWrt 官方两阶段） |
| `/etc/uci-defaults/96-gfc-rootfs-resize` | 扩 root **文件系统**后重启 |
| `/etc/uci-defaults/97-gfc-oem-root-password` | 出厂 root 密码 |
| `/etc/uci-defaults/98-gfc-network-ports` | WAN=首块 NIC，LAN=末块 |
| `/etc/uci-defaults/99-gfc-firstboot` | 总首启：门户、DHCP、SSH 212、routing、服务 enable |
| `/etc/init.d/gfc-lan-dhcp` | 开机晚启动：等 br-lan 后重启 dnsmasq（修首次 DHCP） |
| `/etc/hotplug.d/iface/99-gfc-dnsmasq` | lan ifup/ifupdate 重启 dnsmasq |
| `/etc/hotplug.d/net/99-gfc-tun` | `gfctun` 出现后装 `ip rule` |
| `/usr/lib/gfc-client/deploy/immortalwrt/gfc-routing.sh` | NAT / DNS hijack / nft gfc / 策略路由 |
| `/www/gfc/activate.html` + CGI | 线路码激活页 |

### 6.4 OEM 网卡约定（r11+）

- 探测 `/sys/class/net` 下物理 `eth*`（编号排序）。  
- **WAN** = 第一块；**LAN (br-lan ports)** = 最后一块。  
- 同步 `/etc/gfc-client/gfc.env` 的 `GFC_WAN_IFACE`。  
- 仅 1 块网卡时不强制拆分。  
- 与 ImmortalWrt stock「lan=eth0 / wan=eth1」相反——以 GFC 首启为准。

---

## 7. 仓库内关键文件地图

```text
gfc-client/deploy/immortalwrt/
  BUILD-FIRMWARE.md                 ← 本手册
  FIRMWARE-BUILD-HANDOFF.md         ← 会话状态与踩坑
  scripts/
    rebuild-gfc-image.sh            ← 一键入口
    setup-immortalwrt-feed.sh       ← feed 注册（v4）
    ensure-gfc-package-index.sh     ← 包是否在 packageinfo
  config/
    gfc-packages.config             ← CONFIG_PACKAGE_*=y
    gfc-package-index.txt           ← 索引校验清单
  package/
    Makefile                        ← PKG_VERSION / PKG_RELEASE / install
    files/etc/…                     ← init.d、uci-defaults、hotplug、gfc.env
  image/files/etc/uci-defaults/     ← 进 ImmortalWrt $IMT_SRC/files 的 overlay
  configure-network-ports.sh
  configure-dnsmasq-dhcp.sh
  configure-dropbear-ssh.sh
  gfc-routing.sh
  www/                              ← 激活门户静态资源
```

---

## 8. 手工步骤（与一键等价，排障用）

```bash
bash "$GFC_REPO/deploy/immortalwrt/scripts/setup-immortalwrt-feed.sh" all

# 合并选包 — 禁止随后 make defconfig / oldconfig
# （rebuild 脚本会 merge；手工时用 setup 的 merge-config）

rm -rf "$IMT_SRC/build_dir/target-x86_64_musl/root-"*
rm -f "$IMT_SRC/build_dir/target-x86_64_musl/stamp/.rootfs_installed"

cd "$IMT_SRC"
make package/install -j1 V=s
make target/linux/install -j1 V=s

grep -i gfc bin/targets/x86/64/*.manifest
```

---

## 9. 绝对禁止（操作红线）

| 禁止 | 原因 |
|------|------|
| 选 GFC 后 `make defconfig` / `oldconfig` | 清掉 GFC 选包 |
| legacy `package/gfc/` | 与 feed 冲突 |
| `gfc-client` 非空 `DEPENDS` | 包从 Kconfig 消失 |
| `CONFIG_PACKAGE_nftables` | 无此包名 |
| `CONFIG_PACKAGE_kmod-sched-htb` | 无此包；HTB 在 `kmod-sched-core` |
| ipk 安装 `/www/index.html` | 与 luci-base clash |
| 以「有 ipk」代替 manifest | 镜像可能无 GFC |
| 删 rootfs 后只跑 `target/install` | 须先 `package/install` |
| 不设 `GOFLAGS=-buildvcs=false` | Go 构建失败 |

完整踩坑表见 HANDOFF §5。

---

## 10. 发布与清理

```bash
# 发布拷贝（可选）
mkdir -p /opt/gfc/dist/gfc-os-v1
cp "$IMT_SRC/bin/targets/x86/64/"*ext4*combined*efi*.img.gz /opt/gfc/dist/gfc-os-v1/
# 可选: gunzip + qemu-img convert → vmdk；sha256sum

# 可删：无 GFC 的旧 img.gz / 误产物
# 保留（加速重编）: dl/ staging_dir/ build_dir/host/ build_dir/toolchain-*
```

---

## 11. 日常 OTA（不必重刷整盘）

| 方式 | 用途 |
|------|------|
| `pack-runtime.sh` → `upgrade-runtime.sh` | 应用层更新 agent/脚本 |
| 新 `img.gz` + `sysupgrade -k` | 大版本 / 内核与选包变更 |

---

## 12. 现网救火（不持久，正式仍以重刷为准）

```sh
sh /usr/lib/gfc-client/deploy/immortalwrt/configure-network-ports.sh
sh /usr/lib/gfc-client/deploy/immortalwrt/configure-dropbear-ssh.sh
printf '%s\n%s\n' 'Wgh@125434' 'Wgh@125434' | passwd root
GFC_ROUTING_TUN_WAIT=5 sh /usr/lib/gfc-client/deploy/immortalwrt/gfc-routing.sh start
```

---

## 13. 排障速查

| 现象 | 先查 |
|------|------|
| manifest 无 gfc | `.config`、feed 路径、ORIG 同步、是否跑了 defconfig |
| package/install clash `/www/index.html` | ipk 是否又装了 index（应 r8+） |
| 激活后无 `ip rule` | `ip link show gfctun`；`ls -l …/gfc-routing.sh`；`/tmp/gfc-routing-*.log`；状态落盘见 `docs/CLIENT_STATE.md` |
| 策略路由保存 `wget exit 8` | BusyBox wget 吃掉 HTTP 4xx；现网应显示中文 `danger_ack` 等。勾选「高危确认」。 |
| 系统 网络→DHCP/DNS `uci/get` ubus 4 | 缺 `/etc/config/firewall`。跑 `disable-immortalwrt-fw4.sh` 写 stub，**不要**启用 fw4。 |
| PC 指 WAN IP 做 DNS，UDP 超时 | `uci get dhcp.@dnsmasq[0].dns_redirect` 须为 `0`；`nft list tables` 无 `dnsmasq` |
| Permission denied on routing | 脚本无 +x → 用 `sh` 或重刷 r9+ |
| 密码仍空 | 是否 r10+；有无 `passwd`；firstboot 是否已跑过旧版 |
| ensure-index 报 `kmod-sched-htb` | 假包名；用 `kmod-sched-core` |
| lan=eth0 wan=eth1 | stock 默认；刷 r11+ 或跑 `configure-network-ports.sh` |
| 设备上无 `tc` 但有 `/usr/libexec/tc-tiny` | ALTERNATIVES 未链上；`ln -sf /usr/libexec/tc-tiny /sbin/tc` 或重刷 r12 |
| rebuild 报 manifest/ORIG missing tc-tiny | `.config` 未选中或 iproute2 未编出；查 merge scrub 与 `find bin -name 'tc-tiny_*.ipk'` |
| rebuild 在 `merged gfc-packages.config` 后静默回提示符 | r12 初版 `verify_dotconfig` 的 `grep -q && die` 触发 `set -e`；pull 含 `if grep` 的修复后再跑 |

---

*改 nft / unbound / sing-box 数据面：先读 `docs/*_ARCHITECTURE.md`，出差异表，等用户「确认修改」。固件选包与 firstboot 改动同理，见 Cursor 规则。*
