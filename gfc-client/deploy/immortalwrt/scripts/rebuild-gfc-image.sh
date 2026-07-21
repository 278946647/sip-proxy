#!/usr/bin/env bash
# Build ImmortalWrt image with gfc-client + luci-app-gfc in rootfs/manifest.
set -euo pipefail

IMT_SRC="${IMT_SRC:-/opt/gfc/immortalwrt}"
GFC_REPO="${GFC_REPO:-/opt/gfc/sip-proxy/gfc-client}"
GFC_DEPLOY="${GFC_REPO}/deploy/immortalwrt"
GFC_FEED_SETUP="${GFC_DEPLOY}/scripts/setup-immortalwrt-feed.sh"
TARGET_BUILD="${IMT_SRC}/build_dir/target-x86_64_musl"
LINUX_BUILD="${TARGET_BUILD}/linux-x86_64"
ROOTFS_DIR="${ROOTFS_DIR:-${TARGET_BUILD}/root-x86}"
# Image/Manifest + squashfs/ext4 are built from TARGET_DIR_ORIG, NOT TARGET_DIR.
# package/install does: opkg install → CP TARGET_DIR → TARGET_DIR_ORIG → prepare_rootfs(TARGET_DIR)
ROOTFS_ORIG_DIR="${ROOTFS_ORIG_DIR:-${TARGET_BUILD}/root.orig-x86}"
STAGING_PKGINFO="${IMT_SRC}/staging_dir/target-x86_64_musl/pkginfo"
JOBS="${JOBS:-$(nproc)}"
export PATH="/usr/local/go/bin:${PATH:-}"
export GOFLAGS="${GOFLAGS:--buildvcs=false}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1 (install Go 1.22+ to /usr/local/go)"
}

require_feed_setup_script() {
  [[ -f "$GFC_FEED_SETUP" ]] || die "missing $GFC_FEED_SETUP"
  grep -q 'GFC_FEED_SETUP_VERSION=4' "$GFC_FEED_SETUP" \
    || die "outdated setup script (need v4). Run: cd /opt/gfc/sip-proxy && git pull"
  grep -q 'feeds update -i gfc' "$GFC_FEED_SETUP" \
    || die "setup script missing feeds update -i — git pull sip-proxy on build machine"
}

load_feed_setup() {
  require_feed_setup_script
  # shellcheck disable=SC1090
  source "$GFC_FEED_SETUP"
}

ensure_gfc_package_index() {
  bash "$GFC_DEPLOY/scripts/ensure-gfc-package-index.sh"
}

# Remove both CONFIG_PACKAGE_foo=... and "# CONFIG_PACKAGE_foo is not set" so =y wins.
scrub_package_config_lines() {
  local file="$1" key="$2"
  grep -v -E "^${key}=|^# ${key} is not set\$" "$file" >"${file}.new" || true
  mv "${file}.new" "$file"
}

# ImmortalWrt 24.10 always appends console=ttyS0 last (CONFIG_GRUB_SERIAL gone).
# Force an extra console=tty1 *after* that so /dev/console = VGA.
patch_immortalwrt_x86_grub_vga() {
  local mk="$IMT_SRC/target/linux/x86/image/Makefile"
  [[ -f "$mk" ]] || die "missing $mk (not an x86 ImmortalWrt tree?)"
  if grep -q 'GFC_VGA_CONSOLE_LAST' "$mk"; then
    log "x86 GRUB Makefile already has GFC_VGA_CONSOLE_LAST"
    return 0
  fi
  # Insert after the unconditional serial cmdline line (24.10+).
  if grep -q 'GRUB_CONSOLE_CMDLINE += console=\$(GRUB_SERIAL)' "$mk"; then
    # Portable: write patched file (GNU sed -i works on build host Linux).
    local tmp
    tmp="$(mktemp)"
    awk '
      { print }
      /GRUB_CONSOLE_CMDLINE \+= console=\$\(GRUB_SERIAL\)/ && !done {
        print ""
        print "# GFC_VGA_CONSOLE_LAST: /dev/console must be VGA (tty1), not serial-last."
        print "GRUB_CONSOLE_CMDLINE += console=tty1"
        done=1
      }
    ' "$mk" >"$tmp"
    grep -q 'GFC_VGA_CONSOLE_LAST' "$tmp" \
      || die "failed to inject GFC_VGA_CONSOLE_LAST into $mk"
    mv "$tmp" "$mk"
    log "patched $mk: append console=tty1 after serial (GFC_VGA_CONSOLE_LAST)"
    return 0
  fi
  die "cannot patch $mk — GRUB_SERIAL cmdline line not found (ImmortalWrt layout changed?)"
}

# Merge GRUB-related .config knobs (timeout / console). Does NOT remove serial —
# serial is hard-wired in 24.10 Makefile; see patch_immortalwrt_x86_grub_vga.
merge_gfc_boot_config() {
  local fragment="$GFC_DEPLOY/config/gfc-boot.config"
  [[ -f "$fragment" ]] || return 0
  cd "$IMT_SRC"
  scrub_package_config_lines .config "CONFIG_GRUB_CONSOLE"
  scrub_package_config_lines .config "CONFIG_GRUB_TIMEOUT"
  scrub_package_config_lines .config "CONFIG_TARGET_SERIAL"
  {
    echo "CONFIG_GRUB_CONSOLE=y"
    echo "CONFIG_GRUB_TIMEOUT=5"
    echo 'CONFIG_TARGET_SERIAL="ttyS0"'
  } >>.config
  grep -q '^CONFIG_GRUB_CONSOLE=y$' .config || die "CONFIG_GRUB_CONSOLE not set after merge"
  patch_immortalwrt_x86_grub_vga
  log "merged gfc-boot.config + x86 GRUB VGA-last patch"
}

# OEM inittab for display-attached boxes (VMware / physical VGA).
# Do NOT convert askfirst→respawn: respawn loops "open: No such file" when the
# tty is missing (classic VMware without serial / before tty1 appears).
# Drop ttyS0 + hvc0 gettys — no serial / Hyper-V console on typical GFC VMs.
patch_vga_inittab() {
  local root="$1"
  local f="$root/etc/inittab"
  [[ -f "$f" ]] || {
    log "WARN: no $f — skip VGA inittab patch"
    return 0
  }
  # Comment serial / hv console lines (keep for docs; procd ignores #).
  sed -i -E \
    -e 's|^ttyS[0-9]+::|# &|' \
    -e 's|^hvc[0-9]+::|# &|' \
    "$f"
  # Ensure tty1 getty exists as askfirst (not respawn).
  if grep -qE '^#?tty1::' "$f"; then
    sed -i -E 's|^#?tty1::.*|tty1::askfirst:/usr/libexec/login.sh|' "$f"
  else
    echo 'tty1::askfirst:/usr/libexec/login.sh' >>"$f"
  fi
  # Undo any older OEM respawn mistake.
  sed -i 's|^tty1::respawn:|tty1::askfirst:|' "$f"
  log "patched $f: disable ttyS*/hvc*; tty1=askfirst"
  grep -E '^(# )?tty|^hvc|^::' "$f" || true
}

# After image pack: cmdline in grub.cfg must end with console=tty1 (not ttyS0).
verify_image_grub_vga_console() {
  local gz img tmpdir esp_loop root_dev
  gz="$(ls -1t "$IMT_SRC"/bin/targets/x86/64/*ext4*combined*efi*.img.gz 2>/dev/null | head -1 || true)"
  [[ -n "$gz" && -f "$gz" ]] || {
    log "WARN: no combined-efi img.gz — skip grub cmdline verify"
    return 0
  }
  # Fast path: strings on gzip often still finds grub.cfg text.
  if zcat "$gz" 2>/dev/null | strings | grep -E 'console=ttyS0[^ ]* console=tty1' >/dev/null; then
    log "grub cmdline OK (tty1 after ttyS0) in $(basename "$gz")"
    return 0
  fi
  if zcat "$gz" 2>/dev/null | strings | grep -E 'console=tty1[^ ]* console=ttyS0' >/dev/null; then
    die "grub cmdline still serial-last in $(basename "$gz") — GFC_VGA_CONSOLE_LAST patch missing; rebuild after patch"
  fi
  log "WARN: could not confirm grub console order via strings — check manually after flash: cat /proc/cmdline"
}

merge_gfc_config() {
  local fragment="$GFC_DEPLOY/config/gfc-packages.config"
  [[ -f "$IMT_SRC/.config" ]] || die "missing $IMT_SRC/.config"
  [[ -f "$fragment" ]] || die "missing $fragment"
  cd "$IMT_SRC"
  ensure_gfc_package_index
  local tmp merged key line pkg skipped=0
  tmp="$(mktemp)"
  merged="$(mktemp)"
  cp .config "$tmp"
  while IFS= read -r line; do
    [[ "$line" =~ ^CONFIG_PACKAGE_ ]] || continue
    key="${line%%=*}"
    pkg="${key#CONFIG_PACKAGE_}"
    if grep -q "config PACKAGE_${pkg}" tmp/.config-package.in 2>/dev/null; then
      echo "$line" >>"$merged"
    else
      log "WARN: skip $key (no Kconfig symbol)"
      skipped=$((skipped + 1))
    fi
  done <"$fragment"
  # Required bandwidth + expand packages must never be silently skipped.
  for pkg in tc-tiny kmod-sched-core kmod-ifb resize2fs parted partx-utils losetup kmod-tcp-bbr kmod-sched luci-theme-bootstrap luci-mod-admin-full; do
    grep -q "^CONFIG_PACKAGE_${pkg}=y$" "$merged" \
      || die "merge skipped required CONFIG_PACKAGE_${pkg}=y (Kconfig missing? feeds install parted/luci?)"
  done
  while IFS= read -r line; do
    [[ "$line" =~ ^CONFIG_PACKAGE_ ]] || continue
    key="${line%%=*}"
    scrub_package_config_lines "$tmp" "$key"
  done <"$merged"
  cat "$tmp" "$merged" >.config
  rm -f "$tmp" "$merged"
  # Stale invalid symbols from older fragments (HTB is inside kmod-sched-core;
  # partx binary is in partx-utils — there is no Package: partx).
  sed -i \
    -e '/^CONFIG_PACKAGE_kmod-sched-htb=/d;/^# CONFIG_PACKAGE_kmod-sched-htb is not set$/d' \
    -e '/^CONFIG_PACKAGE_partx=/d;/^# CONFIG_PACKAGE_partx is not set$/d' \
    .config
  # Force-disable ImmortalWrt stock packages that break package/install.
  # GFC uses luci-base + luci-app-gfc + theme/mod-admin-full; fw4 is stopped at firstboot.
  local disable_pkgs=(
    default-settings
    default-settings-chn
    kmod-nft-fullcone
    firewall4
    luci-app-firewall
    luci
    luci-light
    luci-ssl
    luci-ssl-openssl
    luci-ssl-nginx
    luci-i18n-firewall-zh-cn
    luci-i18n-firewall-en
    kmod-r8168
    kmod-r8101
    kmod-r8125
    kmod-r8126
    kmod-usb-net-rtl8152-vendor
  )
  for pkg in "${disable_pkgs[@]}"; do
    scrub_package_config_lines .config "CONFIG_PACKAGE_${pkg}"
    echo "# CONFIG_PACKAGE_${pkg} is not set" >>.config
  done
  # Catch any remaining luci firewall i18n / realtek vendor symbols.
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    scrub_package_config_lines .config "$key"
    echo "# ${key} is not set" >>.config
  done < <(grep -E '^CONFIG_PACKAGE_(luci-i18n-.*firewall|kmod-r81[0-9]*).*=(y|m)$' .config \
    | sed 's/=.*//' || true)
  grep -q '^CONFIG_PACKAGE_gfc-client=y$' .config || die "CONFIG_PACKAGE_gfc-client not in .config after merge"
  grep -q '^CONFIG_PACKAGE_luci-base=y$' .config || die "CONFIG_PACKAGE_luci-base not in .config after merge"
  log "merged gfc-packages.config (skipped=$skipped); disabled fw4/fullcone/luci-meta/luci-light/realtek-oob"
  merge_gfc_boot_config
}

# OpenWrt image install list comes from Kconfig package-y + pkginfo/*.install.
refresh_build_metadata() {
  ensure_gfc_package_index
}

ensure_feeds_only() {
  cd "$IMT_SRC"
  [[ -d package/feeds/gfc/gfc-client ]] \
    || die "package/feeds/gfc/gfc-client missing after register_feed"
  [[ ! -e package/gfc-client && ! -e package/luci-app-gfc && ! -e package/gfc ]] \
    || die "legacy package/gfc* still present — re-run register_feed"
  grep 'Source-Makefile: package/feeds/gfc/gfc-client/Makefile' tmp/.packageinfo >/dev/null \
    || die "packageinfo still not on feeds path — re-run register_feed"
  log "feed path OK: package/feeds/gfc/gfc-client"
}

verify_dotconfig() {
  local pkg
  cd "$IMT_SRC"
  grep -q '^CONFIG_PACKAGE_gfc-client=y$' .config || die ".config missing CONFIG_PACKAGE_gfc-client=y"
  grep -q '^CONFIG_PACKAGE_luci-app-gfc=y$' .config || die ".config missing CONFIG_PACKAGE_luci-app-gfc=y"
  for pkg in tc-tiny kmod-sched-core kmod-ifb kmod-tcp-bbr kmod-sched resize2fs parted partx-utils losetup luci-theme-bootstrap luci-mod-admin-full; do
    grep -q "^CONFIG_PACKAGE_${pkg}=y$" .config || die ".config missing CONFIG_PACKAGE_${pkg}=y"
    # Must use if/then: under set -e, "grep -q && die" returns 1 when absent and aborts the script.
    if grep -qE "^# CONFIG_PACKAGE_${pkg} is not set$" .config; then
      die ".config still has '# CONFIG_PACKAGE_${pkg} is not set' alongside =y"
    fi
  done
  for pkg in default-settings default-settings-chn kmod-nft-fullcone firewall4 luci-app-firewall luci \
    luci-light luci-ssl luci-ssl-openssl luci-ssl-nginx luci-i18n-firewall-zh-cn \
    kmod-r8168 kmod-r8101 kmod-r8125 kmod-r8126 kmod-usb-net-rtl8152-vendor; do
    if grep -qE "^CONFIG_PACKAGE_${pkg}=y$" .config; then
      die ".config still enables CONFIG_PACKAGE_${pkg}=y (must be disabled for GFC OEM)"
    fi
  done
  grep -q '^CONFIG_GRUB_CONSOLE=y$' .config || die ".config missing CONFIG_GRUB_CONSOLE=y"
  grep -q 'GFC_VGA_CONSOLE_LAST' "$IMT_SRC/target/linux/x86/image/Makefile" \
    || die "x86 image Makefile missing GFC_VGA_CONSOLE_LAST — merge_gfc_boot_config did not patch"
  log ".config OK: gfc + luci-base + GRUB VGA-last patch; fw4/fullcone/luci-meta/luci-light/realtek-oob off"
}

# tc-tiny installs binary at /usr/libexec/tc-tiny; /sbin/tc is ALTERNATIVES symlink.
rootfs_has_tc() {
  local root="$1"
  [[ -x "$root/sbin/tc" || -x "$root/usr/sbin/tc" || -x "$root/usr/libexec/tc-tiny" \
    || -x "$root/usr/libexec/tc-full" || -x "$root/usr/libexec/tc-bpf" ]]
}

prepare_gfc_env() {
  local env_dir="$GFC_DEPLOY/package/files/etc/gfc-client"
  [[ -f "$env_dir/gfc.env" ]] || cp "$env_dir/gfc.env.example" "$env_dir/gfc.env"
  cd "$GFC_REPO"
  go mod tidy
}

# ImmortalWrt prepare_rootfs copies $IMT_SRC/files into rootfs (and per-fs images).
link_image_files_overlay() {
  local src="$GFC_DEPLOY/image/files"
  local dst="$IMT_SRC/files"
  [[ -d "$src/etc/uci-defaults" ]] || die "missing image overlay: $src"
  [[ -f "$src/etc/uci-defaults/95-gfc-rootpt-resize" ]] || die "missing 95-gfc-rootpt-resize in $src"
  [[ -f "$src/etc/uci-defaults/96-gfc-rootfs-resize" ]] || die "missing 96-gfc-rootfs-resize in $src"
  [[ -f "$src/etc/uci-defaults/99-gfc-firstboot" ]] || die "missing 99-gfc-firstboot in $src"
  [[ -f "$src/etc/opkg/distfeeds.conf" ]] || die "missing etc/opkg/distfeeds.conf in $src"
  [[ -f "$src/etc/sysctl.d/12-gfc-bbr.conf" ]] || die "missing etc/sysctl.d/12-gfc-bbr.conf in $src"
  # Only check active feed lines (comments may mention old mirrors).
  if ! grep -E '^[[:space:]]*src/' "$src/etc/opkg/distfeeds.conf" \
    | grep -q 'downloads.immortalwrt.org'; then
    die "distfeeds.conf active src lines must use downloads.immortalwrt.org"
  fi
  if grep -E '^[[:space:]]*src/' "$src/etc/opkg/distfeeds.conf" \
    | grep -qiE 'vsean|mirrors\.vsean'; then
    die "distfeeds.conf still has active src line pointing at vsean mirror"
  fi
  # Copy (not symlink) so kmods URL rewrite does not dirty the sip-proxy tree.
  if [[ -L "$dst" || -e "$dst" ]]; then
    rm -rf "$dst"
  fi
  mkdir -p "$dst"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$src/" "$dst/"
  else
    cp -a "$src/." "$dst/"
  fi
  rewrite_distfeeds_kmods_for_build_tree "$dst/etc/opkg/distfeeds.conf" \
    || log "WARN: keep packaged kmods URL (see comments in distfeeds.conf)"
  log "ImmortalWrt files overlay: $dst <= $src (copy)"
}

# Map build-tree kernel vermagic → immortalwrt_kmods URL (or drop the line if CDN has no match).
# Baked kmods (e.g. kmod-tcp-bbr via gfc-packages.config) do NOT depend on this feed.
rewrite_distfeeds_kmods_for_build_tree() {
  local conf=$1
  local vermagic_file kernel_ver hash kmods_dir url tmp
  vermagic_file="$(
    find "$IMT_SRC/build_dir" -path '*/linux-x86_64/linux-*/.vermagic' 2>/dev/null \
      | head -1
  )"
  [[ -n "$vermagic_file" && -f "$vermagic_file" ]] || {
    log "no .vermagic under build_dir — skip kmods URL rewrite"
    return 1
  }
  hash="$(tr -d '[:space:]' <"$vermagic_file")"
  [[ -n "$hash" ]] || return 1
  kernel_ver="$(basename "$(dirname "$vermagic_file")")"
  kernel_ver="${kernel_ver#linux-}"
  kmods_dir="${kernel_ver}-1-${hash}"
  # Prefer same release channel as other feeds; fall back to snapshots if present.
  for url in \
    "https://downloads.immortalwrt.org/releases/24.10.6/targets/x86/64/kmods/${kmods_dir}" \
    "https://downloads.immortalwrt.org/snapshots/targets/x86/64/kmods/${kmods_dir}"
  do
    if command -v curl >/dev/null 2>&1; then
      if curl -fsI -o /dev/null --connect-timeout 5 --max-time 15 "$url/" 2>/dev/null; then
        tmp="$(mktemp)"
        awk -v u="$url" '
          BEGIN { done=0 }
          /^[[:space:]]*src\/gz[[:space:]]+immortalwrt_kmods[[:space:]]+/ {
            print "src/gz immortalwrt_kmods " u
            done=1
            next
          }
          { print }
          END {
            if (!done)
              print "src/gz immortalwrt_kmods " u
          }
        ' "$conf" >"$tmp"
        mv "$tmp" "$conf"
        log "distfeeds immortalwrt_kmods → $url (from $vermagic_file)"
        return 0
      fi
    fi
  done
  # No public kmods for this vermagic (common on custom/snapshot trees).
  # Drop the feed so LuCI/opkg does not advertise incompatible 6.6.133 kmods.
  tmp="$(mktemp)"
  grep -Ev '^[[:space:]]*src/gz[[:space:]]+immortalwrt_kmods[[:space:]]+' "$conf" >"$tmp" || true
  mv "$tmp" "$conf"
  log "WARN: no CDN kmods for ${kmods_dir} — removed immortalwrt_kmods from distfeeds"
  log "      baked packages (kmod-tcp-bbr etc.) still come from this build tree"
  return 0
}

make_gfc_package() {
  local target="$1"
  shift
  cd "$IMT_SRC"
  make "$target/compile" -j1 V=s "$@"
}

build_packages() {
  cd "$IMT_SRC"
  make "package/feeds/gfc/gfc-client/clean" V=s 2>/dev/null || true
  log "compile gfc-client ipk"
  make_gfc_package "package/feeds/gfc/gfc-client" "GFC_CLIENT_SRC=$GFC_REPO"
  log "compile luci-app-gfc ipk"
  make_gfc_package "package/feeds/gfc/luci-app-gfc"
  find bin -name 'gfc-client*.ipk' -print | grep -q . || die "gfc-client ipk not produced"
  ensure_gfc_client_pkginfo
  # Bandwidth shaping: ensure tc-tiny (+ deps) are built before package/install.
  log "compile tc-tiny / kmod-sched-core / kmod-ifb (HTB shaping)"
  make package/network/utils/iproute2/compile -j"$JOBS" V=s \
    || die "iproute2 (tc-tiny) compile failed"
  make package/kernel/linux/compile -j"$JOBS" V=s 2>/dev/null || true
  find bin -name 'tc-tiny_*.ipk' -print | grep -q . \
    || die "tc-tiny ipk not produced — check CONFIG_PACKAGE_tc-tiny=y and iproute2 build"
  # Root expand tools:
  # - resize2fs: package/utils/e2fsprogs (Package: resize2fs)
  # - partx-utils: package/utils/util-linux
  # - parted: packages feed → package/feeds/packages/parted (NOT package/utils/parted)
  log "compile resize2fs / partx-utils / parted (first-boot disk expand)"
  make package/utils/e2fsprogs/compile -j"$JOBS" V=s \
    || die "e2fsprogs tree compile failed (needed for resize2fs ipk)"
  make package/utils/util-linux/compile -j"$JOBS" V=s \
    || die "util-linux compile failed (needed for partx-utils ipk)"
  local parted_tgt=""
  if [[ -d package/feeds/packages/parted ]]; then
    parted_tgt=package/feeds/packages/parted
  elif [[ -d package/feeds/packages/utils/parted ]]; then
    parted_tgt=package/feeds/packages/utils/parted
  else
    log "parted feed path missing — feeds install -f parted"
    ./scripts/feeds install -f parted \
      || die "feeds install parted failed (packages feed required)"
    if [[ -d package/feeds/packages/parted ]]; then
      parted_tgt=package/feeds/packages/parted
    elif [[ -d package/feeds/packages/utils/parted ]]; then
      parted_tgt=package/feeds/packages/utils/parted
    else
      die "parted still missing under package/feeds/packages after feeds install"
    fi
  fi
  make "${parted_tgt}/compile" -j"$JOBS" V=s \
    || die "parted compile failed (target=${parted_tgt})"
  find bin -name 'resize2fs_*.ipk' -print | grep -q . \
    || die "resize2fs ipk not produced — use CONFIG_PACKAGE_resize2fs=y (not e2fsprogs alone)"
  find bin -name 'parted_*.ipk' -print | grep -q . \
    || die "parted ipk not produced — packages feed + CONFIG_PACKAGE_parted=y"
  find bin -name 'partx-utils_*.ipk' -print | grep -q . \
    || die "partx-utils ipk not produced — use CONFIG_PACKAGE_partx-utils=y (not partx)"
  find bin -name 'losetup_*.ipk' -print | grep -q . \
    || die "losetup ipk not produced — use CONFIG_PACKAGE_losetup=y"
}

ensure_gfc_client_pkginfo() {
  local pkginfo="$STAGING_PKGINFO/gfc-client.default.install"
  cd "$IMT_SRC"
  # Always rewrite: older scripts wrongly wrote a file listing here.
  if [[ -f "$pkginfo" ]] && grep -qx 'gfc-client' "$pkginfo"; then
    log "pkginfo OK: $pkginfo"
  else
    log "fix/write gfc-client.default.install (must be package name, not file list)"
    synthesize_gfc_client_default_install
  fi
  grep -qx 'gfc-client' "$pkginfo" || die "gfc-client.default.install must contain exactly package name 'gfc-client'"
}

find_rootfs_dir() {
  if [[ -d "$ROOTFS_DIR" ]]; then
    printf '%s\n' "$ROOTFS_DIR"
    return 0
  fi
  find "$TARGET_BUILD" -maxdepth 1 -type d -name 'root-*' 2>/dev/null | head -1
}

detect_opkg_arch() {
  if [[ -n "${GFC_OPKG_ARCH:-}" ]]; then
    printf '%s\n' "$GFC_OPKG_ARCH"
    return 0
  fi
  local cfg="$IMT_SRC/.config"
  if [[ -f "$cfg" ]]; then
    local arch
    arch="$(grep -E '^CONFIG_TARGET_ARCH_PACKAGES=' "$cfg" | cut -d= -f2- | tr -d '"')"
    [[ -n "$arch" ]] && { printf '%s\n' "$arch"; return 0; }
    grep -q '^CONFIG_x86_64=y' "$cfg" && { printf '%s\n' x86_64; return 0; }
  fi
  printf '%s\n' x86_64
}

prepare_ipk_for_opkg() {
  local ipk=$1
  if head -c 8 "$ipk" | grep -q '^!<arch>'; then
    printf '%s\n' "$ipk"
    return 0
  fi
  if tar tf "$ipk" debian-binary >/dev/null 2>&1; then
    printf '%s\n' "$ipk"
    return 0
  fi
  if file -b "$ipk" | grep -qi '^gzip compressed'; then
    local tmp
    tmp="$(mktemp /tmp/gfc-ipk.XXXXXX)"
    gunzip -c "$ipk" >"$tmp"
    printf '%s\n' "$tmp"
    return 0
  fi
  printf '%s\n' "$ipk"
}

rootfs_has_gfc_opkg() {
  local root=$1
  [[ -f "$root/usr/lib/opkg/info/gfc-client.control" ]] \
    || grep -q '^Package: gfc-client$' "$root/usr/lib/opkg/status" 2>/dev/null
}

synthesize_gfc_client_default_install() {
  # OpenWrt PACKAGE_INSTALL_FILES: each *.default.install contains PACKAGE NAMES
  # (one per line), NOT a file listing. package/Makefile does:
  #   opkg install $(opkg_package_files $(cat *.install))
  local out="$STAGING_PKGINFO/gfc-client.default.install"
  mkdir -p "$STAGING_PKGINFO"
  printf '%s\n' gfc-client >"$out"
  log "wrote $out (package name only — required for opkg_install_list)"
}

validate_ipk() {
  local ipk="$1"
  [[ -f "$ipk" ]] || die "ipk not found: $ipk"
  [[ -s "$ipk" ]] || die "ipk empty (compile may have failed): $ipk"
  if ! file -b "$ipk" | grep -qiE 'ar archive|debian|gzip|tar|zip'; then
    die "ipk not a valid archive: $ipk ($(file -b "$ipk"))"
  fi
}

find_newest_ipk() {
  local pattern=$1
  find "$IMT_SRC/bin" -name "$pattern" -type f -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-
}

find_gfc_ipk() {
  local ipk
  ipk="$(find_newest_ipk 'gfc-client_*.ipk')"
  [[ -n "$ipk" ]] || return 1
  validate_ipk "$ipk"
  printf '%s\n' "$ipk"
}

find_luci_ipk() {
  local ipk
  ipk="$(find_newest_ipk 'luci-app-gfc_*.ipk')"
  [[ -n "$ipk" ]] || return 1
  validate_ipk "$ipk"
  printf '%s\n' "$ipk"
}

# Bust rootfs + image outputs. Do NOT call make target/install alone after this —
# OpenWrt may skip package/install when stamps exist, then tar/mksquashfs fails on missing root-x86.
force_rootfs() {
  cd "$IMT_SRC"
  log "bust rootfs + image cache (keep package build_dir/ipk)"
  rm -rf "$TARGET_BUILD"/root-*
  rm -rf "$LINUX_BUILD"/root.squashfs "$LINUX_BUILD"/root.ext4 "$LINUX_BUILD"/tmp
  rm -f "$TARGET_BUILD/stamp/.rootfs_installed"
  rm -f "$TARGET_BUILD/stamp/.target_install"
  rm -f "$IMT_SRC/bin/targets/x86/64/"*.manifest
  rm -f "$IMT_SRC/bin/targets/x86/64/"*rootfs.tar.gz
  rm -f "$IMT_SRC/bin/targets/x86/64/"*ext4*combined*efi*.img.gz
}

# package/install resolves every kmod via Depends: kernel (= VER~HASH-rN).
# If that exact kernel_*.ipk is missing from bin/targets/x86/64/packages/, OR
# bin/ still mixes an older vermagic (c2bd4df8 vs 57887482), opkg reports
# "cannot find dependency kernel" + misleading "incompatible architectures"
# for EVERY package. Always refresh unless GFC_SKIP_KERNEL_REFRESH=1.
read_build_vermagic() {
  local vermagic_file
  vermagic_file="$(
    find "$IMT_SRC/build_dir" -path '*/linux-x86_64/linux-*/.vermagic' 2>/dev/null \
      | head -1
  )"
  [[ -n "$vermagic_file" && -f "$vermagic_file" ]] || return 1
  tr -d '[:space:]' <"$vermagic_file"
}

read_build_kernel_ver() {
  local vermagic_file
  vermagic_file="$(
    find "$IMT_SRC/build_dir" -path '*/linux-x86_64/linux-*/.vermagic' 2>/dev/null \
      | head -1
  )"
  [[ -n "$vermagic_file" && -f "$vermagic_file" ]] || return 1
  local d
  d="$(basename "$(dirname "$vermagic_file")")"
  printf '%s\n' "${d#linux-}"
}

verify_kernel_ipk_for_install() {
  local hash=$1 kernel_ver=$2
  local pkgdir="$IMT_SRC/bin/targets/x86/64/packages"
  local ipk ver
  [[ -d "$pkgdir" ]] || die "missing $pkgdir after kernel rebuild"
  ipk="$(find "$pkgdir" -maxdepth 1 -name "kernel_${kernel_ver}~${hash}*.ipk" 2>/dev/null | head -1)"
  [[ -n "$ipk" ]] || die "missing $pkgdir/kernel_${kernel_ver}~${hash}*.ipk (package/install cannot resolve kmods)"
  ver="$(
    tar -xOf "$ipk" ./control.tar.gz 2>/dev/null | tar -xzO ./control 2>/dev/null \
      || tar -xOf "$ipk" control.tar.gz 2>/dev/null | tar -xzO control 2>/dev/null \
      || true
  )"
  ver="$(printf '%s\n' "$ver" | awk -F': ' '/^Version:/{print $2; exit}')"
  [[ -n "$ver" ]] || die "cannot read Version from $ipk"
  [[ "$ver" == "${kernel_ver}~${hash}-"* ]] \
    || die "kernel ipk Version=$ver does not match build ${kernel_ver}~${hash}-* ($ipk)"
  log "kernel ipk OK: $(basename "$ipk") Version=$ver"
}

prepare_package_install_abi() {
  local hash kernel_ver pkgdir mixed
  cd "$IMT_SRC"
  hash="$(read_build_vermagic)" || die "no .vermagic under build_dir — compile target/linux first"
  kernel_ver="$(read_build_kernel_ver)" || die "cannot parse kernel version from build_dir"
  pkgdir="bin/targets/x86/64/packages"
  log "prepare package/install ABI: kernel=${kernel_ver} vermagic=${hash}"

  if [[ "${GFC_SKIP_KERNEL_REFRESH:-0}" == "1" ]]; then
    log "GFC_SKIP_KERNEL_REFRESH=1 — only verify existing kernel ipk"
    verify_kernel_ipk_for_install "$hash" "$kernel_ver"
    return 0
  fi

  # Any Packages index mentioning a different 6.6.x~hash means mixed ABI.
  mixed=0
  while IFS= read -r pkg_index; do
    [[ -f "$pkg_index" ]] || continue
    if grep -E "kernel \(= 6\.6\.[0-9]+~[0-9a-f]+" "$pkg_index" 2>/dev/null \
      | grep -v "~${hash}" >/dev/null 2>&1; then
      mixed=1
      log "mixed kernel ABI in $pkg_index"
      break
    fi
  done < <(find bin -type f -name Packages 2>/dev/null)

  # CRITICAL: do NOT wipe the whole target packages dir.
  # OpenWrt puts nonshared packages there (base-files, etc.). Wiping it then only
  # rebuilding kernel left package/install without base-files → no /etc/rc.common
  # and bogus "./etc/rc.common: No such file" during enable (and broken images).
  mkdir -p "$pkgdir"
  log "refresh kernel/kmod ipks only under $pkgdir (preserve base-files and other nonshared)"
  find "$pkgdir" -maxdepth 1 -type f \( \
    -name 'kernel_*.ipk' -o -name 'kmod-*.ipk' \
    -o -name 'Packages' -o -name 'Packages.gz' -o -name 'Packages.sig' -o -name 'Packages.manifest' \
  \) -delete 2>/dev/null || true
  # Drop out-of-tree Realtek leftovers that often pin an old vermagic.
  find bin -type f \( \
    -name 'kmod-r8101_*.ipk' -o -name 'kmod-r8125_*.ipk' -o -name 'kmod-r8126_*.ipk' \
    -o -name 'kmod-r8168_*.ipk' -o -name 'kmod-usb-net-rtl8152-vendor_*.ipk' \
  \) -delete 2>/dev/null || true

  log "clean + compile package/kernel/linux (produces kernel_*.ipk + kmods)"
  make package/kernel/linux/clean V=s 2>/dev/null || true
  make target/linux/compile -j"$JOBS" V=s \
    || die "target/linux/compile failed"
  make package/kernel/linux/compile -j"$JOBS" V=s \
    || die "package/kernel/linux/compile failed"
  verify_kernel_ipk_for_install "$hash" "$kernel_ver"

  # Always ensure base-files ipk exists and contains /etc/rc.common.
  ensure_base_files_ipk

  # Do NOT run full `make package/compile` here — it rebuilds the whole tree and
  # commonly fails on an unrelated package under -jN. Userspace ipks stay in
  # bin/packages/x86_64/. Opt-in: GFC_FULL_PACKAGE_COMPILE=1
  if [[ "${GFC_FULL_PACKAGE_COMPILE:-0}" == "1" ]]; then
    log "GFC_FULL_PACKAGE_COMPILE=1 — make package/compile"
    if ! BUILD_LOG=1 make package/compile -j"$JOBS" V=s; then
      die "full package/compile failed — see logs/package/*/compile.txt or recover-package-install.sh"
    fi
    make package/index -j1 V=s 2>/dev/null || true
  fi
  verify_kernel_ipk_for_install "$hash" "$kernel_ver"
  verify_required_gfc_ipks
  ensure_base_files_ipk

  if [[ "$mixed" -eq 1 ]]; then
    log "note: had mixed ABI indexes before refresh; re-check for leftover stale hashes"
    while IFS= read -r pkg_index; do
      [[ -f "$pkg_index" ]] || continue
      if grep -E "kernel \(= 6\.6\.[0-9]+~[0-9a-f]+" "$pkg_index" 2>/dev/null \
        | grep -v "~${hash}" >/dev/null 2>&1; then
        log "WARN: still stale ABI in $pkg_index — removing that Packages file"
        rm -f "$pkg_index" "${pkg_index}.gz" "${pkg_index}.sig" 2>/dev/null || true
      fi
    done < <(find bin -type f -name Packages 2>/dev/null)
  fi
  log "package/install ABI ready (kernel refreshed; base-files preserved/rebuilt)"
}

# base-files is nonshared → lives in bin/targets/.../packages/. Must contain rc.common.
ensure_base_files_ipk() {
  local src_rc ipk tmp data
  cd "$IMT_SRC"
  src_rc="package/base-files/files/etc/rc.common"
  [[ -f "$src_rc" ]] || die "missing $src_rc in ImmortalWrt tree — checkout is broken"

  ipk="$(find bin/targets/x86/64/packages -maxdepth 1 -name 'base-files_*.ipk' -type f 2>/dev/null | head -1 || true)"
  if [[ -n "$ipk" ]]; then
    tmp="$(mktemp -d /tmp/gfc-bf.XXXXXX)"
    data=""
    if ( cd "$tmp" && ar x "$ipk" >/dev/null 2>&1 ); then
      if [[ -f "$tmp/data.tar.gz" ]]; then
        data="$tmp/data.tar.gz"
      elif [[ -f "$tmp/data.tar.zst" ]]; then
        data="$tmp/data.tar.zst"
      fi
    fi
    if [[ -n "$data" ]] && tar -t -f "$data" 2>/dev/null | grep -qE '^\./etc/rc\.common$|^etc/rc\.common$'; then
      log "base-files ipk OK: $(basename "$ipk") contains etc/rc.common"
      rm -rf "$tmp"
      return 0
    fi
    log "WARN: $(basename "${ipk:-none}") missing etc/rc.common — rebuilding base-files"
    rm -rf "$tmp"
  else
    log "base-files_*.ipk missing under bin/targets/x86/64/packages — compiling"
  fi

  make package/base-files/clean V=s 2>/dev/null || true
  rm -rf build_dir/target-x86_64_musl/linux-x86_64/base-files
  make package/base-files/compile -j"$JOBS" V=s \
    || die "package/base-files/compile failed"
  ipk="$(find bin/targets/x86/64/packages -maxdepth 1 -name 'base-files_*.ipk' -type f 2>/dev/null | head -1 || true)"
  [[ -n "$ipk" ]] || die "base-files ipk still missing after compile"
  tmp="$(mktemp -d /tmp/gfc-bf.XXXXXX)"
  ( cd "$tmp" && ar x "$ipk" ) || die "cannot ar x $ipk"
  data=""
  if [[ -f "$tmp/data.tar.gz" ]]; then
    data="$tmp/data.tar.gz"
  elif [[ -f "$tmp/data.tar.zst" ]]; then
    data="$tmp/data.tar.zst"
  else
    die "no data.tar.* in $ipk"
  fi
  tar -t -f "$data" | grep -qE '^\./etc/rc\.common$|^etc/rc\.common$' \
    || die "rebuilt $ipk still lacks etc/rc.common — ImmortalWrt package/base-files tree broken"
  rm -rf "$tmp"
  log "base-files rebuilt OK: $(basename "$ipk")"
  # Note: ipkg-build may warn find: .../etc/config/network missing — those conffiles
  # are optional at pack time (created on first boot). Harmless if rc.common is present.
}

# Ensure GFC OEM runtime packages were actually built (not only kernel).
verify_required_gfc_ipks() {
  local name missing=0
  local pkgs=(
    gfc-client luci-app-gfc luci-base luci-theme-bootstrap luci-mod-admin-full
    sing-box unbound-daemon unbound-checkconf dnsmasq-full
    tc-tiny kmod-sched-core kmod-sched kmod-ifb kmod-tcp-bbr kmod-tun kmod-nft-core
    nftables-json curl wget-ssl tcpdump iftop bmon autossh
    libcap libcap-bin ca-bundle ip-full resize2fs parted partx-utils losetup
  )
  log "verify required GFC ipks under bin/"
  for name in "${pkgs[@]}"; do
    if find bin -type f -name "${name}_*.ipk" 2>/dev/null | grep -q .; then
      :
    else
      log "MISSING ipk: ${name}_*.ipk"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || die "required GFC packages missing after package/compile — check .config / feeds"
  log "required GFC ipks present"
}

require_rootfs_populated() {
  local root="$1"
  [[ -d "$root" ]] || die "rootfs dir missing: $root (run make package/install first)"
  [[ -d "$root/etc" && -d "$root/usr" ]] \
    || die "rootfs dir incomplete: $root (package/install did not populate rootfs)"
}

install_rootfs() {
  cd "$IMT_SRC"
  prepare_package_install_abi
  log "package/install -> populate $ROOTFS_DIR (+ snapshot $ROOTFS_ORIG_DIR)"
  make package/install -j1 V=s
  require_rootfs_populated "$ROOTFS_DIR"
  [[ -d "$ROOTFS_ORIG_DIR" ]] || die "missing $ROOTFS_ORIG_DIR after package/install (Image/Manifest uses ORIG)"
  # base-files must be present. Build-time "./etc/rc.common: No such file" is ONLY
  # OK when the file exists in ORIG — if missing, enable failed and image is broken.
  assert_rootfs_base_files "$ROOTFS_DIR"
  assert_rootfs_base_files "$ROOTFS_ORIG_DIR"
  if grep -qE 'gfc-client_.*\.ipk' "$IMT_SRC/tmp/opkg_install_list" 2>/dev/null; then
    log "opkg_install_list includes gfc-client ipk"
  else
    log "WARN: gfc-client still missing from opkg_install_list — will inject into TARGET_DIR + ORIG"
  fi
}

assert_rootfs_base_files() {
  local root=$1
  local missing=0
  for f in \
    "$root/etc/rc.common" \
    "$root/sbin/init" \
    "$root/etc/inittab" \
    "$root/bin/busybox"
  do
    if [[ ! -e "$f" ]]; then
      log "ERROR: missing required rootfs file: $f"
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    die "rootfs incomplete under $root (base-files not installed). Fix:
  cd $IMT_SRC
  ls bin/packages/*/base/base-files_*.ipk bin/targets/*/packages/base-files_*.ipk 2>/dev/null
  make package/base-files/clean package/base-files/compile -j\${JOBS:-$(nproc)} V=s
  rm -rf build_dir/target-*/root-* build_dir/target-*/stamp/.rootfs_installed
  make package/install -j1 V=s
Then re-run rebuild-gfc-image.sh. Do NOT flash images built without /etc/rc.common."
  fi
  local n
  n="$(find "$root/etc/rc.d" -maxdepth 1 -name 'S*' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${n:-0}" -lt 5 ]]; then
    die "rootfs $root has almost no /etc/rc.d/S* ($n) — service enable failed (often because rc.common missing). Rebuild base-files + package/install."
  fi
  log "rootfs base OK: rc.common + init + inittab + busybox; rc.d/S*=$n ($root)"
}

# Manifest + images come from TARGET_DIR_ORIG. Inject must update BOTH trees.
sync_gfc_into_orig() {
  local root=$1
  local orig="${2:-$ROOTFS_ORIG_DIR}"
  [[ -d "$orig" ]] || die "ORIG rootfs missing: $orig"
  log "sync gfc from $(basename "$root") → $(basename "$orig") (required for Image/Manifest)"
  mkdir -p "$orig/usr/bin" "$orig/usr/lib" "$orig/etc" "$orig/usr/lib/opkg/info"
  for bin in gfc-api gfc-agent gfc-bootstrap; do
    [[ -f "$root/usr/bin/$bin" ]] && cp -a "$root/usr/bin/$bin" "$orig/usr/bin/$bin"
  done
  [[ -d "$root/usr/lib/gfc-client" ]] && rm -rf "$orig/usr/lib/gfc-client" && cp -a "$root/usr/lib/gfc-client" "$orig/usr/lib/"
  [[ -d "$root/etc/gfc-client" ]] && rm -rf "$orig/etc/gfc-client" && cp -a "$root/etc/gfc-client" "$orig/etc/"
  if [[ -d "$root/etc/uci-defaults" ]]; then
    mkdir -p "$orig/etc/uci-defaults"
    for f in "$root/etc/uci-defaults"/9*-gfc-*; do
      [[ -f "$f" ]] && cp -a "$f" "$orig/etc/uci-defaults/"
    done
  fi
  if [[ -d "$root/etc/hotplug.d" ]]; then
    mkdir -p "$orig/etc/hotplug.d"
    for sub in net iface; do
      if [[ -d "$root/etc/hotplug.d/$sub" ]]; then
        mkdir -p "$orig/etc/hotplug.d/$sub"
        for f in "$root/etc/hotplug.d/$sub"/99-gfc-*; do
          [[ -f "$f" ]] && cp -a "$f" "$orig/etc/hotplug.d/$sub/"
        done
      fi
    done
  fi
  [[ -d "$root/etc/init.d" ]] && for s in gfc-api gfc-agent gfc-unbound gfc-sing-box gfc-routing; do
    [[ -f "$root/etc/init.d/$s" ]] && cp -a "$root/etc/init.d/$s" "$orig/etc/init.d/$s"
  done
  if [[ -f "$root/usr/lib/opkg/info/gfc-client.control" ]]; then
    cp -a "$root/usr/lib/opkg/info/gfc-client".* "$orig/usr/lib/opkg/info/" 2>/dev/null || true
  fi
  if grep -q '^Package: gfc-client$' "$root/usr/lib/opkg/status" 2>/dev/null; then
    if ! grep -q '^Package: gfc-client$' "$orig/usr/lib/opkg/status" 2>/dev/null; then
      awk '
        BEGIN { keep=0 }
        /^Package: gfc-client$/ { keep=1 }
        keep { print }
        keep && /^$/ { exit }
      ' "$root/usr/lib/opkg/status" >>"$orig/usr/lib/opkg/status"
    fi
  fi
  rootfs_has_gfc_opkg "$orig" || die "ORIG still missing gfc-client opkg after sync"
  [[ -x "$orig/usr/bin/gfc-api" ]] || die "ORIG still missing gfc-api after sync"
}

diagnose_missing_gfc() {
  local root="$1"
  log "diagnose: gfc not in $root after package/install"
  grep -E 'CONFIG_PACKAGE_gfc|gfc-client' "$IMT_SRC/.config" || true
  ls -la "$STAGING_PKGINFO"/gfc-client* 2>/dev/null || log "no gfc-client pkginfo files"
  if [[ -f "$IMT_SRC/tmp/opkg_install_list" ]]; then
    log "opkg_install_list gfc lines:"
    grep -i gfc "$IMT_SRC/tmp/opkg_install_list" || log "(gfc not in opkg_install_list)"
  fi
}

opkg_install_ipk_into_rootfs() {
  local root="$1" ipk="$2"
  local opkg="$IMT_SRC/staging_dir/host/bin/opkg"
  local arch prepared cleanup=0
  arch="$(detect_opkg_arch)"
  [[ -x "$opkg" ]] || die "host opkg missing: $opkg"
  validate_ipk "$ipk"
  prepared="$(prepare_ipk_for_opkg "$ipk")"
  [[ "$prepared" != "$ipk" ]] && cleanup=1
  log "opkg install $(basename "$ipk") arch=${arch} offline-root=$root"
  mkdir -p "$root/tmp"
  IPKG_NO_SCRIPT=1 IPKG_INSTROOT="$root" TMPDIR="$root/tmp" \
    "$opkg" --offline-root "$root" \
      --force-postinstall --force-overwrite --force-depends \
      --add-dest root:/ \
      --add-arch "all:100" \
      --add-arch "${arch}:200" \
      install "$prepared"
  local rc=$?
  (( cleanup )) && rm -f "$prepared"
  return "$rc"
}

ipkg_is_tar_archive() {
  file -b "$1" | grep -qiE 'tar archive|POSIX tar'
}

ipkg_unpack_members() {
  local ipk=$1 tmp=$2
  if head -c 8 "$ipk" | grep -q '^!<arch>'; then
    ( cd "$tmp" && ar x "$ipk" )
    return 0
  fi
  # ImmortalWrt ipk: gzip outer -> GNU tar(debian-binary, control.tar.*, data.tar.*)
  if ipkg_is_tar_archive "$ipk"; then
    tar xf "$ipk" -C "$tmp"
    return 0
  fi
  if tar tf "$ipk" 2>/dev/null | grep -qE '(^|/)debian-binary$'; then
    tar xf "$ipk" -C "$tmp"
    return 0
  fi
  die "cannot unpack ipk (not ar or tar): $ipk ($(file -b "$ipk"))"
}

ipkg_extract_data_into_rootfs() {
  local data=$1 root=$2
  case "$data" in
    *.tar.gz|*.tgz) tar xzf "$data" -C "$root" ;;
    *.tar.zst|*.tzst)
      if command -v zstd >/dev/null 2>&1; then
        zstd -dc "$data" | tar xf - -C "$root"
      elif [[ -x "$IMT_SRC/staging_dir/host/bin/zstd" ]]; then
        "$IMT_SRC/staging_dir/host/bin/zstd" -dc "$data" | tar xf - -C "$root"
      else
        die "data.tar.zst needs zstd: $data"
      fi
      ;;
    *.tar.xz|*.txz) tar xJf "$data" -C "$root" ;;
    *) die "unsupported data member: $data" ;;
  esac
}

ipkg_list_data_files() {
  local data=$1
  case "$data" in
    *.tar.gz|*.tgz) tar tzf "$data" ;;
    *.tar.zst|*.tzst)
      if command -v zstd >/dev/null 2>&1; then
        zstd -dc "$data" | tar tf -
      else
        "$IMT_SRC/staging_dir/host/bin/zstd" -dc "$data" | tar tf -
      fi
      ;;
    *.tar.xz|*.txz) tar tJf "$data" ;;
    *) die "unsupported data member for list: $data" ;;
  esac
}

register_opkg_metadata_from_ipk() {
  local ipk=$1 root=$2
  local tmp prepared ctrl_tmp cleanup=0
  local pkg ver arch depends info_dir
  tmp="$(mktemp -d)"
  prepared="$(prepare_ipk_for_opkg "$ipk")"
  [[ "$prepared" != "$ipk" ]] && cleanup=1
  ipkg_unpack_members "$prepared" "$tmp"
  shopt -s nullglob
  local controls=( "$tmp"/control.tar.* "$tmp"/*/control.tar.* )
  local data_members=( "$tmp"/data.tar.* "$tmp"/*/data.tar.* )
  shopt -u nullglob
  ((${#controls[@]})) || die "no control.tar.* in $ipk"
  ctrl_tmp="$(mktemp -d)"
  case "${controls[0]}" in
    *.tar.gz|*.tgz) tar xzf "${controls[0]}" -C "$ctrl_tmp" ;;
    *.tar.zst|*.tzst)
      if command -v zstd >/dev/null 2>&1; then
        zstd -dc "${controls[0]}" | tar xf - -C "$ctrl_tmp"
      else
        "$IMT_SRC/staging_dir/host/bin/zstd" -dc "${controls[0]}" | tar xf - -C "$ctrl_tmp"
      fi
      ;;
    *.tar.xz|*.txz) tar xJf "${controls[0]}" -C "$ctrl_tmp" ;;
    *) die "unsupported control member: ${controls[0]}" ;;
  esac
  [[ -f "$ctrl_tmp/control" ]] || die "control file missing in $ipk"
  pkg="$(awk -F': ' '/^Package:/{print $2; exit}' "$ctrl_tmp/control")"
  ver="$(awk -F': ' '/^Version:/{print $2; exit}' "$ctrl_tmp/control")"
  arch="$(awk -F': ' '/^Architecture:/{print $2; exit}' "$ctrl_tmp/control")"
  depends="$(awk -F': ' '/^Depends:/{print $2; exit}' "$ctrl_tmp/control")"
  [[ -n "$pkg" && -n "$ver" ]] || die "invalid control in $ipk"
  info_dir="$root/usr/lib/opkg/info"
  mkdir -p "$info_dir"
  cp "$ctrl_tmp/control" "$info_dir/${pkg}.control"
  : >"$info_dir/${pkg}.list"
  for data in "${data_members[@]}"; do
    [[ -f "$data" ]] || continue
    ipkg_list_data_files "$data" >>"$info_dir/${pkg}.list"
  done
  if ! grep -q "^Package: ${pkg}$" "$root/usr/lib/opkg/status" 2>/dev/null; then
    {
      echo "Package: $pkg"
      echo "Version: $ver"
      echo "Depends: ${depends:-}"
      echo "Status: install ok installed"
      echo "Architecture: ${arch:-$(detect_opkg_arch)}"
      echo "Installed-Time: $(date +%s)"
      echo
    } >>"$root/usr/lib/opkg/status"
  fi
  rm -rf "$ctrl_tmp" "$tmp"
  (( cleanup )) && rm -f "$prepared"
  log "opkg metadata registered from ipk: $pkg $ver"
}

ipkg_extract_into_rootfs() {
  local ipk="$1" root="$2"
  local tmp prepared data cleanup=0
  tmp="$(mktemp -d)"
  prepared="$(prepare_ipk_for_opkg "$ipk")"
  [[ "$prepared" != "$ipk" ]] && cleanup=1
  ipkg_unpack_members "$prepared" "$tmp"
  shopt -s nullglob
  local members=( "$tmp"/data.tar.* "$tmp"/*/data.tar.* )
  shopt -u nullglob
  for data in "${members[@]}"; do
    [[ -f "$data" ]] || continue
    ipkg_extract_data_into_rootfs "$data" "$root"
    rm -rf "$tmp"
    (( cleanup )) && rm -f "$prepared"
    return 0
  done
  rm -rf "$tmp"
  (( cleanup )) && rm -f "$prepared"
  die "ipk has no data.tar.* member: $ipk"
}

ensure_gfc_in_rootfs() {
  local root="$1"
  local ipk lipk
  ipk="$(find_gfc_ipk)" || die "gfc-client ipk not found under bin/ (run build_packages first)"
  lipk="$(find_luci_ipk 2>/dev/null || true)"

  # Prefer native install path: if ORIG already has opkg metadata, package/install succeeded.
  if rootfs_has_gfc_opkg "$ROOTFS_ORIG_DIR" && [[ -x "$ROOTFS_ORIG_DIR/usr/bin/gfc-api" ]]; then
    log "ORIG already has gfc-client (native package/install) — OK for manifest"
    return 0
  fi

  if rootfs_has_gfc_opkg "$root" && [[ -x "$root/usr/bin/gfc-api" ]]; then
    log "TARGET_DIR has gfc; syncing to ORIG for Image/Manifest"
    sync_gfc_into_orig "$root" "$ROOTFS_ORIG_DIR"
    return 0
  fi

  diagnose_missing_gfc "$root"
  cd "$IMT_SRC"

  log "register gfc-client via opkg into TARGET_DIR (arch=$(detect_opkg_arch))"
  if ! opkg_install_ipk_into_rootfs "$root" "$ipk"; then
    log "opkg install failed — extract + register metadata"
    if [[ ! -x "$root/usr/bin/gfc-api" ]]; then
      ipkg_extract_into_rootfs "$ipk" "$root"
    fi
    register_opkg_metadata_from_ipk "$ipk" "$root"
  fi

  if [[ -n "$lipk" ]] && ! grep -q '^Package: luci-app-gfc$' "$root/usr/lib/opkg/status" 2>/dev/null; then
    log "register luci-app-gfc via opkg"
    opkg_install_ipk_into_rootfs "$root" "$lipk" \
      || { ipkg_extract_into_rootfs "$lipk" "$root"; register_opkg_metadata_from_ipk "$lipk" "$root"; }
  fi

  [[ -x "$root/usr/bin/gfc-api" ]] || die "gfc-api still missing after rootfs inject"
  rootfs_has_gfc_opkg "$root" \
    || die "gfc-api present but opkg status missing on TARGET_DIR"
  sync_gfc_into_orig "$root" "$ROOTFS_ORIG_DIR"
  log "rootfs OK: gfc-api + opkg on TARGET_DIR and ORIG"
}

regenerate_manifest_from_orig() {
  local orig="$ROOTFS_ORIG_DIR"
  local manifest="$IMT_SRC/bin/targets/x86/64/immortalwrt-x86-64-generic.manifest"
  local opkg="$IMT_SRC/staging_dir/host/bin/opkg"
  local arch
  arch="$(detect_opkg_arch)"
  [[ -x "$opkg" ]] || die "host opkg missing"
  [[ -d "$orig" ]] || die "ORIG missing for manifest regenerate"
  mkdir -p "$(dirname "$manifest")"
  log "regenerate manifest via opkg list-installed on ORIG"
  IPKG_NO_SCRIPT=1 IPKG_INSTROOT="$orig" TMPDIR="$orig/tmp" \
    "$opkg" --offline-root "$orig" \
      --add-dest root:/ \
      --add-arch "all:100" \
      --add-arch "${arch}:200" \
      list-installed >"$manifest"
  grep -q gfc-client "$manifest" || die "regenerated manifest still missing gfc-client"
}

build_target_images() {
  cd "$IMT_SRC"
  require_rootfs_populated "$ROOTFS_DIR"
  rootfs_has_gfc_opkg "$ROOTFS_ORIG_DIR" \
    || die "ORIG missing gfc-client before image build — Image/Manifest would omit it"
  log "target/linux/install (pack ORIG rootfs into images)"
  make target/linux/install -j1 V=s
  require_rootfs_populated "$ROOTFS_DIR"
  # Belt-and-suspenders: OpenWrt Image/Manifest reads ORIG; rewrite if race/stale.
  if ! grep -q gfc-client "$IMT_SRC/bin/targets/x86/64/"*.manifest 2>/dev/null; then
    log "WARN: image build manifest missing gfc-client — regenerating from ORIG"
    regenerate_manifest_from_orig
  fi
}

build_image() {
  cd "$IMT_SRC"
  merge_gfc_config
  verify_dotconfig
  refresh_build_metadata
  link_image_files_overlay
  install_rootfs

  local root
  root="$(find_rootfs_dir)"
  ensure_gfc_in_rootfs "$root"
  # Overlay + ipk both ship firstboot; ensure ORIG has it before image pack.
  if [[ ! -f "$ROOTFS_ORIG_DIR/etc/uci-defaults/99-gfc-firstboot" ]]; then
    mkdir -p "$ROOTFS_ORIG_DIR/etc/uci-defaults"
    cp -a "$GFC_DEPLOY/image/files/etc/uci-defaults/99-gfc-firstboot" \
      "$ROOTFS_ORIG_DIR/etc/uci-defaults/99-gfc-firstboot"
    chmod +x "$ROOTFS_ORIG_DIR/etc/uci-defaults/99-gfc-firstboot"
    log "injected 99-gfc-firstboot into ORIG"
  fi
  if [[ -f "$GFC_DEPLOY/image/files/etc/uci-defaults/95-gfc-rootpt-resize" ]]; then
    mkdir -p "$ROOTFS_ORIG_DIR/etc/uci-defaults"
    cp -a "$GFC_DEPLOY/image/files/etc/uci-defaults/95-gfc-rootpt-resize" \
      "$ROOTFS_ORIG_DIR/etc/uci-defaults/95-gfc-rootpt-resize"
    chmod +x "$ROOTFS_ORIG_DIR/etc/uci-defaults/95-gfc-rootpt-resize"
  fi
  if [[ -f "$GFC_DEPLOY/image/files/etc/uci-defaults/96-gfc-rootfs-resize" ]]; then
    mkdir -p "$ROOTFS_ORIG_DIR/etc/uci-defaults"
    cp -a "$GFC_DEPLOY/image/files/etc/uci-defaults/96-gfc-rootfs-resize" \
      "$ROOTFS_ORIG_DIR/etc/uci-defaults/96-gfc-rootfs-resize"
    chmod +x "$ROOTFS_ORIG_DIR/etc/uci-defaults/96-gfc-rootfs-resize"
  fi
  # Remove obsolete single-phase expand script if present from older trees.
  rm -f "$ROOTFS_ORIG_DIR/etc/uci-defaults/96-gfc-expand-rootfs"
  if [[ -f "$GFC_DEPLOY/image/files/etc/uci-defaults/97-gfc-oem-root-password" ]]; then
    mkdir -p "$ROOTFS_ORIG_DIR/etc/uci-defaults"
    cp -a "$GFC_DEPLOY/image/files/etc/uci-defaults/97-gfc-oem-root-password" \
      "$ROOTFS_ORIG_DIR/etc/uci-defaults/97-gfc-oem-root-password"
    chmod +x "$ROOTFS_ORIG_DIR/etc/uci-defaults/97-gfc-oem-root-password"
  fi
  if [[ -f "$GFC_DEPLOY/image/files/etc/uci-defaults/98-gfc-network-ports" ]]; then
    mkdir -p "$ROOTFS_ORIG_DIR/etc/uci-defaults"
    cp -a "$GFC_DEPLOY/image/files/etc/uci-defaults/98-gfc-network-ports" \
      "$ROOTFS_ORIG_DIR/etc/uci-defaults/98-gfc-network-ports"
    chmod +x "$ROOTFS_ORIG_DIR/etc/uci-defaults/98-gfc-network-ports"
  fi
  if [[ -f "$GFC_DEPLOY/image/files/etc/uci-defaults/93-gfc-vga-console" ]]; then
    mkdir -p "$ROOTFS_ORIG_DIR/etc/uci-defaults"
    cp -a "$GFC_DEPLOY/image/files/etc/uci-defaults/93-gfc-vga-console" \
      "$ROOTFS_ORIG_DIR/etc/uci-defaults/93-gfc-vga-console"
    chmod +x "$ROOTFS_ORIG_DIR/etc/uci-defaults/93-gfc-vga-console"
  fi
  # First-boot VGA login: patch inittab in both trees before packing images.
  patch_vga_inittab "$root"
  patch_vga_inittab "$ROOTFS_ORIG_DIR"
  build_target_images
}

verify_manifest() {
  cd "$IMT_SRC"
  local manifest="bin/targets/x86/64/immortalwrt-x86-64-generic.manifest"
  local root orig pkg
  root="$(find_rootfs_dir)"
  orig="$ROOTFS_ORIG_DIR"
  [[ -f "$manifest" ]] || die "missing $manifest"
  log "TARGET_DIR: $(test -x "$root/usr/bin/gfc-api" && echo has gfc-api || echo NO gfc-api)"
  log "ORIG: $(rootfs_has_gfc_opkg "$orig" && echo gfc-client registered || echo NO gfc-client opkg)"
  log "firstboot: $(test -f "$orig/etc/uci-defaults/99-gfc-firstboot" && echo present || echo MISSING)"
  if ! grep -q gfc-client "$manifest"; then
    log "manifest stale — regenerate from ORIG"
    regenerate_manifest_from_orig
  fi
  log "manifest gfc lines:"
  grep -i gfc "$manifest" || true
  grep -i gfc-client "$manifest" >/dev/null || die "manifest has no gfc-client"
  grep -i luci-app-gfc "$manifest" >/dev/null || die "manifest has no luci-app-gfc"
  for pkg in tc-tiny kmod-sched-core kmod-ifb kmod-tcp-bbr kmod-sched resize2fs parted partx-utils losetup; do
    grep -qE "^${pkg}( |$)" "$manifest" \
      || die "manifest missing ${pkg}"
  done
  log "manifest tc/htb/bbr lines:"
  grep -E '^(tc-tiny|kmod-sched-core|kmod-ifb|kmod-tcp-bbr|kmod-sched) ' "$manifest" || true
  log "manifest expand lines:"
  grep -E '^(resize2fs|parted|partx-utils|losetup) ' "$manifest" || true
  rootfs_has_tc "$orig" \
    || die "ORIG missing tc binary (/sbin/tc or /usr/libexec/tc-tiny) — package/install did not ship tc-tiny"
  log "ORIG tc: $(ls -la "$orig/sbin/tc" "$orig/usr/libexec/tc-tiny" 2>/dev/null || true)"
  [[ -x "$orig/usr/sbin/resize2fs" || -x "$orig/sbin/resize2fs" ]] \
    || die "ORIG missing resize2fs binary — select CONFIG_PACKAGE_resize2fs=y (not e2fsprogs alone)"
  [[ -x "$orig/usr/sbin/partx" || -x "$orig/sbin/partx" ]] \
    || die "ORIG missing partx binary — select CONFIG_PACKAGE_partx-utils=y (not partx)"
  [[ -f "$orig/etc/uci-defaults/95-gfc-rootpt-resize" ]] \
    || die "ORIG missing /etc/uci-defaults/95-gfc-rootpt-resize"
  [[ -f "$orig/etc/uci-defaults/96-gfc-rootfs-resize" ]] \
    || die "ORIG missing /etc/uci-defaults/96-gfc-rootfs-resize"
  [[ -x "$orig/etc/init.d/gfc-lan-dhcp" ]] \
    || die "ORIG missing /etc/init.d/gfc-lan-dhcp"
  [[ -f "$orig/etc/uci-defaults/99-gfc-firstboot" ]] \
    || die "ORIG missing /etc/uci-defaults/99-gfc-firstboot"
  # prepare_rootfs may print "./etc/rc.common: No such file" while Enabling *;
  # that is a known OpenWrt offline-enable quirk. The file must still exist in ORIG.
  [[ -f "$orig/etc/rc.common" ]] \
    || die "ORIG missing /etc/rc.common — rootfs is broken (not the Enabling noise)"
  log "ORIG /etc/rc.common present (Enabling rc.common noise during build is OK)"
  [[ -x "$orig/usr/libexec/login.sh" || -x "$orig/bin/login" ]] \
    || die "ORIG missing login helper — inittab getty will fail with open errors"
  if grep -qE '^tty1::respawn:' "$orig/etc/inittab" 2>/dev/null; then
    die "ORIG inittab still has tty1::respawn (causes open spam) — patch_vga_inittab failed"
  fi
  if grep -qE '^ttyS[0-9]+::' "$orig/etc/inittab" 2>/dev/null; then
    die "ORIG inittab still has active ttyS* getty — patch_vga_inittab failed"
  fi
  log "ORIG inittab OK (no ttyS* getty, no tty1 respawn)"
  ls -lh bin/targets/x86/64/*ext4*combined*efi*.img.gz
}

# Versioned image names are for formal releases only (see docs/VERSION_AND_RELEASE.md §1.5).
#   GFC_PUBLISH_RELEASE=1  →  gfc-os-v{product}-client-{ver}-r{N}-….img.gz
#   otherwise              →  optional gfc-build-<gitsha>-….img.gz (not a product version)
publish_versioned_image() {
  local src dest pkg_ver pkg_rel product outdir gitsha
  outdir="$IMT_SRC/bin/targets/x86/64"
  src="$(ls -1t "$outdir"/*ext4*combined*efi*.img.gz 2>/dev/null | grep -vE '/gfc-(os|build)-' | head -1 || true)"
  [[ -n "$src" && -f "$src" ]] || die "no stock combined-efi img.gz to copy"
  pkg_ver="$(grep -E '^PKG_VERSION:=' "$GFC_DEPLOY/package/Makefile" | head -1 | cut -d= -f2-)"
  pkg_rel="$(grep -E '^PKG_RELEASE:=' "$GFC_DEPLOY/package/Makefile" | head -1 | cut -d= -f2-)"
  [[ -n "$pkg_ver" && -n "$pkg_rel" ]] || die "cannot read PKG_VERSION/RELEASE from Makefile"
  gitsha="$(git -C "${GFC_REPO}/.." rev-parse --short HEAD 2>/dev/null || echo nogit)"

  if [[ "${GFC_PUBLISH_RELEASE:-0}" == "1" ]]; then
    product="unknown"
    local matrix=""
    [[ -f "$GFC_REPO/../docs/releases/VERSION_MATRIX.json" ]] \
      && matrix="$GFC_REPO/../docs/releases/VERSION_MATRIX.json"
    [[ -z "$matrix" && -f "$(dirname "$GFC_REPO")/docs/releases/VERSION_MATRIX.json" ]] \
      && matrix="$(dirname "$GFC_REPO")/docs/releases/VERSION_MATRIX.json"
    if [[ -n "$matrix" ]]; then
      product="$(grep -E '"current"' "$matrix" | head -1 \
        | sed -E 's/.*"current"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
    fi
    dest="$outdir/gfc-os-v${product}-client-${pkg_ver}-r${pkg_rel}-x86-64-ext4-combined-efi.img.gz"
    log "GFC_PUBLISH_RELEASE=1 → formal release artifact"
  else
    dest="$outdir/gfc-build-${gitsha}-client-${pkg_ver}-r${pkg_rel}-x86-64-ext4-combined-efi.img.gz"
    log "dev/build artifact (not a product release). Formal name: GFC_PUBLISH_RELEASE=1"
  fi

  cp -f "$src" "$dest"
  ( cd "$outdir" && sha256sum "$(basename "$dest")" >"$(basename "$dest").sha256" )
  log "image copy: $dest"
  ls -lh "$dest" "$dest.sha256"
}

main() {
  require go
  load_feed_setup
  register_feed
  ensure_feeds_only
  merge_gfc_config
  verify_dotconfig
  refresh_build_metadata
  prepare_gfc_env
  build_packages
  force_rootfs
  build_image
  verify_manifest
  verify_image_grub_vga_console
  publish_versioned_image
  log "GFC firmware build OK"
}

main "$@"
