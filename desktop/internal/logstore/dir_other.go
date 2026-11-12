//go:build !darwin && !windows

package logstore

import (
	"fmt"
	"os"
	"path/filepath"
)

// DefaultDir is the directory the client's logs live in when the user has not chosen one:
// $XDG_STATE_HOME/lithe-desktop/logs, falling back to ~/.local/state/lithe-desktop/logs. Logs are
// state, not configuration or cache, which is the XDG category they belong to.
func DefaultDir() (string, error) {
	if state := os.Getenv("XDG_STATE_HOME"); state != "" && filepath.IsAbs(state) {
		return filepath.Join(state, "lithe-desktop", "logs"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("find the home directory: %w", err)
	}
	return filepath.Join(home, ".local", "state", "lithe-desktop", "logs"), nil
}
