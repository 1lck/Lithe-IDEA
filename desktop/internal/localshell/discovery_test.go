package localshell

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestShellDiscoveryUsesExistingExecutablesAndDeduplicates(t *testing.T) {
	root := t.TempDir()
	pwsh, cmd := filepath.Join(root, "PowerShell 7", "pwsh.exe"), filepath.Join(root, "cmd.exe")
	paths := map[string]string{"standard-pwsh": pwsh, "cmd.exe": cmd, "alias-cmd": strings.ToUpper(cmd)}
	lookup := func(program string) (string, error) {
		if path, ok := paths[program]; ok {
			return path, nil
		}
		return "", os.ErrNotExist
	}
	choices := discoverShells([]shellCandidate{
		{"PowerShell 7", []string{"", "missing-pwsh", "standard-pwsh"}},
		{"CMD", []string{"cmd.exe"}},
		{"Duplicate CMD", []string{"alias-cmd"}},
		{"Missing", []string{"missing"}},
	}, cmd, lookup)
	if len(choices) != 2 || choices[0].Path != pwsh || choices[0].Default || choices[1].Path != cmd || !choices[1].Default {
		t.Fatalf("discovered shells: %+v", choices)
	}
}
