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
		"cn":                   filepath.Join(m.cfg.Paths.UnboundConfD, "cn.unbound.conf"),
		SnippetBlock:           filepath.Join(base, "local.d", "gfc-block.conf"),
		SnippetStatic:          filepath.Join(base, "local.d", "gfc-static.conf"),
		SnippetDomesticForward: filepath.Join(m.cfg.Paths.UnboundConfD, "gfc-domestic-forward.conf"),
		"main":                 m.cfg.Paths.UnboundConfig,
	}
}

func (m *Manager) listPath(kind string) string {
	conf := m.paths()[kind]
	dir := filepath.Dir(conf)
	switch kind {
	case SnippetBlock:
		return filepath.Join(dir, "gfc-block.list")
	case SnippetStatic:
		return filepath.Join(dir, "gfc-static.list")
	case SnippetDomesticForward:
		return filepath.Join(dir, "gfc-domestic-forward.list")
	default:
		return conf + ".list"
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
		list := m.listPath(kind)
		if _, err := os.Stat(list); err != nil {
			if err := os.WriteFile(list, []byte(dslHeader(kind)), 0o644); err != nil {
				return err
			}
		}
	}
	return nil
}

func defaultBlockConf() string {
	conf, _ := GenerateConf(SnippetBlock, nil)
	return conf
}

func defaultStaticConf() string {
	conf, _ := GenerateConf(SnippetStatic, nil)
	return conf
}

func defaultDomesticForwardConf() string {
	conf, _ := GenerateConf(SnippetDomesticForward, nil)
	return conf
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
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasPrefix(name, "cn.unbound.") &&
			!strings.HasPrefix(name, "gfc-block.") &&
			!strings.HasPrefix(name, "gfc-static.") &&
			!strings.HasPrefix(name, "gfc-domestic-forward.") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, map[string]any{
			"name":    name,
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
	m.InvalidateCNIndex()
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
	m.InvalidateCNIndex()
	return m.validateMain()
}

// GetSnippet returns operator DSL (prefer .list; else reverse-parse conf).
func (m *Manager) GetSnippet(kind string) (string, error) {
	if _, ok := m.paths()[kind]; !ok {
		return "", os.ErrInvalid
	}
	_ = m.EnsureTree()
	listPath := m.listPath(kind)
	if data, err := os.ReadFile(listPath); err == nil && len(strings.TrimSpace(string(data))) > 0 {
		// If list is only header, still try enrich from conf once
		entries, perr := ParseDSL(kind, string(data))
		if perr == nil && len(entries) > 0 {
			return FormatDSL(kind, sortEntries(entries)), nil
		}
		if perr == nil && len(entries) == 0 {
			conf, _ := m.GetSnippetConf(kind)
			extracted := ExtractEntriesFromConf(kind, conf)
			if len(extracted) > 0 {
				return FormatDSL(kind, sortEntries(extracted)), nil
			}
			return FormatDSL(kind, nil), nil
		}
	}
	conf, err := m.GetSnippetConf(kind)
	if err != nil {
		return FormatDSL(kind, nil), nil
	}
	return FormatDSL(kind, sortEntries(ExtractEntriesFromConf(kind, conf))), nil
}

// GetSnippetConf returns the on-disk unbound include file content.
func (m *Manager) GetSnippetConf(kind string) (string, error) {
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

// PutSnippetResult is returned to the API layer.
type PutSnippetResult struct {
	Kind      string      `json:"kind"`
	Audit     AuditResult `json:"audit"`
	Generated string      `json:"generated,omitempty"`
	Backup    string      `json:"backup,omitempty"`
}

// PutSnippet parses DSL, audits conflicts, writes .list + generated conf.
// force=true allows warn-level only; deny-level still blocked unless forceDeny.
func (m *Manager) PutSnippet(kind, content string, force bool) (*PutSnippetResult, error) {
	if _, ok := m.paths()[kind]; !ok {
		return nil, os.ErrInvalid
	}
	entries, err := ParseDSL(kind, content)
	if err != nil {
		return nil, err
	}
	entries = sortEntries(entries)
	audit := m.AuditWrite(kind, entries)
	_ = force // reserved; exact cross-list conflicts are always denied
	if audit.Denied {
		return &PutSnippetResult{Kind: kind, Audit: audit}, fmt.Errorf("conflict: %s", audit.Summary)
	}
	conf, err := GenerateConf(kind, entries)
	if err != nil {
		return nil, err
	}
	backupName, _ := m.backupSnippet(kind)
	listPath := m.listPath(kind)
	confPath := m.paths()[kind]
	if err := os.MkdirAll(filepath.Dir(confPath), 0o755); err != nil {
		return nil, err
	}
	dsl := FormatDSL(kind, entries)
	origList, _ := os.ReadFile(listPath)
	origConf, _ := os.ReadFile(confPath)
	if err := os.WriteFile(listPath+".tmp", []byte(dsl), 0o644); err != nil {
		return nil, err
	}
	if err := os.WriteFile(confPath+".tmp", []byte(conf), 0o644); err != nil {
		_ = os.Remove(listPath + ".tmp")
		return nil, err
	}
	if err := os.Rename(listPath+".tmp", listPath); err != nil {
		_ = os.Remove(confPath + ".tmp")
		return nil, err
	}
	if err := os.Rename(confPath+".tmp", confPath); err != nil {
		_ = os.WriteFile(listPath, origList, 0o644)
		return nil, err
	}
	if err := m.validateMain(); err != nil {
		_ = os.WriteFile(listPath, origList, 0o644)
		_ = os.WriteFile(confPath, origConf, 0o644)
		return nil, err
	}
	return &PutSnippetResult{
		Kind:      kind,
		Audit:     audit,
		Generated: conf,
		Backup:    backupName,
	}, nil
}

func (m *Manager) backupSnippet(kind string) (string, error) {
	if err := os.MkdirAll(m.backupDir(), 0o755); err != nil {
		return "", err
	}
	ts := time.Now().Format("20060102-150405")
	prefix := map[string]string{
		SnippetBlock:           "gfc-block",
		SnippetStatic:          "gfc-static",
		SnippetDomesticForward: "gfc-domestic-forward",
	}[kind]
	if prefix == "" {
		return "", fmt.Errorf("bad kind")
	}
	listSrc := m.listPath(kind)
	confSrc := m.paths()[kind]
	name := fmt.Sprintf("%s.%s.list", prefix, ts)
	_ = copyFile(listSrc, filepath.Join(m.backupDir(), name))
	_ = copyFile(confSrc, filepath.Join(m.backupDir(), fmt.Sprintf("%s.%s.conf", prefix, ts)))
	return name, nil
}

func sortEntries(in []Entry) []Entry {
	out := append([]Entry(nil), in...)
	sort.Slice(out, func(i, j int) bool {
		return out[i].Domain < out[j].Domain
	})
	return out
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
