package rules

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

type Spec struct {
	Tag      string
	Filename string
	Remote   string
}

var Specs = []Spec{
	{"geosite-cn", "geosite-cn.srs", "geosite/cn.srs"},
	{"geoip-cn", "geoip-cn.srs", "geoip/cn.srs"},
	{"geosite-geolocation-!cn", "geosite-geolocation-not-cn.srs", "geosite/geolocation-!cn.srs"},
}

const metaBase = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo"

type Manager struct {
	cfg *config.Config
}

func New(cfg *config.Config) *Manager {
	return &Manager{cfg: cfg}
}

func (m *Manager) Available() bool {
	for _, s := range Specs {
		if _, err := os.Stat(filepath.Join(m.cfg.Paths.RulesDir, s.Filename)); err != nil {
			return false
		}
	}
	return true
}

func (m *Manager) Entries() []map[string]any {
	var entries []map[string]any
	for _, s := range Specs {
		p := filepath.Join(m.cfg.Paths.RulesDir, s.Filename)
		if _, err := os.Stat(p); err == nil {
			entries = append(entries, map[string]any{
				"type": "local", "tag": s.Tag, "format": "binary", "path": p,
			})
		}
	}
	return entries
}

func (m *Manager) EnsureLocal(tryDownload bool) (bool, []string) {
	var msgs []string
	_ = os.MkdirAll(m.cfg.Paths.RulesDir, 0o755)

	bundle := filepath.Join(m.cfg.Paths.Root, "share", "rules")
	if info, err := os.Stat(bundle); err == nil && info.IsDir() {
		for _, s := range Specs {
			src := filepath.Join(bundle, s.Filename)
			dst := filepath.Join(m.cfg.Paths.RulesDir, s.Filename)
			if st, err := os.Stat(src); err == nil && st.Size() > 0 {
				if dstSt, err2 := os.Stat(dst); err2 != nil || dstSt.Size() == 0 {
					if copyFile(src, dst) == nil {
						msgs = append(msgs, "copied "+s.Filename)
					}
				}
			}
		}
	}

	if m.Available() {
		return true, msgs
	}
	if !tryDownload {
		return false, append(msgs, "missing rule files")
	}
	for _, s := range Specs {
		dst := filepath.Join(m.cfg.Paths.RulesDir, s.Filename)
		if _, err := os.Stat(dst); err == nil {
			continue
		}
		url := metaBase + "/" + s.Remote
		if err := downloadFile(url, dst); err != nil {
			msgs = append(msgs, fmt.Sprintf("%s: %v", s.Filename, err))
		} else {
			msgs = append(msgs, "downloaded "+s.Filename)
		}
	}
	return m.Available(), msgs
}

func (m *Manager) Update() map[string]any {
	ok, msgs := m.EnsureLocal(false)
	result := map[string]any{"ok": ok, "messages": msgs, "updated": []string{}, "errors": []string{}}
	if !ok {
		ok2, msgs2 := m.EnsureLocal(true)
		result["ok"] = ok2
		result["messages"] = append(msgs, msgs2...)
	}
	var updated, errors []string
	client := &http.Client{Timeout: 180 * time.Second}
	for _, s := range Specs {
		url := metaBase + "/" + s.Remote
		dst := filepath.Join(m.cfg.Paths.RulesDir, s.Filename)
		req, _ := http.NewRequest("GET", url, nil)
		resp, err := client.Do(req)
		if err != nil {
			errors = append(errors, s.Filename+": "+err.Error())
			continue
		}
		data, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if len(data) < 64 {
			errors = append(errors, s.Filename+": too small")
			continue
		}
		if old, err := os.ReadFile(dst); err == nil && string(old) == string(data) {
			continue
		}
		if err := os.WriteFile(dst, data, 0o644); err != nil {
			errors = append(errors, s.Filename+": "+err.Error())
		} else {
			updated = append(updated, s.Filename)
		}
	}
	result["updated"] = updated
	result["errors"] = errors
	result["ok"] = m.Available()
	return result
}

func (m *Manager) List() []map[string]any {
	var list []map[string]any
	for _, s := range Specs {
		p := filepath.Join(m.cfg.Paths.RulesDir, s.Filename)
		item := map[string]any{"tag": s.Tag, "filename": s.Filename, "path": p}
		if st, err := os.Stat(p); err == nil {
			item["size"] = st.Size()
			item["updated_at"] = st.ModTime().UTC().Format(time.RFC3339)
		}
		list = append(list, item)
	}
	return list
}

func downloadFile(url, dst string) error {
	client := &http.Client{Timeout: 180 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if len(data) < 64 {
		return fmt.Errorf("file too small")
	}
	return os.WriteFile(dst, data, 0o644)
}

func copyFile(src, dst string) error {
	in, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, in, 0o644)
}
