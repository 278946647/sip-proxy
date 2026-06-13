#!/usr/bin/env bash
# Ensure Go >= GO_MIN (default 1.22) — Ubuntu 22.04 apt golang-go is 1.18.
ensure_go() {
  local min=${GO_MIN:-1.22}
  local ver=${GO_VERSION:-1.22.10}
  local arch=${GO_ARCH:-}

  if [[ -z "$arch" ]]; then
    case "$(uname -m)" in
      x86_64) arch=amd64 ;;
      aarch64) arch=arm64 ;;
      *) echo "ERROR: unsupported arch for Go install: $(uname -m)" >&2; return 1 ;;
    esac
  fi

  if command -v go >/dev/null 2>&1; then
    local have
    have=$(go version | awk '{print $3}' | sed 's/^go//')
    if go_version_ge "$have" "$min"; then
      echo "    Go $have (ok, need >= $min)"
      export PATH="/usr/local/go/bin:${PATH}"
      return 0
    fi
    echo "    Go $have too old (need >= $min), installing go$ver"
  else
    echo "    Go not found, installing go$ver"
  fi

  local tmp url="/usr/local/go"
  tmp=$(mktemp -d)
  url="https://go.dev/dl/go${ver}.linux-${arch}.tar.gz"
  echo "    Download $url"
  curl -fsSL "$url" -o "$tmp/go.tgz"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$tmp/go.tgz"
  rm -rf "$tmp"

  export PATH="/usr/local/go/bin:${PATH}"
  if ! grep -qs '/usr/local/go/bin' /etc/profile.d/gfc-go-path.sh 2>/dev/null; then
    echo 'export PATH=/usr/local/go/bin:$PATH' >/etc/profile.d/gfc-go-path.sh
    chmod 644 /etc/profile.d/gfc-go-path.sh
  fi

  go version
}

# Return 0 if $1 >= $2
go_version_ge() {
  local have=$1 need=$2
  [[ "$(printf '%s\n' "$need" "$have" | sort -V | head -1)" == "$need" ]]
}
