//go:build !darwin || !lithe_bundled_fonts

package bundledfont

import "io/fs"

// Files returns nil: this build carries no fonts, so the system's fonts apply.
func Files() fs.FS { return nil }
