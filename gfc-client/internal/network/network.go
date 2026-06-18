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
		"wanConfig":   m.LoadWAN(),
		"dhcpConfig":  m.LoadDHCP(),
		"routes":      m.LoadRoutes(),
		"vlan":        m.LoadVLAN(),
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

func (m *Manager) LoadWAN() map[string]any {
	return m.loadConfig("network-wan.json", defaultWAN(m.cfg))
}

func (m *Manager) LoadDHCP() map[string]any {
	return m.loadConfig("network-dhcp.json", defaultDHCP(m.cfg))
}

func (m *Manager) LoadRoutes() map[string]any {
	return m.loadConfig("network-routes.json", map[string]any{"routes": []any{}})
}

func (m *Manager) LoadVLAN() map[string]any {
	return m.loadConfig("network-vlan.json", map[string]any{"vlans": []any{}})
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

func defaultWAN(cfg *config.Config) map[string]any {
	wan := cfg.WanIface
	if wan == "" {
		ifaces := ListInterfaces()
		if len(ifaces) > 0 {
			wan = ifaces[0]
		}
	}
	return map[string]any{
		"enabled": true, "interface": wan, "mode": "dhcp", "mtu": 1500,
		"address": "", "netmask": "", "gateway": "", "dns1": "", "dns2": "",
	}
}

func defaultDHCP(cfg *config.Config) map[string]any {
	return map[string]any{
		"enabled": true, "gateway": cfg.LanAddress, "start": "192.168.68.100",
		"end": "192.168.68.199", "dns": cfg.LanAddress, "leaseTime": "12h", "domain": "lan",
	}
}

func (m *Manager) loadConfig(name string, defaults map[string]any) map[string]any {
	path := filepath.Join(m.cfg.Paths.Etc, name)
	data, err := os.ReadFile(path)
	if err != nil {
		return defaults
	}
	var cfg map[string]any
	if json.Unmarshal(data, &cfg) != nil {
		return defaults
	}
	for k, v := range defaults {
		if _, ok := cfg[k]; !ok {
			cfg[k] = v
		}
	}
	return cfg
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

func (m *Manager) ApplyNetwork() (map[string]any, error) {
	script := filepath.Join(m.cfg.Paths.Root, "deploy", "apply-network.sh")
	if _, err := os.Stat(script); err != nil {
		return nil, err
	}
	cmd := exec.Command("bash", script)
	out, err := cmd.CombinedOutput()
	return map[string]any{"output": string(out), "ok": err == nil}, err
}

func (m *Manager) ApplyBridge(body map[string]any) (map[string]any, error) {
	cfg := m.loadBridge()
	for k, v := range body {
		cfg[k] = v
	}
	return m.saveNetworkConfig("network-bridge.json", cfg, true)
}

func (m *Manager) ApplyWAN(body map[string]any) (map[string]any, error) {
	cfg := m.LoadWAN()
	for k, v := range body {
		cfg[k] = v
	}
	if iface, ok := cfg["interface"].(string); ok && strings.TrimSpace(iface) != "" {
		_ = m.saveRoles(map[string]any{"wan": strings.TrimSpace(iface)})
	}
	return m.saveNetworkConfig("network-wan.json", cfg, true)
}

func (m *Manager) ApplyDHCP(body map[string]any) (map[string]any, error) {
	cfg := m.LoadDHCP()
	for k, v := range body {
		cfg[k] = v
	}
	return m.saveNetworkConfig("network-dhcp.json", cfg, true)
}

func (m *Manager) ApplyRoutes(body map[string]any) (map[string]any, error) {
	cfg := m.LoadRoutes()
	for k, v := range body {
		cfg[k] = v
	}
	return m.saveNetworkConfig("network-routes.json", cfg, true)
}

func (m *Manager) ApplyVLAN(body map[string]any) (map[string]any, error) {
	cfg := m.LoadVLAN()
	for k, v := range body {
		cfg[k] = v
	}
	return m.saveNetworkConfig("network-vlan.json", cfg, true)
}

func (m *Manager) saveRoles(update map[string]any) error {
	roles := m.loadRoles()
	if roles == nil {
		roles = map[string]any{}
	}
	for k, v := range update {
		roles[k] = v
	}
	path := filepath.Join(m.cfg.Paths.Etc, "network-roles.json")
	raw, _ := json.MarshalIndent(roles, "", "  ")
	return os.WriteFile(path, raw, 0o644)
}

func (m *Manager) saveNetworkConfig(name string, cfg map[string]any, apply bool) (map[string]any, error) {
	path := filepath.Join(m.cfg.Paths.Etc, name)
	raw, _ := json.MarshalIndent(cfg, "", "  ")
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		return nil, err
	}
	if !apply {
		return map[string]any{"config": cfg, "message": "saved"}, nil
	}
	script := filepath.Join(m.cfg.Paths.Root, "deploy", "apply-network.sh")
	if _, err := os.Stat(script); err == nil {
		cmd := exec.Command("bash", script)
		out, err := cmd.CombinedOutput()
		return map[string]any{"config": cfg, "output": string(out), "ok": err == nil}, err
	}
	return map[string]any{"config": cfg, "message": "saved, run deploy/apply-network.sh on device"}, nil
}
