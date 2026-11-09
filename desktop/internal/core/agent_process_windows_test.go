//go:build windows

package core

import (
	"errors"
	"syscall"
	"testing"
)

func assertAgentFixtureStopped(t *testing.T, pid int) {
	t.Helper()
	handle, err := syscall.OpenProcess(syscall.SYNCHRONIZE, false, uint32(pid))
	if errors.Is(err, syscall.Errno(87)) { // ERROR_INVALID_PARAMETER: process no longer exists.
		return
	}
	if err != nil {
		t.Fatalf("open fixture process: %v", err)
	}
	defer syscall.CloseHandle(handle)
	result, err := syscall.WaitForSingleObject(handle, 2000)
	if err != nil || result != 0 { // WAIT_OBJECT_0
		t.Fatalf("fixture process %d did not stop: wait=%d err=%v", pid, result, err)
	}
}
