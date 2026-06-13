package network

import (
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

type Manager struct {
	cfg *config.Config
}

func New(cfg *config.Config) *Manager {
	return &Manager{cfg: cfg}
}

func (m *Manager) Status() map[string]any {
	wan := m.cfg.WanIface
	lan := m.cfg.LanIface
	if roles := m.loadRoles(); roles != nil {
		if v, ok := roles["wan"].(string); ok && v != "" {
			wan = v
		}
		if v, ok := roles["lan"].(string); ok && v != "" {
			lan = v
		}
	}
	return map[string]any{
		"wan":         wan,
		"lan":         lan,
		"interfaces":  ListInterfaces(),
		"lanAddress":  m.cfg.LanAddress,
		"lanNetwork":  m.cfg.LanCIDR,
		"gateway":     m.cfg.LanAddress,
		"dhcp":        map[string]any{"enabled": lan != "", "interface": lan},
		"bridge":      m.loadBridge(),
	}
}

func (m *Manager) loadRoles() map[string]any {
	path := filepath.Join(m.cfg.Paths.Etc, "network-roles.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var roles map[string]any
	if json.Unmarshal(data, &roles) != nil {
		return nil
	}
	return roles
}

func (m *Manager) LoadBridge() map[string]any {
	return m.loadBridge()
}

func (m *Manager) loadBridge() map[string]any {
	path := filepath.Join(m.cfg.Paths.Etc, "network-bridge.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return defaultBridge(m.cfg)
	}
	var cfg map[string]any
	if json.Unmarshal(data, &cfg) != nil {
		return defaultBridge(m.cfg)
	}
	return cfg
}

func defaultBridge(cfg *config.Config) map[string]any {
	ifaces := ListInterfaces()
	wan := ""
	if len(ifaces) > 0 {
		wan = ifaces[0]
	}
	return map[string]any{
		"mode": "bridge", "bridgeName": "bridge_lan", "wan": wan,
		"lanAddress": cfg.LanAddress, "dhcpStart": "192.168.68.100", "dhcpEnd": "192.168.68.250",
	}
}

func ListInterfaces() []string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var names []string
	for _, iface := range ifaces {
		if iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		n := iface.Name
		if strings.HasPrefix(n, "docker") || strings.HasPrefix(n, "veth") || strings.HasPrefix(n, "gfctun") {
			continue
		}
		names = append(names, n)
	}
	return names
}

func (m *Manager) ApplyBridge(body map[string]any) (map[string]any, error) {
	cfg := m.loadBridge()
	for k, v := range body {
		cfg[k] = v
	}
	path := filepath.Join(m.cfg.Paths.Etc, "network-bridge.json")
	raw, _ := json.MarshalIndent(cfg, "", "  ")
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		return nil, err
	}
	script := filepath.Join(m.cfg.Paths.Root, "deploy", "apply-network.sh")
	if _, err := os.Stat(script); err == nil {
		cmd := exec.Command("bash", script)
		out, err := cmd.CombinedOutput()
		return map[string]any{"config": cfg, "output": string(out), "ok": err == nil}, err
	}
	return map[string]any{"config": cfg, "message": "saved, run deploy/apply-network.sh on device"}, nil
}
