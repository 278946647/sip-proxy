#!/usr/bin/env bash
# Download and install mosdns binary (mosdns-x preferred for easymosdns).
# Usage: MOS_ARCH=amd64 install_mosdns_bin /usr/local/bin/mosdns
# Optional: MOSDNS_VERSION=5.3.4 to pin IrineSistiana/mosdns release.
install_mosdns_bin() {
  local dest=$1
  local arch=${MOS_ARCH:-amd64}
  local tmp
  tmp=$(mktemp -d)

  local -a urls=()
  if [[ -n "${MOSDNS_VERSION:-}" ]]; then
    urls+=("https://github.com/IrineSistiana/mosdns/releases/download/v${MOSDNS_VERSION}/mosdns-linux-${arch}.zip")
  fi
  urls+=(
    "https://github.com/pmkol/mosdns-x/releases/latest/download/mosdns-linux-${arch}.zip"
    "https://github.com/IrineSistiana/mosdns/releases/latest/download/mosdns-linux-${arch}.zip"
  )

  local url ok=0
  for url in "${urls[@]}"; do
    echo "    Try mosdns: $url"
    if curl -fsSL --connect-timeout 15 --max-time 300 "$url" -o "$tmp/m.zip"; then
      ok=1
      break
    fi
  done

  if [[ "$ok" -ne 1 ]]; then
    echo "ERROR: mosdns download failed (pmkol/mosdns-x and IrineSistiana/mosdns)" >&2
    rm -rf "$tmp"
    return 1
  fi

  if ! command -v unzip >/dev/null; then
    apt-get install -y -qq unzip
  fi
  unzip -q "$tmp/m.zip" -d "$tmp"
  local bin
  bin=$(find "$tmp" -name mosdns -type f | head -1)
  if [[ -z "$bin" ]]; then
    echo "ERROR: mosdns binary not found in zip" >&2
    rm -rf "$tmp"
    return 1
  fi
  install -m 755 "$bin" "$dest"
  rm -rf "$tmp"
  "$dest" version 2>&1 | head -1 || true
  echo "    mosdns -> $dest"
}
