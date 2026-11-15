//go:build windows

package buildprocess

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

const (
	windowsTreeMode   = "LITHE_TEST_WINDOWS_TREE"
	windowsTreePID    = "LITHE_TEST_WINDOWS_TREE_PID"
	windowsTreeHelper = "^TestWindowsTreeParentHelper$"
	windowsTreeChild  = "^TestWindowsTreeChildHelper$"
)

func TestWindowsTreeParentHelper(t *testing.T) {
	if os.Getenv(windowsTreeMode) != "parent" {
		return
	}
	child := exec.Command(os.Args[0], "-test.run="+windowsTreeChild)
	child.Env = append(os.Environ(), windowsTreeMode+"=child", windowsTreePID+"="+os.Getenv(windowsTreePID))
	if err := child.Start(); err != nil {
		os.Exit(11)
	}
	time.Sleep(30 * time.Second)
	os.Exit(0)
}

func TestWindowsTreeChildHelper(t *testing.T) {
	if os.Getenv(windowsTreeMode) != "child" {
		return
	}
	path := os.Getenv(windowsTreePID)
	if err := os.WriteFile(path, []byte(strconv.Itoa(os.Getpid())), 0o600); err != nil {
		os.Exit(12)
	}
	time.Sleep(30 * time.Second)
	os.Exit(0)
}

func TestWindowsJobEndsDescendantsAfterStop(t *testing.T) {
	directory := t.TempDir()
	pidFile := filepath.Join(directory, "child.pid")
	spec := Spec{
		Executable:       os.Args[0],
		Arguments:        []string{"-test.run=" + windowsTreeHelper},
		WorkingDirectory: directory,
		Environment:      map[string]string{windowsTreeMode: "parent", windowsTreePID: pidFile},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	process, err := Start(ctx, spec, nil)
	if err != nil {
		t.Fatal(err)
	}
	pid := waitWindowsPID(t, ctx, pidFile)
	process.Stop()
	if err := process.Wait(); err != nil {
		// The root is expected to exit non-zero when its job is terminated.
		t.Logf("root exit: %v", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		if windowsProcessGone(pid) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("child process %d survived the job termination", pid)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func waitWindowsPID(t *testing.T, ctx context.Context, path string) int {
	t.Helper()
	for {
		if body, err := os.ReadFile(path); err == nil {
			pid, parseErr := strconv.Atoi(strings.TrimSpace(string(body)))
			if parseErr == nil && pid > 0 {
				return pid
			}
		}
		select {
		case <-ctx.Done():
			t.Fatalf("the child process did not report its PID: %v", ctx.Err())
		default:
			time.Sleep(10 * time.Millisecond)
		}
	}
}

func windowsProcessGone(pid int) bool {
	handle, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(pid))
	if err != nil {
		return true
	}
	defer windows.CloseHandle(handle)
	event, err := windows.WaitForSingleObject(handle, 0)
	if err != nil {
		return false
	}
	return event == windows.WAIT_OBJECT_0
}
