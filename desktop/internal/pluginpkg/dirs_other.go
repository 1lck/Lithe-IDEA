//go:build !darwin && !windows

package pluginpkg

import (
	"fmt"
	"os"
	"path/filepath"
)

// DefaultRoot is the directory installed plugin packages live in.
func DefaultRoot() (string, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("find the configuration directory: %w", err)
	}
	return filepath.Join(base, "lithe-desktop", "plugins"), nil
}
