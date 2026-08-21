package proxymode

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

const (
	fileProxyMode      = "proxy-mode.json"
	fileCustomerHosts  = "customer-hosts.json"
	filePending        = "proxy-mode-pending.json"
	fileWAN            = "network-wan.json"
)

type CommittedState struct {
	Mode      string `json:"mode"`
	Confirmed bool   `json:"confirmed"`
	UpdatedAt string `json:"updated_at,omitempty"`
}

type HostsFile struct {
	Hosts []string `json:"hosts"`
}

type PendingSwitch struct {
	Token      string         `json:"token"`
	FromMode   string         `json:"from_mode"`
	ToMode     string         `json:"to_mode"`
	ExpiresAt  string         `json:"expires_at"`
	WANBefore  map[string]any `json:"wan_before,omitempty"`
	WANAfter   map[string]any `json:"wan_after,omitempty"`
	HostsBefore []string      `json:"hosts_before,omitempty"`
	HostsAfter  []string      `json:"hosts_after,omitempty"`
	DataplaneNote string      `json:"dataplane_note,omitempty"`
}

func proxyModePath(cfg *config.Config) string {
	return filepath.Join(cfg.Paths.Etc, fileProxyMode)
}

func hostsPath(cfg *config.Config) string {
	return filepath.Join(cfg.Paths.Etc, fileCustomerHosts)
}

func pendingPath(cfg *config.Config) string {
	return filepath.Join(cfg.Paths.Etc, filePending)
}

func wanPath(cfg *config.Config) string {
	return filepath.Join(cfg.Paths.Etc, fileWAN)
}

// CommittedMode is the device-Web intended proxy_mode after confirm.
// Control plane should display this; dataplane still follows env until P3.
func CommittedMode(cfg *config.Config) string {
	st, err := LoadCommitted(cfg)
	if err == nil && strings.TrimSpace(st.Mode) != "" {
		return NormalizeMode(st.Mode)
	}
	return NormalizeMode(cfg.ProxyMode)
}

func LoadCommitted(cfg *config.Config) (CommittedState, error) {
	var st CommittedState
	data, err := os.ReadFile(proxyModePath(cfg))
	if err != nil {
		return CommittedState{Mode: NormalizeMode(cfg.ProxyMode)}, err
	}
	if err := json.Unmarshal(data, &st); err != nil {
		return CommittedState{Mode: NormalizeMode(cfg.ProxyMode)}, err
	}
	st.Mode = NormalizeMode(st.Mode)
	return st, nil
}

func SaveCommitted(cfg *config.Config, mode string) error {
	st := CommittedState{
		Mode:      NormalizeMode(mode),
		Confirmed: true,
		UpdatedAt: time.Now().UTC().Format(time.RFC3339),
	}
	return writeJSON(proxyModePath(cfg), st)
}

func LoadHosts(cfg *config.Config) []string {
	data, err := os.ReadFile(hostsPath(cfg))
	if err != nil {
		return nil
	}
	var f HostsFile
	if json.Unmarshal(data, &f) != nil {
		return nil
	}
	hosts, err := NormalizeHosts(f.Hosts)
	if err != nil {
		return nil
	}
	return hosts
}

func SaveHosts(cfg *config.Config, hosts []string) error {
	normalized, err := NormalizeHosts(hosts)
	if err != nil {
		return err
	}
	return writeJSON(hostsPath(cfg), HostsFile{Hosts: normalized})
}

func LoadPending(cfg *config.Config) (*PendingSwitch, error) {
	data, err := os.ReadFile(pendingPath(cfg))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var p PendingSwitch
	if err := json.Unmarshal(data, &p); err != nil {
		return nil, err
	}
	if strings.TrimSpace(p.Token) == "" {
		return nil, nil
	}
	return &p, nil
}

func SavePending(cfg *config.Config, p *PendingSwitch) error {
	return writeJSON(pendingPath(cfg), p)
}

func ClearPending(cfg *config.Config) error {
	err := os.Remove(pendingPath(cfg))
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func PendingExpired(p *PendingSwitch, now time.Time) bool {
	if p == nil {
		return true
	}
	exp, err := time.Parse(time.RFC3339, p.ExpiresAt)
	if err != nil {
		return true
	}
	return !now.Before(exp)
}

func SecondsLeft(p *PendingSwitch, now time.Time) int {
	if p == nil {
		return 0
	}
	exp, err := time.Parse(time.RFC3339, p.ExpiresAt)
	if err != nil {
		return 0
	}
	d := int(exp.Sub(now).Seconds())
	if d < 0 {
		return 0
	}
	return d
}

func writeJSON(path string, v any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, raw, 0o600)
}
