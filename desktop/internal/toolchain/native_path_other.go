//go:build !windows

package toolchain

import "path/filepath"

func resolveNativePath(absolute string) (string, error) {
	return filepath.EvalSymlinks(absolute)
}
