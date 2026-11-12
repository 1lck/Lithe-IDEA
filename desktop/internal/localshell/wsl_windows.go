//go:build windows

package localshell

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

// wslExecutable is the wsl.exe that runs distributions, or empty when this
// Windows has none.
func wslExecutable() string {
	if path, err := exec.LookPath("wsl.exe"); err == nil {
		return path
	}
	if root := os.Getenv("SystemRoot"); root != "" {
		path := filepath.Join(root, "System32", "wsl.exe")
		if info, err := os.Stat(path); err == nil && !info.IsDir() {
			return path
		}
	}
	return ""
}

// InstalledWSL lists the distributions that can be started, asking wsl.exe.
// It starts a process, so callers keep it off the window thread. No wsl.exe, a
// failing one, or no distribution is an empty list.
func InstalledWSL(ctx context.Context) []Choice {
	exe := wslExecutable()
	if exe == "" {
		return nil
	}
	command := exec.CommandContext(ctx, exe, "--list", "--quiet")
	// Ask for UTF-8, which newer WSL honors; older output is UTF-16 and decoded.
	command.Env = append(os.Environ(), "WSL_UTF8=1")
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000} // CREATE_NO_WINDOW
	output, err := command.Output()
	if err != nil {
		return nil
	}
	return WSLChoices(ParseWSLDistros(output))
}

// prepareWSL turns a request for a WSL distribution into the wsl.exe command
// that starts it: the program, and the Config to run it with.
func prepareWSL(config Config, distro string) (string, Config, error) {
	exe := wslExecutable()
	if exe == "" {
		return "", config, errors.New("localshell: WSL is not installed")
	}
	program, args, env := wslLaunch(exe, config, distro, os.Getenv("WSLENV"))
	config.Args = args
	config.Env = append(append([]string(nil), config.Env...), env...)
	// wsl.exe takes the folder as --cd or from the script; the Windows folder
	// the process itself starts in does not matter.
	config.Dir = ""
	return program, config, nil
}
