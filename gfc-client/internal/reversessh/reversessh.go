package reversessh

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/platform"
)

const defaultPortBase = 6000

// Port mirrors control-plane _reverse_ssh_port(device_key).
func Port(deviceKey string, base int) int {
	if base <= 0 {
		base = defaultPortBase
	}
	offset := 0
	if len(deviceKey) >= 4 {
		if v, err := strconv.ParseInt(deviceKey[:4], 16, 64); err == nil {
			offset = int(v % 1000)
		}
	}
	return base + offset
}

type Manager struct {
	cfg *config.Config
}

func New(cfg *config.Config) *Manager {
	return &Manager{cfg: cfg}
}

func (m *Manager) Enabled() bool {
	return strings.TrimSpace(os.Getenv("GFC_REVERSE_SSH_HOST")) != ""
}

func (m *Manager) Sync(deviceKey string) (bool, string) {
	host := strings.TrimSpace(os.Getenv("GFC_REVERSE_SSH_HOST"))
	if host == "" || deviceKey == "" {
		return m.stopUnit()
	}
	user := env("GFC_REVERSE_SSH_USER", "root")
	base := envInt("GFC_SSH_PORT_BASE", defaultPortBase)
	port := Port(deviceKey, base)
	if platform.IsOpenWrt() {
		return m.syncOpenWrt(host, user, port)
	}
	unitPath := "/etc/systemd/system/gfc-reverse-ssh.service"
	identity := filepath.Join(m.cfg.Paths.Etc, "reverse_ssh_id")
	script := m.buildScript(host, user, port, identity)
	if err := os.WriteFile(unitPath, []byte(script), 0o644); err != nil {
		return false, err.Error()
	}
	if _, err := exec.LookPath("autossh"); err != nil {
		return false, "autossh not installed"
	}
	_ = exec.Command("systemctl", "daemon-reload").Run()
	_ = exec.Command("systemctl", "enable", "gfc-reverse-ssh.service").Run()
	cmd := exec.Command("systemctl", "restart", "gfc-reverse-ssh.service")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return false, strings.TrimSpace(string(out))
	}
	return true, fmt.Sprintf("reverse ssh :%d -> %s", port, host)
}

func (m *Manager) stopUnit() (bool, string) {
	if platform.IsOpenWrt() {
		_ = exec.Command("/etc/init.d/gfc-reverse-ssh", "stop").Run()
		_ = exec.Command("/etc/init.d/gfc-reverse-ssh", "disable").Run()
		return true, "reverse ssh disabled"
	}
	_ = exec.Command("systemctl", "stop", "gfc-reverse-ssh.service").Run()
	_ = exec.Command("systemctl", "disable", "gfc-reverse-ssh.service").Run()
	return true, "reverse ssh disabled"
}

func (m *Manager) Status() map[string]any {
	active := "unknown"
	if platform.IsOpenWrt() {
		if err := exec.Command("/etc/init.d/gfc-reverse-ssh", "running").Run(); err == nil {
			active = "active"
		} else {
			active = "inactive"
		}
	} else if _, err := os.Stat("/bin/systemctl"); err == nil {
		out, _ := exec.Command("systemctl", "is-active", "gfc-reverse-ssh.service").Output()
		active = strings.TrimSpace(string(out))
	}
	return map[string]any{
		"enabled":  m.Enabled(),
		"active":   active,
		"host":     os.Getenv("GFC_REVERSE_SSH_HOST"),
		"port_base": envInt("GFC_SSH_PORT_BASE", defaultPortBase),
	}
}

func (m *Manager) syncOpenWrt(host, user string, port int) (bool, string) {
	if _, err := exec.LookPath("autossh"); err != nil {
		return false, "autossh not installed"
	}
	identity := filepath.Join(m.cfg.Paths.Etc, "reverse_ssh_id")
	script := m.buildOpenWrtInit(host, user, port, identity)
	path := "/etc/init.d/gfc-reverse-ssh"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		return false, err.Error()
	}
	_ = exec.Command(path, "enable").Run()
	out, err := exec.Command(path, "restart").CombinedOutput()
	if err != nil {
		return false, strings.TrimSpace(string(out))
	}
	return true, fmt.Sprintf("reverse ssh :%d -> %s", port, host)
}

func (m *Manager) buildScript(host, user string, port int, identity string) string {
	remotePort := envInt("GFC_SSH_PORT", 212)
	return fmt.Sprintf(`[Unit]
Description=GFC Reverse SSH Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Environment=AUTOSSH_GATETIME=0
ExecStart=/usr/bin/autossh -M 0 -N -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -i %s -R %d:127.0.0.1:%d %s@%s
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
`, identity, port, remotePort, user, host)
}

func (m *Manager) buildOpenWrtInit(host, user string, port int, identity string) string {
	remotePort := envInt("GFC_SSH_PORT", 212)
	return fmt.Sprintf(`#!/bin/sh /etc/rc.common
START=93
STOP=17
USE_PROCD=1

start_service() {
	procd_open_instance
	procd_set_param command /usr/bin/autossh -M 0 -N -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -i %s -R %d:127.0.0.1:%d %s@%s
	procd_set_param env AUTOSSH_GATETIME=0
	procd_set_param respawn 5 10 0
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}
`, identity, port, remotePort, user, host)
}

func env(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}
