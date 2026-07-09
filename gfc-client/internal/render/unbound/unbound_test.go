package unbound

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPatchOpenWrtPathsTrustAnchorAndChroot(t *testing.T) {
	text := `server:
    auto-trust-anchor-file: "/var/lib/unbound/root.key"
    tls-cert-bundle: "/etc/ssl/certs/ca-certificates.crt"
`
	out := patchOpenWrtPaths(text)
	if strings.Contains(out, `auto-trust-anchor-file: "/etc/unbound/root.key"`) {
		t.Fatalf("must not patch anchor to /etc/unbound/root.key:\n%s", out)
	}
	if !strings.Contains(out, `auto-trust-anchor-file: "/var/lib/unbound/root.key"`) {
		t.Fatalf("anchor path missing:\n%s", out)
	}
	if !strings.Contains(out, `chroot: ""`) {
		t.Fatalf("chroot disable missing:\n%s", out)
	}
}

func TestEnsureTrustAnchorLayoutCreatesAnchor(t *testing.T) {
	dir := t.TempDir()
	anchor := filepath.Join(dir, "root.key")
	chrootEtc := filepath.Join(dir, "etc", "unbound")
	if err := ensureTrustAnchorLayoutAt(dir, anchor, chrootEtc); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(anchor); err != nil {
		t.Fatalf("anchor not created: %v", err)
	}
	if _, err := os.Stat(filepath.Join(chrootEtc, "root.key")); err != nil {
		t.Fatalf("chroot anchor mirror missing: %v", err)
	}
}
