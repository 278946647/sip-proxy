#!/usr/bin/env bash
# Ensure Node.js >= NODE_MIN (default 18) — Ubuntu 22.04 apt nodejs is v12.
ensure_node() {
  local min=${NODE_MIN:-18}
  local ver=${NODE_VERSION:-20.18.1}
  local arch=${NODE_ARCH:-}

  if [[ -z "$arch" ]]; then
    case "$(uname -m)" in
      x86_64) arch=x64 ;;
      aarch64) arch=arm64 ;;
      *) echo "ERROR: unsupported arch for Node install: $(uname -m)" >&2; return 1 ;;
    esac
  fi

  export PATH="/usr/local/node/bin:${PATH}"

  if command -v node >/dev/null 2>&1; then
    local have major
    have=$(node -p "process.versions.node.split('.')[0]")
    if [[ "$have" -ge "$min" ]]; then
      echo "    Node $(node -v) (ok, need >= v${min})"
      return 0
    fi
    echo "    Node $(node -v) too old (need >= v${min}), installing v${ver}"
  else
    echo "    Node not found, installing v${ver}"
  fi

  local tmp url
  tmp=$(mktemp -d)
  url="https://nodejs.org/dist/v${ver}/node-v${ver}-linux-${arch}.tar.xz"
  echo "    Download $url"
  curl -fsSL "$url" -o "$tmp/node.tar.xz"
  rm -rf /usr/local/node
  mkdir -p /usr/local/node
  tar -xJf "$tmp/node.tar.xz" -C /usr/local/node --strip-components=1
  rm -rf "$tmp"

  export PATH="/usr/local/node/bin:${PATH}"
  if ! grep -qs '/usr/local/node/bin' /etc/profile.d/gfc-node-path.sh 2>/dev/null; then
    echo 'export PATH=/usr/local/node/bin:$PATH' >/etc/profile.d/gfc-node-path.sh
    chmod 644 /etc/profile.d/gfc-node-path.sh
  fi

  node -v
  npm -v
}
