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
)

// PowerShell and cmd.exe mark their prompt under the session's token when they
// start and after every command, a folder change included: the folder's name is
// part of the prompt the marks wrap. PowerShell, through PSReadLine, also marks
// the command's start before it runs, which is what turns on the features that
// need it (#2008); cmd.exe never does.
func TestWindowsShellsMarkTheirPromptsUnderTheToken(t *testing.T) {
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
			config := Config{Shell: program, Dir: home, PromptToken: "test-token"}
			if strings.EqualFold(filepath.Base(program), "powershell.exe") {
				// The agent host injects PowerShell 7 modules into PSModulePath.
				// Windows PowerShell 5.1 must use its own signed inbox modules: the
				// system ones, and the PSReadLine it ships under Program Files.
				config.Env = []string{"PSModulePath=" + strings.Join([]string{
					filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "Modules"),
					filepath.Join(os.Getenv("ProgramFiles"), "WindowsPowerShell", "Modules"),
				}, string(os.PathListSeparator))}
			}
			shell, wakes := startWindows(t, config)
			screen := term.New(120, 30, 0)
			screen.SetPromptToken("test-token")
			var output strings.Builder
			// marks counts the shell's markers of kind so far, however ConPTY ends them.
			marks := func(kind string) int { return strings.Count(output.String(), "\x1b]133;"+kind+";motty=test-token") }
			// The first prompt waits for the shell to start. Windows PowerShell 5.1 takes about 9 s
			// to start on the Windows CI runners and sometimes more than 12 s; the prompt after a
			// directory change comes much sooner.
			const startDeadline, promptDeadline = 45 * time.Second, 12 * time.Second
			wait := func(what string, limit time.Duration, done func() bool) {
				t.Helper()
				deadline := time.NewTimer(limit)
				defer deadline.Stop()
				for {
					data := shell.Drain(nil)
					output.Write(data)
					screen.Write(data)
					if done() {
						return
					}
					select {
					case <-wakes:
					case <-deadline.C:
						t.Fatalf("waiting for %s (A=%d B=%d C=%d); screen: %q", what, marks("A"), marks("B"), marks("C"), screen.Text())
					}
				}
			}
			wait("the first prompt", startDeadline, func() bool { return marks("A") > 0 && marks("B") > 0 })
			started, ready := marks("A"), marks("B")
			command := "Set-Location -LiteralPath '" + strings.ReplaceAll(target, "'", "''") + "'\r"
			if strings.EqualFold(filepath.Base(program), "cmd.exe") {
				command = "cd /d \"" + target + "\"\r"
			}
			if !shell.Write([]byte(command)) {
				t.Fatal("shell refused input")
			}
			wait("the prompt after the folder change", promptDeadline, func() bool { return marks("A") > started && marks("B") > ready })
			text := output.String()
			if strings.EqualFold(filepath.Base(program), "cmd.exe") {
				if marks("C") != 0 || screen.CommandReporting() {
					t.Fatalf("cmd.exe marked %d command starts", marks("C"))
				}
				return
			}
			// The start of the command comes before the prompt drawn after it.
			if start, prompt := strings.LastIndex(text, "\x1b]133;C;motty=test-token"), strings.LastIndex(text, "\x1b]133;A;motty=test-token"); start < 0 || start > prompt {
				t.Fatalf("the command's start is at %d, the prompt after it at %d", start, prompt)
			}
			if !screen.CommandReporting() || !screen.AtPrompt() {
				t.Fatalf("the screen does not trust the prompt: reporting %v, at prompt %v", screen.CommandReporting(), screen.AtPrompt())
			}
		})
	}
}

func TestWindowsIntegrationLeavesCommandsAndUnknownShellsUntouched(t *testing.T) {
	for _, config := range []Config{{PromptToken: "bad';command"}, {PromptToken: "valid", Args: []string{"-Command", "echo test"}}, {}} {
		actual := integrateWindowsShell(config, "pwsh.exe")
		if strings.Join(actual.Args, "|") != strings.Join(config.Args, "|") || len(actual.Env) != len(config.Env) {
			t.Fatal("integration changed an explicit command or invalid configuration")
		}
	}
	if config := integrateWindowsShell(Config{PromptToken: "valid"}, "other.exe"); len(config.Args) != 0 || len(config.Env) != 0 {
		t.Fatal("integration modified an unknown shell")
	}
}

// PowerShell keeps its version banner: the integration runs after it, so hiding
// it was never needed, and a tab starts as it does in Windows Terminal.
func TestPowerShellIntegrationKeepsTheBanner(t *testing.T) {
	for _, program := range []string{"pwsh.exe", "powershell.exe"} {
		args := integrateWindowsShell(Config{PromptToken: "valid"}, program).Args
		if len(args) != 3 || strings.Join(args[:2], " ") != "-NoExit -EncodedCommand" {
			t.Fatalf("%s arguments = %q, want -NoExit -EncodedCommand and the script, without -NoLogo", program, args)
		}
	}
}

// PSReadLine's reader is wrapped to mark the command's start: the line it returns
// is unchanged, it still sees whether the last command failed (it colors its error
// prompt by it), and without PSReadLine no reader is defined.
func TestPowerShellReadLineIntegrationMarksTheCommandStart(t *testing.T) {
	for _, program := range []string{"powershell.exe", "pwsh.exe"} {
		t.Run(program, func(t *testing.T) {
			program, err := exec.LookPath(program)
			if err != nil {
				t.Skip("shell not installed")
			}
			integration := strings.ReplaceAll(powerShellPromptIntegration, "__MOTTY_TOKEN__", "test-token")
			script := `function global:PSConsoleHostReadLine {
    if ($?) { 'line after success' } else { 'line after failure' }
}
` + integration + `
Write-Error 'original failure' -ErrorAction Ignore
$line = PSConsoleHostReadLine
if ($line -ne 'line after failure') { throw "failure status lost: $line" }
Write-Output 'success' | Out-Null
$line = PSConsoleHostReadLine
if ($line -ne 'line after success' -or $line -isnot [string]) { throw "line changed: $line" }
`
			output, err := exec.Command(program, "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", encodePowerShellCommand(script)).CombinedOutput()
			if err != nil {
				t.Fatalf("reader status: %v: %s", err, output)
			}
			if n := strings.Count(string(output), "\x1b]133;C;motty=test-token\a"); n != 2 {
				t.Fatalf("marked %d command starts for 2 lines: %q", n, output)
			}
			bare := integration + `
if (Test-Path Function:\PSConsoleHostReadLine) { throw 'a reader was defined without PSReadLine' }
`
			if output, err := exec.Command(program, "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", encodePowerShellCommand(bare)).CombinedOutput(); err != nil {
				t.Fatalf("without PSReadLine: %v: %s", err, output)
			}
		})
	}
}

func TestPowerShellPromptIntegrationPreservesCustomPromptAndExitStatus(t *testing.T) {
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
` + strings.ReplaceAll(powerShellPromptIntegration, "__MOTTY_TOKEN__", "test-token") + `
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
