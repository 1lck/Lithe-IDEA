package main

import (
	"os/exec"
	"syscall"
)

func detachGUI(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x00000008 | syscall.CREATE_NEW_PROCESS_GROUP}
}
