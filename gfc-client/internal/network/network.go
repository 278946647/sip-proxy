package network

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/platform"
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
	bridgeName := "bridge_lan"
	if platform.IsOpenWrt() {
		bridgeName = "br-lan"
	}
	return map[string]any{
		"mode": "bridge", "bridgeName": bridgeName, "wan": wan,
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
	if platform.IsOpenWrt() {
		return m.applyOpenWrt()
	}
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
	if platform.IsOpenWrt() {
		result, err := m.applyOpenWrt()
		if result == nil {
			result = map[string]any{}
		}
		result["config"] = cfg
		return result, err
	}
	script := filepath.Join(m.cfg.Paths.Root, "deploy", "apply-network.sh")
	if _, err := os.Stat(script); err == nil {
		cmd := exec.Command("bash", script)
		out, err := cmd.CombinedOutput()
		return map[string]any{"config": cfg, "output": string(out), "ok": err == nil}, err
	}
	return map[string]any{"config": cfg, "message": "saved, run deploy/apply-network.sh on device"}, nil
}

func (m *Manager) applyOpenWrt() (map[string]any, error) {
	if _, err := exec.LookPath("uci"); err != nil {
		return nil, fmt.Errorf("uci not found; not an OpenWrt/ImmortalWrt runtime")
	}
	var msgs []string
	bridge := m.loadBridge()
	wan := m.LoadWAN()
	dhcp := m.LoadDHCP()
	routes := m.LoadRoutes()
	vlan := m.LoadVLAN()

	if err := m.applyOpenWrtLAN(bridge); err != nil {
		return nil, err
	}
	msgs = append(msgs, "network.lan updated")
	if err := m.applyOpenWrtWAN(wan); err != nil {
		return nil, err
	}
	msgs = append(msgs, "network.wan updated")
	if err := m.applyOpenWrtDHCP(dhcp); err != nil {
		return nil, err
	}
	msgs = append(msgs, "dhcp.lan updated")
	if err := m.applyOpenWrtRoutes(routes); err != nil {
		return nil, err
	}
	msgs = append(msgs, "static routes updated")
	if err := m.applyOpenWrtVLAN(vlan, bridge); err != nil {
		return nil, err
	}
	msgs = append(msgs, "bridge vlans updated")
	if err := m.applyOpenWrtFirewall(); err != nil {
		msgs = append(msgs, "firewall warning: "+err.Error())
	}

	for _, pkg := range []string{"network", "dhcp", "firewall"} {
		if out, err := uci("commit", pkg); err != nil {
			return map[string]any{"messages": msgs, "output": out}, err
		}
	}
	reload := []string{}
	for _, svc := range []string{"network", "dnsmasq", "firewall"} {
		out, err := initd(svc, "restart")
		if err != nil {
			reload = append(reload, svc+": "+strings.TrimSpace(out))
			continue
		}
		reload = append(reload, svc+": restarted")
	}
	_ = m.saveRoles(map[string]any{
		"wan": wanString(wan, "interface", m.cfg.WanIface),
		"lan": lanName(bridge, m.cfg),
	})
	return map[string]any{
		"ok":       true,
		"platform": platform.Detect(),
		"messages": msgs,
		"reload":   reload,
	}, nil
}

func (m *Manager) applyOpenWrtLAN(cfg map[string]any) error {
	bridgeName := strings.TrimSpace(text(cfg["bridgeName"]))
	if bridgeName == "" {
		bridgeName = "br-lan"
	}
	lanAddr := strings.TrimSpace(text(cfg["lanAddress"]))
	if lanAddr == "" {
		lanAddr = m.cfg.LanAddress
	}
	netmask := prefixToNetmask(intValue(cfg["lanPrefix"], 24))
	mode := strings.ToLower(strings.TrimSpace(text(cfg["mode"])))
	members := stringList(cfg["members"])
	if len(members) == 0 {
		if lan := strings.TrimSpace(m.cfg.LanIface); lan != "" {
			members = []string{lan}
		}
	}

	if mode == "" || mode == "bridge" {
		if _, err := uci("set", "network.gfc_lan_dev=device"); err != nil {
			return err
		}
		_, _ = uci("set", "network.gfc_lan_dev.name="+bridgeName)
		_, _ = uci("set", "network.gfc_lan_dev.type=bridge")
		if len(members) > 0 {
			_, _ = uci("set", "network.gfc_lan_dev.ports="+strings.Join(members, " "))
		}
		_, _ = uci("set", "network.lan=interface")
		_, _ = uci("set", "network.lan.device="+bridgeName)
	} else {
		lan := strings.TrimSpace(text(cfg["interface"]))
		if lan == "" {
			lan = m.cfg.LanIface
		}
		_, _ = uci("set", "network.lan=interface")
		_, _ = uci("set", "network.lan.device="+lan)
	}
	_, _ = uci("set", "network.lan.proto=static")
	_, _ = uci("set", "network.lan.ipaddr="+lanAddr)
	_, _ = uci("set", "network.lan.netmask="+netmask)
	return nil
}

func (m *Manager) applyOpenWrtWAN(cfg map[string]any) error {
	iface := strings.TrimSpace(text(cfg["interface"]))
	if iface == "" {
		iface = m.cfg.WanIface
	}
	if iface == "" {
		return nil
	}
	mode := strings.ToLower(strings.TrimSpace(text(cfg["mode"])))
	if mode == "" {
		mode = "dhcp"
	}
	_, _ = uci("set", "network.wan=interface")
	_, _ = uci("set", "network.wan.device="+iface)
	_, _ = uci("set", "network.wan.proto="+mode)
	if mtu := intValue(cfg["mtu"], 0); mtu > 0 {
		_, _ = uci("set", "network.wan.mtu="+strconv.Itoa(mtu))
	}
	if mode == "static" {
		for key, uciKey := range map[string]string{"address": "ipaddr", "netmask": "netmask", "gateway": "gateway"} {
			if val := strings.TrimSpace(text(cfg[key])); val != "" {
				_, _ = uci("set", "network.wan."+uciKey+"="+val)
			}
		}
		dns := compact([]string{text(cfg["dns1"]), text(cfg["dns2"])})
		if len(dns) > 0 {
			_, _ = uci("set", "network.wan.dns="+strings.Join(dns, " "))
		}
	}
	return nil
}

func (m *Manager) applyOpenWrtDHCP(cfg map[string]any) error {
	enabled := boolValue(cfg["enabled"], true)
	_, _ = uci("set", "dhcp.lan=dhcp")
	_, _ = uci("set", "dhcp.lan.interface=lan")
	if !enabled {
		_, _ = uci("set", "dhcp.lan.ignore=1")
		return nil
	}
	_, _ = uci("delete", "dhcp.lan.ignore")
	start, limit := dhcpRange(text(cfg["start"]), text(cfg["end"]))
	_, _ = uci("set", "dhcp.lan.start="+strconv.Itoa(start))
	_, _ = uci("set", "dhcp.lan.limit="+strconv.Itoa(limit))
	if lease := strings.TrimSpace(text(cfg["leaseTime"])); lease != "" {
		_, _ = uci("set", "dhcp.lan.leasetime="+lease)
	}
	return nil
}

func (m *Manager) applyOpenWrtRoutes(cfg map[string]any) error {
	for i := 0; i < 32; i++ {
		_, _ = uci("delete", fmt.Sprintf("network.gfc_route_%d", i))
	}
	for i, raw := range objectList(cfg["routes"]) {
		name := fmt.Sprintf("network.gfc_route_%d", i)
		_, _ = uci("set", name+"=route")
		_, _ = uci("set", name+".interface="+defaultText(raw["interface"], "wan"))
		for key, uciKey := range map[string]string{"target": "target", "netmask": "netmask", "gateway": "gateway", "metric": "metric"} {
			if val := strings.TrimSpace(text(raw[key])); val != "" {
				_, _ = uci("set", name+"."+uciKey+"="+val)
			}
		}
	}
	return nil
}

func (m *Manager) applyOpenWrtVLAN(cfg map[string]any, bridge map[string]any) error {
	for i := 0; i < 64; i++ {
		_, _ = uci("delete", fmt.Sprintf("network.gfc_vlan_%d", i))
	}
	device := defaultText(bridge["bridgeName"], "br-lan")
	for i, raw := range objectList(cfg["vlans"]) {
		id := intValue(first(raw, "id", "vlan"), 0)
		if id <= 0 {
			continue
		}
		name := fmt.Sprintf("network.gfc_vlan_%d", i)
		_, _ = uci("set", name+"=bridge-vlan")
		_, _ = uci("set", name+".device="+device)
		_, _ = uci("set", name+".vlan="+strconv.Itoa(id))
		ports := stringList(raw["ports"])
		if len(ports) > 0 {
			_, _ = uci("set", name+".ports="+strings.Join(ports, " "))
		}
	}
	return nil
}

func (m *Manager) applyOpenWrtFirewall() error {
	_, _ = uci("set", "firewall.@zone[1].masq=1")
	_, _ = uci("set", "firewall.@zone[1].mtu_fix=1")
	return nil
}

func uci(args ...string) (string, error) {
	out, err := exec.Command("uci", args...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func initd(service, action string) (string, error) {
	path := filepath.Join("/etc/init.d", service)
	out, err := exec.Command(path, action).CombinedOutput()
	return string(out), err
}

func text(v any) string {
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprint(v)
}

func defaultText(v any, def string) string {
	if s := strings.TrimSpace(text(v)); s != "" {
		return s
	}
	return def
}

func intValue(v any, def int) int {
	switch n := v.(type) {
	case int:
		return n
	case float64:
		return int(n)
	case string:
		if parsed, err := strconv.Atoi(strings.TrimSpace(n)); err == nil {
			return parsed
		}
	}
	return def
}

func boolValue(v any, def bool) bool {
	switch b := v.(type) {
	case bool:
		return b
	case string:
		switch strings.ToLower(strings.TrimSpace(b)) {
		case "1", "true", "yes", "on", "enabled":
			return true
		case "0", "false", "no", "off", "disabled":
			return false
		}
	}
	return def
}

func stringList(v any) []string {
	switch vv := v.(type) {
	case []string:
		return compact(vv)
	case []any:
		out := make([]string, 0, len(vv))
		for _, item := range vv {
			if s := strings.TrimSpace(text(item)); s != "" {
				out = append(out, s)
			}
		}
		return out
	case string:
		return strings.FieldsFunc(vv, func(r rune) bool { return r == ',' || r == ' ' || r == '\n' || r == '\t' })
	default:
		return nil
	}
}

func objectList(v any) []map[string]any {
	items, _ := v.([]any)
	out := make([]map[string]any, 0, len(items))
	for _, item := range items {
		if m, ok := item.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

func compact(in []string) []string {
	out := make([]string, 0, len(in))
	for _, s := range in {
		if s = strings.TrimSpace(s); s != "" {
			out = append(out, s)
		}
	}
	return out
}

func prefixToNetmask(prefix int) string {
	if prefix <= 0 || prefix > 32 {
		prefix = 24
	}
	mask := net.CIDRMask(prefix, 32)
	return net.IP(mask).String()
}

func dhcpRange(startIP, endIP string) (int, int) {
	start := lastOctet(startIP, 100)
	end := lastOctet(endIP, 199)
	if end < start {
		return start, 100
	}
	return start, end - start + 1
}

func lastOctet(ip string, def int) int {
	parts := strings.Split(strings.TrimSpace(ip), ".")
	if len(parts) == 0 {
		return def
	}
	n, err := strconv.Atoi(parts[len(parts)-1])
	if err != nil || n <= 0 || n > 254 {
		return def
	}
	return n
}

func wanString(m map[string]any, key, def string) string {
	if s := strings.TrimSpace(text(m[key])); s != "" {
		return s
	}
	return def
}

func lanName(m map[string]any, cfg *config.Config) string {
	if s := strings.TrimSpace(text(m["bridgeName"])); s != "" {
		return s
	}
	if s := strings.TrimSpace(cfg.LanIface); s != "" {
		return s
	}
	return "br-lan"
}

func first(m map[string]any, keys ...string) any {
	for _, key := range keys {
		if v, ok := m[key]; ok {
			return v
		}
	}
	return nil
}
