//go:build windows

package logstore

import (
	"errors"
	"os"
	"path/filepath"
)

// DefaultDir is the directory the client's logs live in when the user has not chosen one:
// %LOCALAPPDATA%\Lithe Desktop\Logs. Logs are machine-local runtime state, so they live in the
// local (non-roaming) application data and never in the installation directory.
func DefaultDir() (string, error) {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		return "", errors.New("LOCALAPPDATA is not set")
	}
	return filepath.Join(base, "Lithe Desktop", "Logs"), nil
}
