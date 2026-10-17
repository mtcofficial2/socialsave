//go:build windows

package providers

import (
	"os/exec"
	"syscall"
)

// createNoWindow keeps yt-dlp, ffmpeg and deno from flashing console windows
// when the desktop app's engine starts them.
const createNoWindow = 0x08000000

func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
}
