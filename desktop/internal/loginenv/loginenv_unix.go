//go:build !windows

package loginenv

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/atomicfile"
)

const (
	// coldStartTimeout bounds the first start, which has no cached PATH: a profile that waits on
	// input or runs slowly must not keep the window from opening. refreshTimeout bounds every
	// other read, which runs in the background.
	coldStartTimeout = 3 * time.Second
	refreshTimeout   = 10 * time.Second
)

// Activate applies the login shell's PATH to this process. Call it at startup, before Core starts
// threads that read the environment. It returns the cache update to run afterwards, or nil.
func Activate() func() error {
	mu.Lock()
	activated = true
	mu.Unlock()
	if os.Getenv(SkipVariable) != "" {
		return nil
	}
	cache := cachePath()
	var cached string
	if cache != "" {
		if data, err := os.ReadFile(cache); err == nil {
			cached = strings.TrimSpace(string(data))
		}
	}
	if cached != "" {
		_ = os.Setenv("PATH", mergedPath(cached, os.Getenv("PATH")))
		return func() error {
			// This process keeps the PATH it started with; the next launch takes the new one.
			if values := captureLoginEnvironment(refreshTimeout); values != nil {
				remember(values)
				return writeCache(cache, values["PATH"])
			}
			return nil
		}
	}
	values := captureLoginEnvironment(coldStartTimeout)
	if values == nil {
		return nil
	}
	remember(values)
	if path := values["PATH"]; path != "" {
		_ = os.Setenv("PATH", mergedPath(path, os.Getenv("PATH")))
		return func() error { return writeCache(cache, path) }
	}
	return nil
}

// captureLoginEnvironment starts the user's shell as an interactive login shell and returns its
// environment, or nil when it fails or does not finish within timeout. A shell that runs too long
// is ended with every job its profile left in its process group.
func captureLoginEnvironment(timeout time.Duration) map[string]string {
	shell := os.Getenv("SHELL")
	if !strings.HasPrefix(shell, "/") {
		shell = "/bin/zsh"
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	command := exec.CommandContext(ctx, shell, "-ilc", "printf '"+marker+"'; /usr/bin/env -0; printf '"+marker+"'")
	command.Env = append(os.Environ(), SkipVariable+"=1")
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error { return syscall.Kill(-command.Process.Pid, syscall.SIGKILL) }
	command.WaitDelay = time.Second
	var output bytes.Buffer
	command.Stdout = &output
	// Both markers prove the output is complete, whatever the shell's exit status.
	_ = command.Run()
	if ctx.Err() != nil {
		return nil
	}
	return parse(output.Bytes())
}

// cachePath is where the login PATH is cached: <user cache>/Lithe/login-path.
func cachePath() string {
	base, err := os.UserCacheDir()
	if err != nil {
		return ""
	}
	return filepath.Join(base, "Lithe", "login-path")
}

// writeCache replaces the cached PATH through a temporary file, so a reader never sees half of it.
func writeCache(path, value string) error {
	if path == "" || value == "" {
		return nil
	}
	return atomicfile.Write(path, []byte(value+"\n"), 0o600)
}
