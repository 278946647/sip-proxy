package platform

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

type Kind string

const (
	KindLinux   Kind = "linux"
	KindOpenWrt Kind = "openwrt"
)

func Detect() Kind {
	if forced := strings.ToLower(strings.TrimSpace(os.Getenv("GFC_PLATFORM"))); forced != "" {
		if forced == "openwrt" || forced == "immortalwrt" {
			return KindOpenWrt
		}
	}
	if fileContains("/etc/openwrt_release", "DISTRIB_ID") {
		return KindOpenWrt
	}
	if fileContains("/etc/os-release", "immortalwrt") || fileContains("/etc/os-release", "openwrt") {
		return KindOpenWrt
	}
	return KindLinux
}

func IsOpenWrt() bool {
	return Detect() == KindOpenWrt
}

func RestartLogical(name string) (bool, string) {
	service, ok := LogicalService(name)
	if !ok {
		return false, "unknown service"
	}
	return Restart(service)
}

func Restart(service string) (bool, string) {
	if IsOpenWrt() {
		init := filepath.Join("/etc/init.d", trimServiceSuffix(service))
		if _, err := os.Stat(init); err != nil {
			return false, trimServiceSuffix(service) + ": init script not found"
		}
		out, err := exec.Command(init, "restart").CombinedOutput()
		if err != nil {
			return false, strings.TrimSpace(string(out))
		}
		return true, trimServiceSuffix(service) + ": restarted"
	}
	if _, err := os.Stat("/bin/systemctl"); err != nil {
		return false, service + ": no systemd"
	}
	out, err := exec.Command("systemctl", "restart", service).CombinedOutput()
	if err != nil {
		return false, strings.TrimSpace(string(out))
	}
	return true, service + ": restarted"
}

func ServiceStatus() map[string]any {
	units := map[string]string{
		"agent":    config.ServiceAgent,
		"sing-box": config.ServiceSingbox,
		"routing":  config.ServiceRouting,
		"unbound":  config.ServiceUnbound,
		"web":      config.ServiceWeb,
		"network":  config.ServiceNetwork,
	}
	result := map[string]any{}
	for name, unit := range units {
		active, sub := activeState(unit)
		result[name] = map[string]any{"unit": unit, "active": active, "sub": sub, "platform": Detect()}
	}
	return result
}

func LogicalService(name string) (string, bool) {
	units := map[string]string{
		"agent":    config.ServiceAgent,
		"sing-box": config.ServiceSingbox,
		"routing":  config.ServiceRouting,
		"unbound":  config.ServiceUnbound,
		"api":      config.ServiceWeb,
		"web":      config.ServiceWeb,
		"dnsmasq":  config.ServiceDnsmasq,
		"network":  config.ServiceNetwork,
	}
	unit, ok := units[name]
	if !ok {
		return "", false
	}
	return unit, true
}

func activeState(service string) (string, string) {
	if IsOpenWrt() {
		name := trimServiceSuffix(service)
		init := filepath.Join("/etc/init.d", name)
		if _, err := os.Stat(init); err != nil {
			return "missing", "no init script"
		}
		out, _ := exec.Command(init, "running").CombinedOutput()
		if strings.TrimSpace(string(out)) == "" {
			if err := exec.Command(init, "running").Run(); err == nil {
				return "active", "running"
			}
		}
		if err := exec.Command(init, "running").Run(); err == nil {
			return "active", "running"
		}
		return "inactive", "stopped"
	}
	cmd := exec.Command("systemctl", "is-active", service)
	out, _ := cmd.Output()
	active := strings.TrimSpace(string(out))
	cmd2 := exec.Command("systemctl", "show", service, "--property=SubState", "--value")
	out2, _ := cmd2.Output()
	return active, strings.TrimSpace(string(out2))
}

func trimServiceSuffix(service string) string {
	service = strings.TrimSpace(service)
	service = strings.TrimSuffix(service, ".service")
	switch service {
	case "gfc-web":
		return "gfc-api"
	case "gfc-network":
		return "network"
	case "gfc-routing":
		return "gfc-routing"
	case "gfc-sing-box":
		return "gfc-sing-box"
	case "gfc-unbound":
		return "gfc-unbound"
	case "gfc-mosdns":
		// Legacy unit name; DNS is unbound under GFC config.
		if IsOpenWrt() {
			return "gfc-unbound"
		}
		return "gfc-unbound"
	default:
		return service
	}
}

func fileContains(path, needle string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	return strings.Contains(strings.ToLower(string(data)), strings.ToLower(needle))
}
