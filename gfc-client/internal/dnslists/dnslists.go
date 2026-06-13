package dnslists

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

var ListNames = map[string]string{
	"block":  "block.txt",
	"china":  "china.txt",
	"global": "global.txt",
}

type Manager struct {
	dir string
}

func New(cfg *config.Config) *Manager {
	return &Manager{dir: cfg.Paths.DNSListsDir}
}

func (m *Manager) EnsureDefaults() error {
	if err := os.MkdirAll(m.dir, 0o755); err != nil {
		return err
	}
	defaults := map[string]string{
		"block.txt":  "# block list\n",
		"china.txt":  "# china override\n",
		"global.txt": "# global override\n",
	}
	for name, content := range defaults {
		p := filepath.Join(m.dir, name)
		if _, err := os.Stat(p); err != nil {
			if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
				return err
			}
		}
	}
	return nil
}

func (m *Manager) List(name string) ([]string, error) {
	filename, ok := ListNames[name]
	if !ok {
		return nil, os.ErrInvalid
	}
	return readDomains(filepath.Join(m.dir, filename))
}

func (m *Manager) Export(name string) (string, error) {
	filename, ok := ListNames[name]
	if !ok {
		return "", os.ErrInvalid
	}
	data, err := os.ReadFile(filepath.Join(m.dir, filename))
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func (m *Manager) Update(name string, domains []string, action string) (int, error) {
	filename, ok := ListNames[name]
	if !ok {
		return 0, os.ErrInvalid
	}
	path := filepath.Join(m.dir, filename)
	current, _ := readDomains(path)
	set := map[string]bool{}
	for _, d := range current {
		set[d] = true
	}
	action = strings.ToLower(action)
	switch action {
	case "replace":
		set = map[string]bool{}
		fallthrough
	case "append":
		for _, d := range domains {
			d = normalizeDomain(d)
			if d != "" {
				set[d] = true
			}
		}
	case "remove":
		for _, d := range domains {
			delete(set, normalizeDomain(d))
		}
	default:
		return 0, os.ErrInvalid
	}
	var out []string
	for d := range set {
		out = append(out, d)
	}
	if err := writeDomains(path, out); err != nil {
		return 0, err
	}
	return len(out), nil
}

func (m *Manager) Import(name, content string, replace bool) (int, error) {
	var domains []string
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		domains = append(domains, line)
	}
	action := "append"
	if replace {
		action = "replace"
	}
	return m.Update(name, domains, action)
}

func (m *Manager) Stats() map[string]any {
	result := map[string]any{"lists": map[string]any{}}
	lists := result["lists"].(map[string]any)
	for key, filename := range ListNames {
		domains, err := readDomains(filepath.Join(m.dir, filename))
		count := 0
		if err == nil {
			count = len(domains)
		}
		lists[key] = map[string]any{"count": count, "file": filepath.Join(m.dir, filename)}
	}
	return result
}

func readDomains(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		out = append(out, normalizeDomain(line))
	}
	return out, sc.Err()
}

func writeDomains(path string, domains []string) error {
	var b strings.Builder
	for _, d := range domains {
		b.WriteString(d)
		b.WriteByte('\n')
	}
	return os.WriteFile(path, []byte(b.String()), 0o644)
}

func normalizeDomain(d string) string {
	d = strings.TrimSpace(strings.ToLower(d))
	d = strings.TrimPrefix(d, ".")
	return d
}
