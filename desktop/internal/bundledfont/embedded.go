//go:build darwin && lithe_bundled_fonts

package bundledfont

import (
	"embed"
	"io/fs"
)

// embedded is the fonts folder with its licenses; the license texts travel with the faces.
//
//go:embed fonts
var embedded embed.FS

// Files returns the bundled font files, at the root of the returned file system.
func Files() fs.FS {
	files, err := fs.Sub(embedded, "fonts")
	if err != nil {
		return nil
	}
	return files
}
