package traffic

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/platform"
)

// ApplyShaping runs deploy/apply-tc-htb.sh (reads bandwidthMbps from saved bundle).
func ApplyShaping(root string) string {
	script := filepath.Join(root, "deploy", "apply-tc-htb.sh")
	if _, err := os.Stat(script); err != nil {
		return ""
	}
	shell := "/bin/bash"
	if platform.IsOpenWrt() {
		shell = "/bin/sh"
	}
	cmd := exec.Command(shell, script, "apply")
	out, err := cmd.CombinedOutput()
	line := strings.TrimSpace(string(out))
	if err != nil {
		if line != "" {
			return fmt.Sprintf("tc-htb: %s", line)
		}
		return fmt.Sprintf("tc-htb: %v", err)
	}
	if line != "" {
		return line
	}
	return "tc-htb: ok"
}

// RemoveShaping tears down HTB/IFB rules on gfctun.
func RemoveShaping(root string) string {
	script := filepath.Join(root, "deploy", "apply-tc-htb.sh")
	if _, err := os.Stat(script); err != nil {
		return ""
	}
	shell := "/bin/bash"
	if platform.IsOpenWrt() {
		shell = "/bin/sh"
	}
	cmd := exec.Command(shell, script, "remove")
	out, _ := cmd.CombinedOutput()
	line := strings.TrimSpace(string(out))
	if line != "" {
		return line
	}
	return "tc-htb: removed"
}
