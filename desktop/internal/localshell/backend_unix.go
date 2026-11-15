//go:build !windows

package localshell

import (
	"errors"
	"github.com/1lck/Lithe-IDEA/desktop/internal/processledger"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"syscall"

	"github.com/creack/pty"
	"golang.org/x/sys/unix"
)

// defaultShell is the user's login shell, else sh.
func defaultShell() string {
	if program := os.Getenv("SHELL"); program != "" {
		return program
	}
	return "/bin/sh"
}

func startBackend(config Config) (backend, error) {
	program := config.Shell
	if program == "" {
		program = defaultShell()
	}
	args := config.Args
	if args == nil {
		args = []string{"-l"}
	}
	cmd := exec.Command(program, args...)
	cmd.Dir = config.Dir
	if cmd.Dir == "" {
		if home, err := os.UserHomeDir(); err == nil {
			cmd.Dir = home
		}
	}
	inherited := os.Environ()
	if pwd := workingDirectoryVariable(cmd.Dir); pwd != "" {
		inherited = append(withoutVariables(inherited, []string{"PWD"}), "PWD="+pwd)
	}
	cmd.Env = append(withoutVariables(inherited, config.Unset), "TERM=xterm-256color", "COLORTERM=truecolor")
	cmd.Env = append(cmd.Env, config.Env...)
	cmd.Env = withUTF8Locale(cmd.Env)
	size := &pty.Winsize{Cols: uint16(max(config.Cols, 1)), Rows: uint16(max(config.Rows, 1))}
	master, err := pty.StartWithSize(cmd, size)
	if err != nil {
		return backend{}, err
	}
	// A terminal's shell is recorded until it ends, so a leftover can be offered for ending at start-up.
	untrack := processledger.Track(processledger.KindTerminal, cmd.Process.Pid)
	return backend{
		io: master,
		resize: func(cols, rows int) {
			control, err := master.SyscallConn()
			if err != nil {
				return
			}
			// A queued resize can overlap Close. Control holds a reference to
			// the descriptor until the ioctl returns, so it cannot be destroyed
			// or recycled for another file while the resize is in flight.
			_ = control.Control(func(fd uintptr) {
				_ = unix.IoctlSetWinsize(int(fd), unix.TIOCSWINSZ, &unix.Winsize{Col: uint16(cols), Row: uint16(rows)})
			})
		},
		wait: func() (int, error) {
			err := cmd.Wait()
			untrack()
			var exit *exec.ExitError
			if errors.As(err, &exit) {
				if code := exit.ExitCode(); code > 0 {
					return code, nil
				}
				return 0, nil // ended by our own hangup or a signal: not a failure to report
			}
			return 0, err
		},
		hangup: func() { _ = cmd.Process.Signal(syscall.SIGHUP) },
		kill:   func() { _ = cmd.Process.Kill() },
		// The shell leads its own process group; a command it runs in the
		// foreground gets another one, and the pty names the foreground group.
		busy: func() bool {
			control, err := master.SyscallConn()
			if err != nil {
				return false
			}
			group := 0
			readErr := control.Control(func(fd uintptr) {
				group, err = unix.IoctlGetInt(int(fd), unix.TIOCGPGRP)
			})
			return readErr == nil && err == nil && group > 0 && group != cmd.Process.Pid
		},
	}, nil
}

// workingDirectoryVariable is the PWD of a shell started in directory, or "" when
// directory is unknown. A shell takes its directory from PWD when PWD names it and
// from the kernel's spelling otherwise, so without this a shell in a directory
// reached through a symbolic link (macOS's /var is /private/var) would print a
// path other than the one the user opened. The inherited PWD is the host's own
// directory, and os/exec sets PWD only for a command without an environment.
func workingDirectoryVariable(directory string) string {
	if directory == "" {
		return ""
	}
	absolute, err := filepath.Abs(directory)
	if err != nil {
		return ""
	}
	return absolute
}

// withoutVariables is environment without the named variables.
func withoutVariables(environment, names []string) []string {
	if len(names) == 0 {
		return environment
	}
	kept := make([]string, 0, len(environment))
	for _, entry := range environment {
		name, _, _ := strings.Cut(entry, "=")
		if !slices.Contains(names, name) {
			kept = append(kept, entry)
		}
	}
	return kept
}
