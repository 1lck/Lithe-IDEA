//go:build darwin

package logstore

import (
	"fmt"
	"os"
	"path/filepath"
)

// DefaultDir is the directory the client's logs live in when the user has not chosen one:
// ~/Library/Logs/Lithe Desktop, the place Console.app and the system's log collection look in.
// It is outside the app bundle, so writing logs never changes the installed release bytes.
func DefaultDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("find the home directory: %w", err)
	}
	return filepath.Join(home, "Library", "Logs", "Lithe Desktop"), nil
}
