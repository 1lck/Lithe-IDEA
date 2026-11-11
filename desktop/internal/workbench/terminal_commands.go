package workbench

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/shellkind"
)

// This file sends a command the client issues to a terminal (matrix id terminal-long-command-input).
// The command cmd.exe and PowerShell accept on one line is limited, so a longer command is written
// to a one-off script in the user's cache directory and the shell runs that script instead; the
// script keeps the command text exactly, and the terminal removes it when it closes. The shell's own
// configuration is never changed. Other shells and short commands are typed as they are.

// terminalCommandLimit is the longest command typed as one line; it stays under cmd.exe's 8191
// characters, the tighter of the two Windows shells' limits.
const terminalCommandLimit = 8000

// terminalCommandDirectory is where the one-off scripts are written: the user's cache directory.
func terminalCommandDirectory() (string, error) {
	base, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "Lithe", "terminal-commands"), nil
}

// sendTerminalCommand types command into t. A command longer than the line limit of a cmd.exe or
// PowerShell terminal is written to a script and the script runs; it reports false when the shell
// did not take the line or the script could not be written.
func (a *App) sendTerminalCommand(t *terminal, command string) bool {
	if t == nil || t.view == nil {
		return false
	}
	kind := shellkind.FromProgram(t.shell)
	if len(command) <= terminalCommandLimit || (kind != shellkind.Cmd && kind != shellkind.PowerShell) {
		return t.view.SendLine(command)
	}
	line, path, err := writeCommandScript(kind, command)
	if err != nil {
		a.notify(err.Error())
		return false
	}
	t.scripts = append(t.scripts, path)
	return t.view.SendLine(line)
}

// writeCommandScript writes command to a new script for kind and returns the line that runs it and
// the script's path.
func writeCommandScript(kind shellkind.Kind, command string) (line, path string, err error) {
	dir, err := terminalCommandDirectory()
	if err != nil {
		return "", "", fmt.Errorf("terminal command: %w", err)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", "", fmt.Errorf("terminal command: %w", err)
	}
	var random [8]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", "", fmt.Errorf("terminal command: %w", err)
	}
	name := hex.EncodeToString(random[:])
	if kind == shellkind.Cmd {
		path = filepath.Join(dir, name+".cmd")
		body := strings.ReplaceAll(strings.ReplaceAll(command, "\r\n", "\n"), "\n", "\r\n")
		if err := os.WriteFile(path, []byte(body+"\r\n"), 0o600); err != nil {
			return "", "", fmt.Errorf("terminal command: %w", err)
		}
		return `call "` + path + `"`, path, nil
	}
	path = filepath.Join(dir, name+".ps1")
	if err := os.WriteFile(path, []byte(command+"\n"), 0o600); err != nil {
		return "", "", fmt.Errorf("terminal command: %w", err)
	}
	// The script is read and run inline, so the execution policy does not stop it.
	quoted := strings.ReplaceAll(path, "'", "''")
	return "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '" + quoted + "')))", path, nil
}

// removeCommandScripts deletes the scripts written for the terminal. A script that is already gone
// is not an error.
func (t *terminal) removeCommandScripts() {
	for _, path := range t.scripts {
		_ = os.Remove(path)
	}
	t.scripts = nil
}
