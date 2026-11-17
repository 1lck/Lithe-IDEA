//go:build windows

package workbench

import (
	"os/exec"
	"syscall"

	"golang.org/x/sys/windows"
)

// hideConsole starts a console helper (a PowerShell script) without a console. The client is a GUI
// program with no console of its own, so Windows would otherwise give every such helper one, which
// with Windows Terminal as the default terminal is a visible terminal window. Only the console is
// withheld: HideWindow can also hide the first window the helper shows, such as the error dialog
// the trash command shows for a file in use, which would leave the helper waiting on a dialog
// nobody sees.
func hideConsole(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NO_WINDOW}
}
