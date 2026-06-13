package metrics

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

func Collect(cfg *config.Config, controlPlaneURL string, reachable bool) map[string]any {
	hostname, _ := os.Hostname()
	m := map[string]any{
		"ts":                  time.Now().UTC().Format(time.RFC3339),
		"hostname":            hostname,
		"agent_version":       config.Version,
		"control_plane_url":   controlPlaneURL,
		"control_plane_reachable": reachable,
		"go_os":               runtime.GOOS,
		"go_arch":             runtime.GOARCH,
		"proxy_mode":          cfg.ProxyMode,
	}
	if addrs, err := net.InterfaceAddrs(); err == nil {
		var ips []string
		for _, a := range addrs {
			if ipnet, ok := a.(*net.IPNet); ok && ipnet.IP.To4() != nil {
				ips = append(ips, ipnet.IP.String())
			}
		}
		m["ips"] = ips
	}
	return m
}

func WriteStatus(path string, metrics map[string]any, device map[string]any) error {
	data := map[string]any{"metrics": metrics, "device": device, "updated_at": time.Now().UTC().Format(time.RFC3339)}
	raw, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, raw, 0o644)
}

func MACAddress() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, iface := range ifaces {
		if len(iface.HardwareAddr) == 6 && iface.Flags&net.FlagLoopback == 0 {
			return iface.HardwareAddr.String()
		}
	}
	return ""
}

func DeviceIDFromMAC(mac string) string {
	if mac == "" {
		return ""
	}
	out := ""
	for _, c := range mac {
		if c != ':' && c != '-' {
			if c >= 'a' && c <= 'f' {
				out += string(c - 32)
			} else {
				out += string(c)
			}
		}
	}
	return out
}
