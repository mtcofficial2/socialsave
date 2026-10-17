//go:build !windows

package providers

import "os/exec"

func hideWindow(*exec.Cmd) {}
