package network

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/platform"
)

const openWrtNetworkConfig = "/etc/config/network"

func (m *Manager) snapshotOpenWrtNetwork() (string, error) {
	if !platform.IsOpenWrt() {
		return "", nil
	}
	data, err := os.ReadFile(openWrtNetworkConfig)
	if err != nil {
		return "", err
	}
	id := time.Now().UTC().Format("20060102-150405")
	dir := filepath.Join(m.cfg.Paths.BackupsDir, "network-"+id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	dst := filepath.Join(dir, "network")
	if err := os.WriteFile(dst, data, 0o600); err != nil {
		return "", err
	}
	_ = pruneNetworkSnapshots(m.cfg.Paths.BackupsDir, 10)
	return id, nil
}

func (m *Manager) RollbackNetwork() (map[string]any, error) {
	if platform.IsOpenWrt() {
		return m.rollbackOpenWrtNetwork()
	}
	return map[string]any{
		"ok":      false,
		"message": "network rollback is only supported on ImmortalWrt/OpenWrt",
	}, nil
}

func (m *Manager) rollbackOpenWrtNetwork() (map[string]any, error) {
	id, path, err := latestNetworkSnapshot(m.cfg.Paths.BackupsDir)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(openWrtNetworkConfig, data, 0o600); err != nil {
		return nil, err
	}
	for _, pkg := range []string{"network", "dhcp"} {
		if _, err := uci("commit", pkg); err != nil {
			return nil, err
		}
	}
	reload := []string{}
	for _, svc := range []string{"network", "dnsmasq"} {
		out, err := initd(svc, "restart")
		if err != nil {
			reload = append(reload, svc+": "+strings.TrimSpace(out))
			continue
		}
		reload = append(reload, svc+": restarted")
	}
	if err := disableOpenWrtFW4(); err == nil {
		reload = append(reload, "firewall: stopped+disabled (GFC nft)")
	}
	return map[string]any{
		"ok":       true,
		"backup":   id,
		"reload":   reload,
		"platform": platform.Detect(),
	}, nil
}

func latestNetworkSnapshot(backupsDir string) (string, string, error) {
	entries, err := os.ReadDir(backupsDir)
	if err != nil {
		return "", "", err
	}
	var ids []string
	for _, ent := range entries {
		if !ent.IsDir() || !strings.HasPrefix(ent.Name(), "network-") {
			continue
		}
		if _, err := os.Stat(filepath.Join(backupsDir, ent.Name(), "network")); err != nil {
			continue
		}
		ids = append(ids, ent.Name())
	}
	if len(ids) == 0 {
		return "", "", fmt.Errorf("no network backup found under %s", backupsDir)
	}
	sort.Strings(ids)
	id := ids[len(ids)-1]
	return id, filepath.Join(backupsDir, id, "network"), nil
}

func pruneNetworkSnapshots(backupsDir string, keep int) error {
	if keep <= 0 {
		return nil
	}
	entries, err := os.ReadDir(backupsDir)
	if err != nil {
		return err
	}
	var ids []string
	for _, ent := range entries {
		if ent.IsDir() && strings.HasPrefix(ent.Name(), "network-") {
			ids = append(ids, ent.Name())
		}
	}
	sort.Strings(ids)
	for len(ids) > keep {
		_ = os.RemoveAll(filepath.Join(backupsDir, ids[0]))
		ids = ids[1:]
	}
	return nil
}

func (m *Manager) ensureWANConfigFromUCI() (bool, error) {
	path := filepath.Join(m.cfg.Paths.Etc, "network-wan.json")
	if _, err := os.Stat(path); err == nil {
		return false, nil
	}
	cfg, err := m.readWANFromUCI()
	if err != nil {
		return false, err
	}
	raw, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return false, err
	}
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		return false, err
	}
	return true, nil
}

func (m *Manager) readWANFromUCI() (map[string]any, error) {
	out, err := uci("show", "network.wan")
	if err != nil || strings.TrimSpace(out) == "" {
		return nil, fmt.Errorf("network.wan not configured in uci")
	}
	values := parseUCIShow(out)
	device := values["device"]
	if device == "" {
		device = values["ifname"]
	}
	proto := strings.ToLower(values["proto"])
	if proto == "" {
		proto = "dhcp"
	}
	cfg := map[string]any{
		"enabled":   true,
		"interface": device,
		"mode":      proto,
		"mtu":       intValue(values["mtu"], 1500),
	}
	if proto == "static" {
		cfg["address"] = values["ipaddr"]
		cfg["netmask"] = values["netmask"]
		cfg["gateway"] = values["gateway"]
		if dns := strings.Fields(values["dns"]); len(dns) > 0 {
			cfg["dns1"] = dns[0]
			if len(dns) > 1 {
				cfg["dns2"] = dns[1]
			}
		}
	}
	if proto == "pppoe" {
		cfg["username"] = values["username"]
		cfg["password"] = values["password"]
	}
	if strings.TrimSpace(device) == "" {
		return nil, fmt.Errorf("network.wan device missing in uci")
	}
	return cfg, nil
}

func parseUCIShow(out string) map[string]string {
	values := map[string]string{}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || !strings.Contains(line, "=") {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimPrefix(key, "network.wan.")
		val = strings.Trim(val, "'")
		if existing, ok := values[key]; ok && key == "dns" {
			values[key] = existing + " " + val
		} else {
			values[key] = val
		}
	}
	return values
}
