//go:build !unix

package upgrade

import "os/exec"

func configureInstallCmd(cmd *exec.Cmd) {}
