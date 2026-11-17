//go:build windows

package workbench

import (
	"os/exec"
	"syscall"

	"golang.org/x/sys/windows"
)

// hideConsole starts a console helper (a PowerShell script) without a console window. The client is
// a GUI program with no console of its own, so Windows would otherwise open one for every such
// helper, which with Windows Terminal as the default terminal is a visible terminal window.
func hideConsole(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}
}
