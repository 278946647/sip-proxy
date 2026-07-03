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
	}
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return err
		}
	}
	files := map[string]string{
		filepath.Join(bundle, "domains-insecure.conf"): r.cfg.Paths.UnboundDomainsInsecure,
		filepath.Join(bundle, "conf.d", "cn.unbound.conf"): filepath.Join(
			r.cfg.Paths.UnboundConfD, "cn.unbound.conf",
		),
	}
	for src, dst := range files {
		if err := copyIfChanged(src, dst); err != nil {
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

func CheckConfig(path string) error {
	bin := findBinary("unbound-checkconf")
	if bin == "" {
		bin = findBinary("unbound")
		if bin == "" {
			return fmt.Errorf("unbound-checkconf binary not found")
		}
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
	for _, p := range []string{"/usr/sbin/" + name, "/usr/bin/" + name, "/usr/local/sbin/" + name} {
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
