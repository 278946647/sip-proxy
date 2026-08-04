package unbound

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/platform"
)

type Renderer struct {
	cfg *config.Config
}

func NewRenderer(cfg *config.Config) *Renderer {
	return &Renderer{cfg: cfg}
}

type DNSUpstream struct {
	Domestic string
	Intl     string
}

func upstreamFromPayload(payload map[string]any) DNSUpstream {
	up := DNSUpstream{
		Domestic: "223.5.5.5",
		Intl:     "1.1.1.1",
	}
	if payload == nil {
		return up
	}
	dns, _ := payload["dns"].(map[string]any)
	if dns == nil {
		return up
	}
	if v := strings.TrimSpace(fmt.Sprint(dns["domesticServer"])); v != "" {
		up.Domestic = v
	}
	if v := strings.TrimSpace(fmt.Sprint(dns["intlServer"])); v != "" {
		up.Intl = v
	}
	return up
}

func (r *Renderer) bundleDir() string {
	return filepath.Join(r.cfg.Paths.Root, "share", "unbound")
}

func (r *Renderer) EnsureTree() error {
	bundle := r.bundleDir()
	if st, err := os.Stat(bundle); err != nil || !st.IsDir() {
		return fmt.Errorf("bundled unbound config missing at %s", bundle)
	}
	dirs := []string{
		r.cfg.Paths.UnboundConfD,
		filepath.Dir(r.cfg.Paths.UnboundConfig),
		"/var/lib/unbound",
	}
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return err
		}
	}
	if err := EnsureTrustAnchorLayout(); err != nil {
		return err
	}
	// Bundle-managed: safe to re-sync from share on every Render.
	syncAlways := map[string]string{
		filepath.Join(bundle, "domains-insecure.conf"): r.cfg.Paths.UnboundDomainsInsecure,
		filepath.Join(bundle, "conf.d", "cn.unbound.conf"): filepath.Join(
			r.cfg.Paths.UnboundConfD, "cn.unbound.conf",
		),
	}
	for src, dst := range syncAlways {
		if err := copyIfChanged(src, dst); err != nil {
			return err
		}
	}
	// Operator-managed snippets: create once from bundle; never overwrite on ReloadDNS.
	operatorOnce := map[string]string{
		filepath.Join(bundle, "conf.d", "gfc-domestic-forward.conf"): filepath.Join(
			r.cfg.Paths.UnboundConfD, "gfc-domestic-forward.conf",
		),
		filepath.Join(bundle, "local.d", "gfc-block.conf"): filepath.Join(
			filepath.Dir(r.cfg.Paths.UnboundConfig), "local.d", "gfc-block.conf",
		),
		filepath.Join(bundle, "local.d", "gfc-static.conf"): filepath.Join(
			filepath.Dir(r.cfg.Paths.UnboundConfig), "local.d", "gfc-static.conf",
		),
	}
	for src, dst := range operatorOnce {
		if err := copyIfMissing(src, dst); err != nil {
			return err
		}
	}
	return nil
}

func (r *Renderer) Render(payload map[string]any) error {
	if err := r.EnsureTree(); err != nil {
		return err
	}
	up := upstreamFromPayload(payload)
	tmplPath := filepath.Join(r.bundleDir(), "unbound.conf.template")
	raw, err := os.ReadFile(tmplPath)
	if err != nil {
		return err
	}
	text := string(raw)
	text = strings.ReplaceAll(text, "223.5.5.5", up.Domestic)
	text = strings.ReplaceAll(text, "119.29.29.29", "119.29.29.29")
	text = patchIntlForwardZone(text, up.Intl)
	if platform.IsOpenWrt() {
		text = patchOpenWrtPaths(text)
	}
	if err := os.MkdirAll(filepath.Dir(r.cfg.Paths.UnboundConfig), 0o755); err != nil {
		return err
	}
	return os.WriteFile(r.cfg.Paths.UnboundConfig, []byte(text), 0o644)
}

func patchIntlForwardZone(text, intlServer string) string {
	intlServer = strings.TrimSpace(intlServer)
	if intlServer == "" || intlServer == "1.1.1.1" {
		return text
	}
	lines := strings.Split(text, "\n")
	out := make([]string, 0, len(lines))
	inDefaultZone := false
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == `forward-zone:` && !inDefaultZone {
			inDefaultZone = true
			out = append(out, line)
			continue
		}
		if inDefaultZone && strings.HasPrefix(trimmed, `name: "."`) {
			out = append(out, line)
			continue
		}
		if inDefaultZone && strings.HasPrefix(trimmed, "forward-addr:") {
			if strings.Contains(trimmed, "1.1.1.1") {
				out = append(out, fmt.Sprintf("    forward-addr: %s@853#cloudflare-dns.com", intlServer))
				continue
			}
			if strings.Contains(trimmed, "1.0.0.1") {
				continue
			}
		}
		if inDefaultZone && trimmed != "" && !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") && trimmed != `forward-zone:` {
			inDefaultZone = false
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

func patchOpenWrtPaths(text string) string {
	caCandidates := []string{
		"/etc/ssl/certs/ca-certificates.crt",
		"/etc/ssl/cert.pem",
		"/etc/ssl/cacert.pem",
	}
	for _, ca := range caCandidates {
		if _, err := os.Stat(ca); err == nil {
			text = strings.ReplaceAll(text,
				`tls-cert-bundle: "/etc/ssl/certs/ca-certificates.crt"`,
				fmt.Sprintf(`tls-cert-bundle: "%s"`, ca),
			)
			break
		}
	}
	// ImmortalWrt unbound-checkconf validates paths inside default chroot
	// (/var/lib/unbound). Never point auto-trust-anchor at /etc/unbound/root.key.
	if !strings.Contains(text, "\n    chroot:") {
		text = strings.Replace(text, "server:\n", "server:\n    chroot: \"\"\n", 1)
	}
	return text
}

const (
	defaultTrustAnchorPath = "/var/lib/unbound/root.key"
	opkgTrustAnchorPath    = "/etc/unbound/root.key"
	chrootAnchorDir        = "/var/lib/unbound/etc/unbound"
)

// EnsureTrustAnchorLayout prepares DNSSEC anchor files for unbound-checkconf on OpenWrt.
func EnsureTrustAnchorLayout() error {
	return ensureTrustAnchorLayoutAt("/var/lib/unbound", defaultTrustAnchorPath, chrootAnchorDir)
}

func ensureTrustAnchorLayoutAt(baseDir, anchorPath, chrootEtcDir string) error {
	if err := os.MkdirAll(baseDir, 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(chrootEtcDir, 0o755); err != nil {
		return err
	}
	chrootAnchor := filepath.Join(chrootEtcDir, "root.key")
	if st, err := os.Stat(anchorPath); err != nil || st.Size() == 0 {
		if data, readErr := os.ReadFile(opkgTrustAnchorPath); readErr == nil && len(data) > 0 {
			if writeErr := os.WriteFile(anchorPath, data, 0o644); writeErr != nil {
				return writeErr
			}
		} else if f, createErr := os.OpenFile(anchorPath, os.O_CREATE|os.O_WRONLY, 0o644); createErr == nil {
			_ = f.Close()
		} else if createErr != nil {
			return createErr
		}
	}
	anchorData, err := os.ReadFile(anchorPath)
	if err != nil {
		return err
	}
	if len(anchorData) == 0 {
		if f, createErr := os.OpenFile(anchorPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644); createErr == nil {
			_ = f.Close()
		}
	}
	if existing, readErr := os.ReadFile(chrootAnchor); readErr != nil || len(existing) == 0 {
		data, _ := os.ReadFile(anchorPath)
		if len(data) == 0 {
			data = []byte{}
		}
		if writeErr := os.WriteFile(chrootAnchor, data, 0o644); writeErr != nil {
			return writeErr
		}
	}
	return nil
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func copyIfChanged(src, dst string) error {
	in, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	if existing, err := os.ReadFile(dst); err == nil && string(existing) == string(in) {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	return os.WriteFile(dst, in, 0o644)
}

// copyIfMissing installs a bundle default only when the destination does not exist.
// Used for operator-edited unbound snippets so ReloadDNS cannot wipe them.
func copyIfMissing(src, dst string) error {
	if _, err := os.Stat(dst); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return err
	}
	in, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	return os.WriteFile(dst, in, 0o644)
}

func BinaryInstalled() bool {
	return findBinary("unbound-checkconf") != "" || findBinary("unbound") != ""
}

func CheckConfig(path string) error {
	if platform.IsOpenWrt() {
		if err := EnsureTrustAnchorLayout(); err != nil {
			return fmt.Errorf("trust anchor layout: %w", err)
		}
	}
	bin := findBinary("unbound-checkconf")
	if bin == "" {
		bin = findBinary("unbound")
	}
	if bin == "" {
		// ImmortalWrt install may render configs before opkg installs unbound.
		if platform.IsOpenWrt() || os.Getenv("GFC_SKIP_UNBOUND_CHECK") == "1" {
			return nil
		}
		return fmt.Errorf("unbound-checkconf binary not found (install unbound package)")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var cmd *exec.Cmd
	if strings.HasSuffix(filepath.Base(bin), "unbound-checkconf") {
		cmd = exec.CommandContext(ctx, bin, path)
	} else {
		cmd = exec.CommandContext(ctx, bin, "-c", path, "-d")
	}
	out, err := cmd.CombinedOutput()
	s := strings.TrimSpace(string(out))
	if err == nil {
		return nil
	}
	if s != "" {
		return fmt.Errorf("%s", s)
	}
	return fmt.Errorf("unbound config check failed (%v)", err)
}

func findBinary(name string) string {
	for _, p := range []string{
		"/usr/sbin/" + name,
		"/usr/bin/" + name,
		"/sbin/" + name,
		"/bin/" + name,
		"/usr/local/sbin/" + name,
	} {
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	p, err := exec.LookPath(name)
	if err != nil {
		return ""
	}
	return p
}

// FlushCache clears resolver message/RRset caches after proxy re-enable.
func FlushCache(confPath string) string {
	if confPath == "" {
		confPath = "/etc/unbound/unbound.conf"
	}
	bin := findBinary("unbound-control")
	if bin == "" {
		return ""
	}
	specs := [][]string{
		{bin, "-c", confPath, "flush"},
		{bin, "flush"},
	}
	for _, args := range specs {
		cmd := exec.Command(args[0], args[1:]...)
		if out, err := cmd.CombinedOutput(); err == nil {
			line := strings.TrimSpace(string(out))
			if line == "" {
				return "unbound cache flushed"
			}
			return line
		}
	}
	return ""
}
