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

func TestRenderBypassACLPublicHost(t *testing.T) {
	got := RenderBypassACL(true, []string{"103.78.41.18", "10.20.30.0/24"})
	if !strings.Contains(got, "access-control: 103.78.41.18/32 allow") {
		t.Fatalf("missing public host ACL:\n%s", got)
	}
	if !strings.Contains(got, "access-control: 10.20.30.0/24 allow") {
		t.Fatalf("missing cidr ACL:\n%s", got)
	}
	if strings.Contains(got, "0.0.0.0/0") {
		t.Fatal("must not allow all")
	}
	inactive := RenderBypassACL(false, []string{"103.78.41.18"})
	if strings.Contains(inactive, "allow") {
		t.Fatalf("gateway ACL must not allow hosts:\n%s", inactive)
	}
}
