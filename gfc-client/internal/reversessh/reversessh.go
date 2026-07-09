package reversessh

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/platform"
)

const defaultPortBase = 6001

type Command struct {
	Enabled   bool
	Host      string
	Port      int
	User      string
	ExpiresAt string
	SSHPort   int
	HTTPPort  int
	Targets   []string
}

type Manager struct {
	cfg     *config.Config
	lastCmd string
}

func New(cfg *config.Config) *Manager {
	return &Manager{cfg: cfg}
}

func (m *Manager) EnsureKeypair() (string, error) {
	identity := filepath.Join(m.cfg.Paths.Etc, "reverse_ssh_id")
	pub := identity + ".pub"
	if _, err := os.Stat(identity); err == nil {
		data, err := os.ReadFile(pub)
		if err != nil {
			return "", err
		}
		return strings.TrimSpace(string(data)), nil
	}
	if _, err := exec.LookPath("ssh-keygen"); err != nil {
		return "", fmt.Errorf("ssh-keygen not installed")
	}
	_ = os.MkdirAll(filepath.Dir(identity), 0o755)
	cmd := exec.Command(
		"ssh-keygen", "-t", "ed25519", "-f", identity, "-N", "", "-C", "gfc-reverse",
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("ssh-keygen: %s", strings.TrimSpace(string(out)))
	}
	_ = os.Chmod(identity, 0o600)
	data, err := os.ReadFile(pub)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}

func ParseCommand(raw map[string]any) *Command {
	if raw == nil {
		return nil
	}
	enabled, _ := raw["enabled"].(bool)
	host, _ := raw["host"].(string)
	user, _ := raw["user"].(string)
	expires, _ := raw["expires_at"].(string)
	port := 212
	if v, ok := raw["port"].(float64); ok {
		port = int(v)
	}
	cmd := &Command{
		Enabled:   enabled,
		Host:      strings.TrimSpace(host),
		User:      strings.TrimSpace(user),
		ExpiresAt: expires,
		Port:      port,
	}
	if ports, ok := raw["ports"].(map[string]any); ok {
		cmd.SSHPort = jsonInt(ports["ssh"])
		cmd.HTTPPort = jsonInt(ports["http"])
	}
	if cmd.SSHPort <= 0 {
		cmd.SSHPort = jsonInt(raw["reverse_ssh_port"])
	}
	if cmd.HTTPPort <= 0 {
		cmd.HTTPPort = jsonInt(raw["reverse_http_port"])
	}
	if targets, ok := raw["targets"].([]any); ok {
		for _, t := range targets {
			cmd.Targets = append(cmd.Targets, fmt.Sprint(t))
		}
	}
	return cmd
}

func jsonInt(v any) int {
	switch n := v.(type) {
	case float64:
		return int(n)
	case int:
		return n
	case int64:
		return int(n)
	case json.Number:
		i, _ := n.Int64()
		return int(i)
	case string:
		i, _ := strconv.Atoi(strings.TrimSpace(n))
		return i
	default:
		return 0
	}
}

func (m *Manager) SyncCommand(cmd *Command) (bool, string) {
	if cmd == nil || !cmd.Enabled || cmd.Host == "" {
		return m.stopUnit()
	}
	if cmd.SSHPort <= 0 {
		return false, "missing reverse ssh port"
	}
	if _, err := m.EnsureKeypair(); err != nil {
		return false, err.Error()
	}
	user := cmd.User
	if user == "" {
		user = env("GFC_REVERSE_SSH_USER", "gfc-reverse")
	}
	fingerprint, _ := json.Marshal(cmd)
	next := string(fingerprint)
	if next == m.lastCmd {
		if m.isActive() {
			return true, fmt.Sprintf("reverse ssh active :%d", cmd.SSHPort)
		}
	}
	m.lastCmd = next
	if platform.IsOpenWrt() {
		return m.syncOpenWrt(cmd.Host, user, cmd.Port, cmd.SSHPort, cmd.HTTPPort, cmd.Targets)
	}
	return m.syncSystemd(cmd.Host, user, cmd.Port, cmd.SSHPort, cmd.HTTPPort, cmd.Targets)
}

func (m *Manager) isActive() bool {
	if platform.IsOpenWrt() {
		return exec.Command("/etc/init.d/gfc-reverse-ssh", "running").Run() == nil
	}
	out, _ := exec.Command("systemctl", "is-active", "gfc-reverse-ssh.service").Output()
	return strings.TrimSpace(string(out)) == "active"
}

func (m *Manager) stopUnit() (bool, string) {
	m.lastCmd = ""
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
	active := "inactive"
	if m.isActive() {
		active = "active"
	}
	return map[string]any{
		"active": active,
		"host":   os.Getenv("GFC_REVERSE_SSH_HOST"),
	}
}

func (m *Manager) syncSystemd(host, user string, sshdPort, revSSH, revHTTP int, targets []string) (bool, string) {
	unitPath := "/etc/systemd/system/gfc-reverse-ssh.service"
	identity := filepath.Join(m.cfg.Paths.Etc, "reverse_ssh_id")
	script := m.buildScript(host, user, sshdPort, revSSH, revHTTP, targets, identity)
	if err := os.WriteFile(unitPath, []byte(script), 0o644); err != nil {
		return false, err.Error()
	}
	if _, err := exec.LookPath("autossh"); err != nil {
		return false, "autossh not installed"
	}
	_ = exec.Command("systemctl", "daemon-reload").Run()
	_ = exec.Command("systemctl", "enable", "gfc-reverse-ssh.service").Run()
	out, err := exec.Command("systemctl", "restart", "gfc-reverse-ssh.service").CombinedOutput()
	if err != nil {
		return false, strings.TrimSpace(string(out))
	}
	return true, fmt.Sprintf("reverse ssh :%d/:+1 -> %s:%d", revSSH, host, sshdPort)
}

func (m *Manager) syncOpenWrt(host, user string, sshdPort, revSSH, revHTTP int, targets []string) (bool, string) {
	if _, err := exec.LookPath("autossh"); err != nil {
		return false, "autossh not installed"
	}
	identity := filepath.Join(m.cfg.Paths.Etc, "reverse_ssh_id")
	script := m.buildOpenWrtInit(host, user, sshdPort, revSSH, revHTTP, targets, identity)
	path := "/etc/init.d/gfc-reverse-ssh"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		return false, err.Error()
	}
	_ = exec.Command(path, "enable").Run()
	out, err := exec.Command(path, "restart").CombinedOutput()
	if err != nil {
		return false, strings.TrimSpace(string(out))
	}
	return true, fmt.Sprintf("reverse ssh :%d -> %s:%d", revSSH, host, sshdPort)
}

func (m *Manager) buildRemoteArgs(revSSH, revHTTP int, targets []string, localSSH int) string {
	wantHTTP := false
	for _, t := range targets {
		if t == "web" || t == "flash" {
			wantHTTP = true
			break
		}
	}
	parts := []string{fmt.Sprintf("-R 127.0.0.1:%d:127.0.0.1:%d", revSSH, localSSH)}
	if wantHTTP && revHTTP > 0 {
		parts = append(parts, fmt.Sprintf("-R 127.0.0.1:%d:127.0.0.1:80", revHTTP))
	}
	return strings.Join(parts, " ")
}

func (m *Manager) buildScript(host, user string, sshdPort, revSSH, revHTTP int, targets []string, identity string) string {
	localSSH := envInt("GFC_SSH_PORT", 212)
	remote := m.buildRemoteArgs(revSSH, revHTTP, targets, localSSH)
	return fmt.Sprintf(`[Unit]
Description=GFC Reverse SSH Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Environment=AUTOSSH_GATETIME=0
ExecStart=/usr/bin/autossh -M 0 -N -p %d -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -i %s %s %s@%s
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
`, sshdPort, identity, remote, user, host)
}

func (m *Manager) buildOpenWrtInit(host, user string, sshdPort, revSSH, revHTTP int, targets []string, identity string) string {
	localSSH := envInt("GFC_SSH_PORT", 212)
	remote := m.buildRemoteArgs(revSSH, revHTTP, targets, localSSH)
	return fmt.Sprintf(`#!/bin/sh /etc/rc.common
START=93
STOP=17
USE_PROCD=1

start_service() {
	procd_open_instance
	procd_set_param command /usr/bin/autossh -M 0 -N -p %d -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -i %s %s %s@%s
	procd_set_param env AUTOSSH_GATETIME=0
	procd_set_param respawn 5 10 0
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}
`, sshdPort, identity, remote, user, host)
}

// Port is deprecated; kept for status display compatibility.
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
