package reversessh

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/platform"
)

const restoreFlagPath = "/var/run/gfc-restore-reverse-ssh"

// RequestRestoreAfterNetwork marks that reverse SSH should be re-synced after network changes.
func RequestRestoreAfterNetwork() {
	_ = os.WriteFile(restoreFlagPath, []byte("1"), 0o644)
}

// ConsumeRestoreRequest returns true once per restore request.
func ConsumeRestoreRequest() bool {
	if _, err := os.Stat(restoreFlagPath); err != nil {
		return false
	}
	_ = os.Remove(restoreFlagPath)
	return true
}

// ClearLastCommand forces the next SyncCommand to re-apply tunnel settings.
func (m *Manager) ClearLastCommand() {
	m.lastCmd = ""
}

// RestartIfRunning restarts autossh when the unit was active before a network reload.
func (m *Manager) RestartIfRunning() (bool, string) {
	if !m.isActive() && !autosshProcessRunning() {
		return true, "reverse ssh idle"
	}
	if platform.IsOpenWrt() {
		if _, err := os.Stat(openWrtInitPath); err != nil {
			return false, "gfc-reverse-ssh init missing"
		}
		out, err := exec.Command(openWrtInitPath, "restart").CombinedOutput()
		if err != nil {
			return false, strings.TrimSpace(string(out))
		}
		return true, "reverse ssh restarted"
	}
	out, err := exec.Command("systemctl", "restart", "gfc-reverse-ssh.service").CombinedOutput()
	if err != nil {
		return false, strings.TrimSpace(string(out))
	}
	return true, "reverse ssh restarted"
}

// RestoreAfterNetwork clears cached command state and restarts an active tunnel.
func (m *Manager) RestoreAfterNetwork() (bool, string) {
	m.ClearLastCommand()
	ok, msg := m.RestartIfRunning()
	if !ok {
		return false, fmt.Sprintf("restore failed: %s", msg)
	}
	return true, msg
}
