package mosdns

import (
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
)

const easyConfigURL = "https://raw.githubusercontent.com/pmkol/easymosdns/main/config.yaml"

var listenRe = regexp.MustCompile(`addr:\s*["']0\.0\.0\.0:53["']`)

type Renderer struct {
	cfg *config.Config
}

func NewRenderer(cfg *config.Config) *Renderer {
	return &Renderer{cfg: cfg}
}

func (r *Renderer) EnsureTree(tryDownload bool) error {
	base := r.cfg.Paths.EasyMosdnsDir
	bundle := filepath.Join(r.cfg.Paths.Root, "share", "easymosdns")
	tmpl := filepath.Join(base, "config.yaml")

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
	if !validEasyConfig(filepath.Join(base, "config.yaml")) {
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

func (r *Renderer) Render() error {
	if err := r.EnsureTree(true); err != nil {
		return err
	}
	base := r.cfg.Paths.EasyMosdnsDir
	raw, err := os.ReadFile(filepath.Join(base, "config.yaml"))
	if err != nil {
		return err
	}
	text := string(raw)
	text = strings.ReplaceAll(text, "./rules/", filepath.Join(base, "rules")+"/")
	text = strings.ReplaceAll(text, "./ecs_cn_domain.txt", filepath.Join(base, "ecs_cn_domain.txt"))
	text = strings.ReplaceAll(text, "./ecs_noncn_domain.txt", filepath.Join(base, "ecs_noncn_domain.txt"))
	text = strings.ReplaceAll(text, "./hosts.txt", filepath.Join(base, "hosts.txt"))
	text = listenRe.ReplaceAllString(text, fmt.Sprintf(`addr: "0.0.0.0:%d"`, config.DefaultMosDNS))
	text = patchIntlDoH(text)
	text = injectGFCOverlay(text, r.cfg.Paths.DNSListsDir)
	if !strings.Contains(text, "main_sequence") {
		return fmt.Errorf("render dropped main_sequence (source %s)", filepath.Join(base, "config.yaml"))
	}
	if err := os.MkdirAll(filepath.Dir(r.cfg.Paths.MosdnsConfig), 0o755); err != nil {
		return err
	}
	return os.WriteFile(r.cfg.Paths.MosdnsConfig, []byte(text), 0o644)
}

func patchIntlDoH(raw string) string {
	if strings.Contains(raw, "https://1.1.1.1/dns-query") {
		return raw
	}
	// EasyMosdns ships tcp/udpme upstreams; replacing them with a broken regex drops main_sequence.
	if strings.Contains(raw, "udpme://") || strings.Contains(raw, "tcp://208.67") {
		return raw
	}
	block := `
  - tag: forward_remote
    type: fast_forward
    args:
      upstream:
        - addr: "https://1.1.1.1/dns-query"
          dial_addr: "1.1.1.1:443"
          enable_http3: false
        - addr: "https://8.8.8.8/dns-query"
          dial_addr: "8.8.8.8:443"
          enable_http3: false
`
	re := regexp.MustCompile(`(?m)^  - tag: forward_remote\n    type: fast_forward\n    args:\n      upstream:\n(?:        - .*\n|          .*\n)+`)
	if !re.MatchString(raw) {
		return raw
	}
	out := re.ReplaceAllString(raw, strings.TrimSpace(block)+"\n\n")
	if !strings.Contains(out, "main_sequence") {
		return raw
	}
	return out
}

func injectGFCOverlay(raw, listsDir string) string {
	if strings.Contains(raw, "gfc_block") {
		return raw
	}
	block := filepath.Join(listsDir, "block.txt")
	china := filepath.Join(listsDir, "china.txt")
	global := filepath.Join(listsDir, "global.txt")
	providers := fmt.Sprintf(`
  - tag: gfc_block
    file: %s
    auto_reload: false
  - tag: gfc_china
    file: %s
    auto_reload: false
  - tag: gfc_global
    file: %s
    auto_reload: false
`, block, china, global)
	plugins := `
  - tag: query_is_gfc_block
    type: query_matcher
    args:
      domain:
        - "provider:gfc_block"
  - tag: query_is_gfc_china
    type: query_matcher
    args:
      domain:
        - "provider:gfc_china"
  - tag: query_is_gfc_global
    type: query_matcher
    args:
      domain:
        - "provider:gfc_global"
`
	seq := `
        - if: query_is_gfc_block
          exec:
            - black_hole
            - ttl_1h
            - _return
        - if: query_is_gfc_china
          exec:
            - forward_local
            - ttl_5m
            - _return
        - if: query_is_gfc_global
          exec:
            - _prefer_ipv4
            - forward_remote
            - ttl_5m
            - _return
`
	if strings.Contains(raw, "data_providers:") {
		raw = strings.Replace(raw, "data_providers:", "data_providers:"+providers, 1)
	}
	if strings.Contains(raw, "plugins:") && !strings.Contains(raw, "query_is_gfc_block") {
		raw = strings.Replace(raw, "plugins:", "plugins:"+plugins, 1)
	}
	if strings.Contains(raw, "  - tag: main_sequence") && !strings.Contains(raw, "query_is_gfc_block") {
		anchor := "  - tag: main_sequence\n    type: sequence\n    args:\n      exec:"
		raw = strings.Replace(raw, anchor, anchor+seq, 1)
	}
	return raw
}

func CheckConfig(path string) error {
	bin := findBinary("mosdns")
	if bin == "" {
		return fmt.Errorf("mosdns binary not found")
	}
	cmd := exec.Command("timeout", "5", bin, "start", "-c", path)
	out, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	s := strings.TrimSpace(string(out))
	if strings.Contains(s, "124") {
		return nil
	}
	if strings.Contains(s, "not defined") || strings.Contains(s, "failed to init") {
		return fmt.Errorf("%s", s)
	}
	return fmt.Errorf("%s", s)
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
