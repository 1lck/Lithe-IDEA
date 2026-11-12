//go:build windows

package localshell

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
	"github.com/1lck/Lithe-IDEA/desktop/internal/winpath"
)

func TestWindowsShellReportsDirectoryAfterChangingIt(t *testing.T) {
	for _, program := range []string{"cmd.exe", "powershell.exe", "pwsh.exe"} {
		t.Run(program, func(t *testing.T) {
			program, err := exec.LookPath(program)
			if err != nil {
				t.Skip("shell not installed")
			}
			home := t.TempDir()
			target := filepath.Join(home, "中文 空格;100%")
			if err := os.Mkdir(target, 0700); err != nil {
				t.Fatal(err)
			}
			config := Config{Shell: program, Dir: home, DirectoryToken: "test-token"}
			if strings.EqualFold(filepath.Base(program), "powershell.exe") {
				// The agent host injects PowerShell 7 modules into PSModulePath.
				// Windows PowerShell 5.1 must use its own signed inbox modules.
				config.Env = []string{"PSModulePath=" + filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "Modules")}
			}
			shell, wakes := startWindows(t, config)
			screen := term.New(120, 30, 0)
			screen.SetPromptToken("test-token")
			started := false
			screen.SetPromptStart(func() { started = true })
			wait := func(want string) {
				t.Helper()
				deadline := time.NewTimer(12 * time.Second)
				defer deadline.Stop()
				for {
					screen.Write(shell.Drain(nil))
					if cwd, ok := screen.WorkingDirectory(); ok && winpath.Equal(cwd.Path, want) && started {
						return
					}
					select {
					case <-wakes:
					case <-deadline.C:
						cwd, _ := screen.WorkingDirectory()
						t.Fatalf("wanted %q, got %q; screen: %q", want, cwd.Path, screen.Text())
					}
				}
			}
			wait(home)
			command := "Set-Location -LiteralPath '" + strings.ReplaceAll(target, "'", "''") + "'\r"
			if strings.EqualFold(filepath.Base(program), "cmd.exe") {
				command = "cd /d \"" + target + "\"\r"
			}
			if !shell.Write([]byte(command)) {
				t.Fatal("shell refused input")
			}
			wait(target)
		})
	}
}

func TestWindowsIntegrationLeavesCommandsAndUnknownShellsUntouched(t *testing.T) {
	for _, config := range []Config{{DirectoryToken: "bad';command"}, {DirectoryToken: "valid", Args: []string{"-Command", "echo test"}}, {}} {
		actual := integrateWindowsShell(config, "pwsh.exe")
		if strings.Join(actual.Args, "|") != strings.Join(config.Args, "|") || len(actual.Env) != len(config.Env) {
			t.Fatal("integration changed an explicit command or invalid configuration")
		}
	}
	if config := integrateWindowsShell(Config{DirectoryToken: "valid"}, "other.exe"); len(config.Args) != 0 || len(config.Env) != 0 {
		t.Fatal("integration modified an unknown shell")
	}
}

func TestPowerShellDirectoryIntegrationPreservesCustomPromptAndExitStatus(t *testing.T) {
	for _, program := range []string{"powershell.exe", "pwsh.exe"} {
		t.Run(program, func(t *testing.T) {
			program, err := exec.LookPath(program)
			if err != nil {
				t.Skip("shell not installed")
			}
			script := `function global:prompt {
    if ($?) { 'motty-success' } else { 'motty-failure' }
    if ($global:LASTEXITCODE -ne 37) { throw 'LASTEXITCODE changed' }
}
` + strings.ReplaceAll(powerShellDirectoryIntegration, "__MOTTY_TOKEN__", "test-token") + `
$global:LASTEXITCODE = 37
Write-Error 'original failure' -ErrorAction Ignore
$rendered = prompt
if ($rendered -notmatch 'motty-failure') { throw "failure status lost: $rendered" }
Write-Output 'success' | Out-Null
$rendered = prompt
if ($rendered -notmatch 'motty-success') { throw "success status lost: $rendered" }
`
			output, err := exec.Command(program, "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", encodePowerShellCommand(script)).CombinedOutput()
			if err != nil {
				t.Fatalf("prompt status: %v: %s", err, output)
			}
		})
	}
}
