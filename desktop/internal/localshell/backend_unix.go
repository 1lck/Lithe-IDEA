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
	dir := config.Dir
	if dir == "" {
		if home, err := os.UserHomeDir(); err == nil {
			dir = home
		}
	}
	inherited := os.Environ()
	if pwd := workingDirectoryVariable(dir); pwd != "" {
		inherited = append(withoutVariables(inherited, []string{"PWD"}), "PWD="+pwd)
	}
	env := append(withoutVariables(inherited, config.Unset), "TERM=xterm-256color", "COLORTERM=truecolor")
	env = withUTF8Locale(append(env, config.Env...))
	args := config.Args
	// runtime is the private directory of an integrated shell's startup files:
	// it is made here and removed once the shell has ended, however it ended,
	// as the shell removes it itself only when its startup gets that far.
	runtime, promptToken := "", ""
	if args == nil {
		args = []string{"-l"}
		// Bash and Zsh report their prompt, commands and folder when sh writes
		// their startup files and then becomes them (see integration_scripts.go),
		// so the shell is still the process started here. Without a private
		// directory the shell starts as itself.
		if integrationScriptWith(program, false, config.DirectoryToken) != "" {
			if made, err := os.MkdirTemp(temporaryDirectory(env), "motty-shell."); err == nil {
				program, args, runtime = "/bin/sh", integrationArgs(program, config.DirectoryToken, made), made
				promptToken = config.DirectoryToken
			}
		}
	}
	removeRuntime := func() {
		if runtime != "" {
			_ = os.RemoveAll(runtime)
		}
	}
	cmd := exec.Command(program, args...)
	cmd.Dir = dir
	cmd.Env = env
	size := &pty.Winsize{Cols: uint16(max(config.Cols, 1)), Rows: uint16(max(config.Rows, 1))}
	master, err := pty.StartWithSize(cmd, size)
	if err != nil {
		removeRuntime()
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
			removeRuntime()
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
		promptToken: promptToken,
	}, nil
}

// temporaryDirectory is the TMPDIR of the environment env, the shell's, or
// /tmp when it names none. The last setting wins, as it does for the shell.
func temporaryDirectory(env []string) string {
	for i := len(env) - 1; i >= 0; i-- {
		if value, ok := strings.CutPrefix(env[i], "TMPDIR="); ok {
			if value != "" {
				return value
			}
			break
		}
	}
	return "/tmp"
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
