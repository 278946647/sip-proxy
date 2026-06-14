package reversessh

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
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
	_ = exec.Command("systemctl", "stop", "gfc-reverse-ssh.service").Run()
	_ = exec.Command("systemctl", "disable", "gfc-reverse-ssh.service").Run()
	return true, "reverse ssh disabled"
}

func (m *Manager) Status() map[string]any {
	active := "unknown"
	if _, err := os.Stat("/bin/systemctl"); err == nil {
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

func (m *Manager) buildScript(host, user string, port int, identity string) string {
	return fmt.Sprintf(`[Unit]
Description=GFC Reverse SSH Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Environment=AUTOSSH_GATETIME=0
ExecStart=/usr/bin/autossh -M 0 -N -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -i %s -R %d:127.0.0.1:22 %s@%s
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
`, identity, port, user, host)
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
