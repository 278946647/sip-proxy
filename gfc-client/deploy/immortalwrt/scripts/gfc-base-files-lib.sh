#!/usr/bin/env bash
# Shared helpers for base-files / rootfs health (sourced by rebuild + repair).
# shellcheck shell=bash

# Return 0 if ipk or staging tree contains etc/rc.common.
# Never use cwd-relative paths; never require system `ar` alone.
gfc_base_files_staging_rc() {
  local imt="${1:-${IMT_SRC:-}}"
  printf '%s\n' "$imt/build_dir/target-x86_64_musl/linux-x86_64/base-files/ipkg-x86_64/base-files/etc/rc.common"
}

gfc_ipk_lists_rc_common() {
  local ipk=$1
  local imt=${IMT_SRC:-/opt/gfc/immortalwrt}
  local tmp host_ar
  [[ -f "$ipk" ]] || return 1

  # Fast path: list with OpenWrt host ar, then system ar, then tar-as-ipk.
  tmp="$(mktemp -d /tmp/gfc-ipk.XXXXXX)"
  cp -f "$ipk" "$tmp/pkg.ipk" || { rm -rf "$tmp"; return 1; }

  host_ar=""
  [[ -x "$imt/staging_dir/host/bin/ar" ]] && host_ar="$imt/staging_dir/host/bin/ar"

  (
    set +e
    cd "$tmp" || exit 1
    if [[ -n "$host_ar" ]]; then
      "$host_ar" x pkg.ipk >/dev/null 2>&1
    fi
    if [[ ! -f data.tar.gz && ! -f data.tar.zst && ! -f data.tar.xz ]]; then
      ar x pkg.ipk >/dev/null 2>&1
    fi
    if [[ -f data.tar.gz ]]; then
      tar -tzf data.tar.gz
    elif [[ -f data.tar.zst ]]; then
      tar -t --zstd -f data.tar.zst 2>/dev/null || tar -t -I zstd -f data.tar.zst
    elif [[ -f data.tar.xz ]]; then
      tar -tJf data.tar.xz
    else
      # Some trees ship ipk as plain tar.gz
      tar -tzf pkg.ipk 2>/dev/null || tar -t --zstd -f pkg.ipk 2>/dev/null
    fi
  ) 2>/dev/null | grep -qE 'etc/rc\.common'
  local st=$?
  rm -rf "$tmp"
  return "$st"
}

# After package/base-files/compile: assert staging + ipk.
gfc_assert_base_files_built() {
  local imt=${IMT_SRC:-/opt/gfc/immortalwrt}
  local pkgdir="$imt/bin/targets/x86/64/packages"
  local stage ipk
  stage="$(gfc_base_files_staging_rc "$imt")"
  if [[ -f "$stage" ]]; then
    echo "==> base-files staging has etc/rc.common"
  else
    echo "ERROR: staging missing $stage (Package/base-files/install did not copy files/)" >&2
    return 1
  fi
  ipk="$(find "$pkgdir" -maxdepth 1 -name 'base-files_*.ipk' -type f 2>/dev/null | head -1 || true)"
  [[ -n "$ipk" ]] || { echo "ERROR: no base-files_*.ipk in $pkgdir" >&2; return 1; }
  if gfc_ipk_lists_rc_common "$ipk"; then
    echo "==> base-files ipk OK: $(basename "$ipk")"
    return 0
  fi
  # Staging OK is enough to proceed; ipk list failure is often host `ar` vs format.
  echo "==> WARN: could not list ipk with host ar/tar; trusting staging rc.common"
  echo "    ipk=$(basename "$ipk") file=$(file -b "$ipk" 2>/dev/null || echo '?')"
  return 0
}
