//go:build darwin

package pluginpkg

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// DefaultRoot is the directory installed plugin packages live in.
//
// An installed app bundle is a release artefact that differential updates depend
// on byte for byte, so a plugin package and everything it writes live below the
// user's Application Support folder instead.
func DefaultRoot() (string, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("find the application support directory: %w", err)
	}
	return filepath.Join(base, store.Directory, "plugins"), nil
}
