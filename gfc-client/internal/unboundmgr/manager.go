package unboundmgr

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/render/unbound"
)

const (
	SnippetBlock           = "block"
	SnippetStatic          = "static"
	SnippetDomesticForward = "domestic-forward"
)

type Manager struct {
	cfg *config.Config
}

func New(cfg *config.Config) *Manager {
	return &Manager{cfg: cfg}
}

func (m *Manager) paths() map[string]string {
	base := filepath.Dir(m.cfg.Paths.UnboundConfig)
	return map[string]string{
		"cn":               filepath.Join(m.cfg.Paths.UnboundConfD, "cn.unbound.conf"),
		SnippetBlock:       filepath.Join(base, "local.d", "gfc-block.conf"),
		SnippetStatic:      filepath.Join(base, "local.d", "gfc-static.conf"),
		SnippetDomesticForward: filepath.Join(m.cfg.Paths.UnboundConfD, "gfc-domestic-forward.conf"),
		"main":             m.cfg.Paths.UnboundConfig,
	}
}

func (m *Manager) backupDir() string {
	return filepath.Join(m.cfg.Paths.Lib, "dns-backups")
}

func (m *Manager) EnsureTree() error {
	p := m.paths()
	if err := os.MkdirAll(filepath.Dir(p[SnippetBlock]), 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(m.cfg.Paths.UnboundConfD, 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(m.backupDir(), 0o755); err != nil {
		return err
	}
	defaults := map[string]string{
		SnippetBlock:           defaultBlockConf(),
		SnippetStatic:          defaultStaticConf(),
		SnippetDomesticForward: defaultDomesticForwardConf(),
	}
	for kind, content := range defaults {
		path := p[kind]
		if _, err := os.Stat(path); err != nil {
			if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
				return err
			}
		}
	}
	return nil
}

func defaultBlockConf() string {
	return `# GFC — 域名阻断（local-zone static）
# 每行一条：domain example.com
# 保存后自动 unbound-checkconf
server:
    # local-zone: "ads.example.com." static
    # local-data: "ads.example.com. 3600 IN A 0.0.0.0"
`
}

func defaultStaticConf() string {
	return `# GFC — 指定域名静态解析
# 示例：
# server:
#     local-zone: "mmo.example.com." static
#     local-data: "mmo.example.com. 3600 IN A 203.0.113.10"
`
}

func defaultDomesticForwardConf() string {
	return `# GFC — 指定域名走国内 DNS（独立于 cn.unbound.conf）
# 示例：
# forward-zone:
#     name: "special.example.com"
#     forward-addr: 223.5.5.5
#     forward-addr: 119.29.29.29
`
}

func (m *Manager) Status() map[string]any {
	p := m.paths()
	check := m.CheckConfig()
	st := map[string]any{
		"paths":   p,
		"check":   check,
		"backups": m.ListBackups(),
	}
	for k, path := range p {
		if k == "main" {
			continue
		}
		if info, err := os.Stat(path); err == nil {
			st[k+"_bytes"] = info.Size()
			st[k+"_mtime"] = info.ModTime().Format(time.RFC3339)
		}
	}
	return st
}

func (m *Manager) CheckConfig() map[string]any {
	_ = m.EnsureTree()
	err := unbound.CheckConfig(m.paths()["main"])
	if err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	return map[string]any{"ok": true}
}

func (m *Manager) ListBackups() []map[string]any {
	dir := m.backupDir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []map[string]any
	for _, e := range entries {
		if e.IsDir() || !strings.HasPrefix(e.Name(), "cn.unbound.") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, map[string]any{
			"name":    e.Name(),
			"size":    info.Size(),
			"updated": info.ModTime().Format(time.RFC3339),
		})
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i]["name"].(string) > out[j]["name"].(string)
	})
	return out
}

func (m *Manager) BackupCN() (string, error) {
	src := m.paths()["cn"]
	if _, err := os.Stat(src); err != nil {
		return "", fmt.Errorf("cn list missing: %s", src)
	}
	if err := os.MkdirAll(m.backupDir(), 0o755); err != nil {
		return "", err
	}
	name := fmt.Sprintf("cn.unbound.%s.conf", time.Now().Format("20060102-150405"))
	dst := filepath.Join(m.backupDir(), name)
	if err := copyFile(src, dst); err != nil {
		return "", err
	}
	return name, nil
}

func (m *Manager) RestoreCN(name string) error {
	name = filepath.Base(strings.TrimSpace(name))
	if name == "" || strings.Contains(name, "..") {
		return fmt.Errorf("invalid backup name")
	}
	src := filepath.Join(m.backupDir(), name)
	if _, err := os.Stat(src); err != nil {
		return err
	}
	if _, err := m.BackupCN(); err != nil {
		// best-effort snapshot before restore
	}
	dst := m.paths()["cn"]
	if err := copyFile(src, dst); err != nil {
		return err
	}
	return m.validateMain()
}

func (m *Manager) SyncCNFromBundle() error {
	bundle := filepath.Join(m.cfg.Paths.Root, "share", "unbound", "conf.d", "cn.unbound.conf")
	if _, err := os.Stat(bundle); err != nil {
		return fmt.Errorf("bundle cn list missing: %s", bundle)
	}
	if _, err := m.BackupCN(); err != nil {
		// allow first sync without existing cn file
	}
	dst := m.paths()["cn"]
	if err := copyFile(bundle, dst); err != nil {
		return err
	}
	return m.validateMain()
}

func (m *Manager) GetSnippet(kind string) (string, error) {
	path, ok := m.paths()[kind]
	if !ok {
		return "", os.ErrInvalid
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			_ = m.EnsureTree()
			data, err = os.ReadFile(path)
		}
		if err != nil {
			return "", err
		}
	}
	return string(data), nil
}

func (m *Manager) PutSnippet(kind, content string) error {
	path, ok := m.paths()[kind]
	if !ok {
		return os.ErrInvalid
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(path+".tmp", []byte(content), 0o644); err != nil {
		return err
	}
	// validate with temp swap
	orig, _ := os.ReadFile(path)
	if err := os.Rename(path+".tmp", path); err != nil {
		return err
	}
	if err := m.validateMain(); err != nil {
		_ = os.WriteFile(path, orig, 0o644)
		return err
	}
	return nil
}

func (m *Manager) validateMain() error {
	if err := unbound.CheckConfig(m.paths()["main"]); err != nil {
		return fmt.Errorf("unbound-checkconf: %w", err)
	}
	return nil
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
