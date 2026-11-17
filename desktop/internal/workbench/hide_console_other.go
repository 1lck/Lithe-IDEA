//go:build !windows

package workbench

import "os/exec"

// hideConsole has nothing to hide where helpers inherit no console window.
func hideConsole(*exec.Cmd) {}
