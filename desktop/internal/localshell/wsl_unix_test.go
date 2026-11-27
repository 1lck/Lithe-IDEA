//go:build !windows

package localshell

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The WSL start script is plain sh, so it runs here against stand-ins for what
// a distribution has and this machine does not.

// fakeWSLPath stands in for a distribution's wslpath -u: a Windows path is given
// back as the Linux one without its drive, so the test's own folders can be named.
const fakeWSLPath = `#!/bin/sh
case $1 in
-u) printf '%s\n' "$(printf '%s' "${2#?:}" | tr '\\' /)" ;;
*) exit 2 ;;
esac
`

// fakeGetent answers for the passwd entry of the user whose login shell the
// test is about; the script asks for it with getent, as WSL's distributions have.
const fakeGetent = `#!/bin/sh
printf 'user:x:1000:1000::%s:%s\n' "$HOME" "$LITHE_TEST_LOGIN_SHELL"
`

// fakeWindowsDrivePath spells a folder as a path on a Windows drive, which the
// script turns into a Linux path with wslpath.
func fakeWindowsDrivePath(linux string) string {
	return `C:` + strings.ReplaceAll(linux, "/", `\`)
}

func writeFakeWSLTools(t *testing.T) string {
	t.Helper()
	tools := t.TempDir()
	for name, content := range map[string]string{"wslpath": fakeWSLPath, "getent": fakeGetent} {
		if err := os.WriteFile(filepath.Join(tools, name), []byte(content), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	return tools
}

func TestWSLScriptStartsTheLoginShellInTheStartFolder(t *testing.T) {
	for _, name := range []string{"bash", "zsh"} {
		t.Run(name, func(t *testing.T) {
			program, err := exec.LookPath(name)
			if err != nil {
				t.Skipf("%s unavailable: %v", name, err)
			}
			home, runtimeDir, tools := t.TempDir(), t.TempDir(), writeFakeWSLTools(t)
			startDir := filepath.Join(home, "start here", "a b%'#;$()", "café")
			if err := os.MkdirAll(startDir, 0o700); err != nil {
				t.Fatal(err)
			}
			// /etc/profile may reset PATH, so the stand-in is put on it by the user's
			// own startup file, the way a distribution has wslpath in /usr/bin.
			profile := "printf 'user-profile-loaded\\n'\nPS1='user-prompt> '\nPATH='" + tools + "':$PATH\n"
			file := ".bash_profile"
			if name == "zsh" {
				file = ".zshrc"
			}
			if err := os.WriteFile(filepath.Join(home, file), []byte(profile), 0o600); err != nil {
				t.Fatal(err)
			}

			script := wslIntegrationScript("wsl-test-token", WSLDirectoryVariable)
			if script == "" {
				t.Fatal("no script")
			}
			s := startIntegrated(t, Config{
				Shell: "/bin/sh", Args: []string{"-c", wslCommandLine(script), "sh"}, Dir: home, Unset: []string{"TERM_PROGRAM"},
				// The Windows folder is given in the other spelling on purpose.
				Env: []string{
					"HOME=" + home, "ZDOTDIR=" + home, "SHELL=/bin/sh", "LITHE_TEST_LOGIN_SHELL=" + program, "TMPDIR=" + runtimeDir,
					"PATH=" + tools + string(os.PathListSeparator) + os.Getenv("PATH"), "LANG=en_US.UTF-8",
					WSLDirectoryVariable + "=" + fakeWindowsDrivePath(startDir),
				},
			}, "wsl-test-token")
			// The shell starts in the folder the environment named, not the home
			// folder, and the user's own startup file ran.
			// Login startup reads /etc/profile and the runner's shell initialization.
			// Under full desktop CI load it may not emit its first byte in 10s;
			// later interactive commands still use the normal bounded 10s wait.
			s.awaitWithin("the first prompt", 30*time.Second, func() bool { return s.ready() > 0 })
			s.run("printf 'in=%s\\n' \"$PWD\"\r", 1, "in="+startDir+"\r\n")
			if !strings.Contains(s.output, "user-profile-loaded") {
				t.Fatalf("the user's startup file did not run: %q", s.output)
			}
			if strings.Contains(s.output, WSLDirectoryVariable) {
				t.Fatalf("the start folder variable reached the shell: %q", s.output)
			}
			if !s.screen.CommandReporting() || s.starts() == 0 || s.lastExit() != 0 {
				t.Fatalf("the shell did not report its commands: %q", s.output)
			}

			s.exit("exit 7\r", 7)
			emptyDirectory(t, runtimeDir)
		})
	}
}

func TestWSLScriptFallsBackToAPlainLoginShellForOtherShells(t *testing.T) {
	home, tools := t.TempDir(), writeFakeWSLTools(t)
	shell, wakes := start(t, Config{
		Shell: "/bin/sh", Args: []string{"-c", wslCommandLine(wslIntegrationScript("wsl-test-token", WSLDirectoryVariable)), "sh"}, Dir: home,
		Env: []string{"HOME=" + home, "SHELL=/bin/sh", "LITHE_TEST_LOGIN_SHELL=/bin/sh", "PATH=" + tools + string(os.PathListSeparator) + os.Getenv("PATH")},
	})
	shell.Write([]byte("echo plain-shell-$((6*7))\n"))
	until(t, shell, wakes, "plain-shell-42")
	shell.Write([]byte("exit 0\n"))
	// Close is asynchronous; let the child leave before TempDir removes its home.
	select {
	case <-shell.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("the plain login shell did not exit")
	}
}

func TestWSLCommandLineFallsBackToTheUsersShellWhenItCannotBeDecoded(t *testing.T) {
	line := strings.Replace(wslCommandLine("echo never\n"), "|base64 -d", "|false", 1)
	shell, wakes := start(t, Config{Shell: "/bin/sh", Args: []string{"-c", line, "sh"}, Env: []string{"SHELL=/bin/sh"}})
	shell.Write([]byte("echo fallback-shell-$((6*7))\n"))
	until(t, shell, wakes, "fallback-shell-42")
	shell.Write([]byte("exit 0\n"))
	select {
	case <-shell.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("the fallback shell did not exit")
	}
}
