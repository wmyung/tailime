//go:build !windows

package tailscale

import "os/exec"

func configureHiddenCommand(cmd *exec.Cmd) {}
