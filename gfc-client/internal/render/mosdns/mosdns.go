package mosdns

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/platform"
)

const easyConfigURL = "https://raw.githubusercontent.com/pmkol/easymosdns/main/config.yaml"

var listenAddrRe = regexp.MustCompile(`addr:\s*["']0\.0\.0\.0:\d+["']`)

type Renderer struct {
	cfg *config.Config
}

func NewRenderer(cfg *config.Config) *Renderer {
	return &Renderer{cfg: cfg}
}

func (r *Renderer) EnsureTree(tryDownload bool) error {
	base := r.cfg.Paths.EasyMosdnsDir
	bundle := filepath.Join(r.cfg.Paths.Root, "share", "easymosdns")
	tmpl := r.cfg.Paths.MosdnsConfig
	openwrtTemplate := filepath.Join(bundle, "config-openwrt.yaml")

	if platform.IsOpenWrt() && fileExists(openwrtTemplate) && !validOpenWrtMosDNSConfig(tmpl) {
		if err := os.MkdirAll(base, 0o755); err != nil {
			return err
		}
		if err := copyFile(openwrtTemplate, tmpl); err == nil && validOpenWrtMosDNSConfig(tmpl) {
			return nil
		}
	}

	if validEasyConfig(tmpl) {
		return nil
	}

	if err := r.syncFromBundle(base, bundle); err == nil {
		return nil
	}

	if !tryDownload {
		return fmt.Errorf("easymosdns template missing or invalid (expected main_sequence)")
	}

	if err := os.RemoveAll(base); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(base, "rules"), 0o755); err != nil {
		return err
	}
	if err := downloadURL(easyConfigURL, tmpl); err != nil {
		return err
	}
	for _, name := range []string{"ecs_cn_domain.txt", "ecs_noncn_domain.txt", "hosts.txt"} {
		dst := filepath.Join(base, name)
		_ = downloadURL("https://raw.githubusercontent.com/pmkol/easymosdns/main/"+name, dst)
	}
	for _, name := range []string{
		"china_domain_list.txt", "gfw_domain_list.txt", "cdn_domain_list.txt",
		"china_ip_list.txt", "gfw_ip_list.txt", "ad_domain_list.txt",
	} {
		dst := filepath.Join(base, "rules", name)
		_ = downloadURL("https://raw.githubusercontent.com/pmkol/easymosdns/main/rules/"+name, dst)
	}
	if !validEasyConfig(tmpl) {
		return fmt.Errorf("downloaded easymosdns config invalid (expected main_sequence)")
	}
	return nil
}

func (r *Renderer) syncFromBundle(base, bundle string) error {
	if info, err := os.Stat(bundle); err != nil || !info.IsDir() {
		return fmt.Errorf("bundled easymosdns missing at %s", bundle)
	}
	if err := os.RemoveAll(base); err != nil {
		return err
	}
	if err := os.MkdirAll(base, 0o755); err != nil {
		return err
	}
	if err := copyBundledTree(bundle, base); err != nil {
		return err
	}
	if platform.IsOpenWrt() && fileExists(filepath.Join(base, "config-openwrt.yaml")) {
		if err := copyFile(filepath.Join(base, "config-openwrt.yaml"), r.cfg.Paths.MosdnsConfig); err != nil {
			return err
		}
		if validOpenWrtMosDNSConfig(r.cfg.Paths.MosdnsConfig) {
			return nil
		}
	}
	if !validEasyConfig(r.cfg.Paths.MosdnsConfig) {
		return fmt.Errorf("bundled easymosdns config invalid")
	}
	return nil
}

func validEasyConfig(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	s := string(data)
	return strings.Contains(s, "main_sequence") && strings.Contains(s, "data_providers:")
}

func validMosDNSV5Config(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	s := string(data)
	return strings.Contains(s, "main_sequence") &&
		strings.Contains(s, "type: sequence") &&
		(strings.Contains(s, "type: udp_server") || strings.Contains(s, "type: tcp_server"))
}

func validOpenWrtMosDNSConfig(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	s := string(data)
	return validMosDNSV5Config(path) && strings.Contains(s, "gfc_openwrt_mosdns_v2")
}

func fileExists(path string) bool {
	st, err := os.Stat(path)
	return err == nil && !st.IsDir()
}

// Render applies only path and listen-port fixes to the easymosdns config.
// Split rules and upstream lists come from easymosdns itself.
func (r *Renderer) Render() error {
	if err := r.EnsureTree(false); err != nil {
		return err
	}
	base := r.cfg.Paths.EasyMosdnsDir
	cfgPath := r.cfg.Paths.MosdnsConfig
	raw, err := os.ReadFile(cfgPath)
	if err != nil {
		return err
	}
	text := string(raw)
	text = strings.ReplaceAll(text, "./rules/", filepath.Join(base, "rules")+"/")
	text = strings.ReplaceAll(text, "./ecs_cn_domain.txt", filepath.Join(base, "ecs_cn_domain.txt"))
	text = strings.ReplaceAll(text, "./ecs_noncn_domain.txt", filepath.Join(base, "ecs_noncn_domain.txt"))
	text = strings.ReplaceAll(text, "./hosts.txt", filepath.Join(base, "hosts.txt"))
	text = listenAddrRe.ReplaceAllString(text, fmt.Sprintf(`addr: "0.0.0.0:%d"`, config.DefaultMosDNS))
	text = stripUnsupportedUpstreamKeys(text)
	text = stripFileLog(text)
	if !strings.Contains(text, "main_sequence") {
		return fmt.Errorf("render dropped main_sequence (source %s)", cfgPath)
	}
	if err := os.MkdirAll(filepath.Dir(cfgPath), 0o755); err != nil {
		return err
	}
	return os.WriteFile(cfgPath, []byte(text), 0o644)
}

// stripFileLog drops easymosdns file logging (systemd captures stderr; avoids permission churn).
func stripFileLog(raw string) string {
	lines := strings.Split(raw, "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		if strings.TrimSpace(line) == `file: "./mosdns.log"` {
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

// stripUnsupportedUpstreamKeys removes upstream fields mosdns-x does not accept.
func stripUnsupportedUpstreamKeys(raw string) string {
	lines := strings.Split(raw, "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "enable_http3: false" || trimmed == "enable_http3: true" {
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

func CheckConfig(path string) error {
	bin := findBinary("mosdns")
	if bin == "" {
		return fmt.Errorf("mosdns binary not found")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "start", "-c", path)
	out, err := cmd.CombinedOutput()
	s := strings.TrimSpace(string(out))
	if err == nil {
		return nil
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return nil
	}
	if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 124 {
		return nil
	}
	if strings.Contains(s, "124") {
		return nil
	}
	if s != "" {
		if strings.Contains(s, "address already in use") || strings.Contains(s, "bind: address already in use") {
			return nil
		}
		return fmt.Errorf("%s", s)
	}
	return fmt.Errorf("mosdns start failed (%v)", err)
}

func findBinary(name string) string {
	for _, p := range []string{"/usr/local/bin/" + name, "/usr/bin/" + name} {
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

func copyBundledTree(src, dst string) error {
	return exec.Command("cp", "-a", src+"/.", dst).Run()
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Close()
}

func downloadURL(url, dst string) error {
	client := &http.Client{Timeout: 120 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o644)
}
