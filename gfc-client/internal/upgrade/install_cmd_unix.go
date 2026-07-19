//go:build unix

package upgrade

import (
	"os/exec"
	"syscall"
)

func configureInstallCmd(cmd *exec.Cmd) {
	// New process group: surviving install.sh is not tied to the parent
	// session, and stdout is a file (not a pipe) so parent death cannot SIGPIPE it.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}
