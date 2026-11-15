//go:build windows

package pluginpkg

import (
	"errors"
	"os"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// DefaultRoot is the directory installed plugin packages live in.
//
// Local app data rather than roaming: a package may carry a language server and
// a JDK, and those should not follow a roaming profile between machines.
func DefaultRoot() (string, error) {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		return "", errors.New("LOCALAPPDATA is not set")
	}
	return filepath.Join(base, store.Directory, "plugins"), nil
}
