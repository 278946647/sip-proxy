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

func TestCopyIfMissing(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src.conf")
	dst := filepath.Join(dir, "dst.conf")
	if err := os.WriteFile(src, []byte("from-bundle\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := copyIfMissing(src, dst); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dst, []byte("operator-edit\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := copyIfMissing(src, dst); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(dst)
	if string(got) != "operator-edit\n" {
		t.Fatalf("operator file overwritten: %q", got)
	}
}
