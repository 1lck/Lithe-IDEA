package core

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
)

// ErrIDEHelperMissing means no lithe-mcp helper exists at any candidate path.
// The settings page shows "helper missing" and keeps enabling disabled.
var ErrIDEHelperMissing = errors.New("lithe-mcp helper is missing")

// IDEHelperName is the packaged stdio helper binary (the lithe-ide-host crate's lithe-mcp bin).
func IDEHelperName() string {
	if runtime.GOOS == "windows" {
		return "lithe-mcp.exe"
	}
	return "lithe-mcp"
}

// ResolveIDEHelperPath returns the first existing helper candidate. Packaged
// builds look beside the executable; development builds use the Core artifact
// directory (.artifacts/desktop/lithe-core/<target>/<profile>/bin). The
// candidates are never written to, so the bundle stays read-only.
func ResolveIDEHelperPath(executableDir, artifactBinDir string) (string, error) {
	candidates := []string{
		filepath.Join(executableDir, IDEHelperName()),
		filepath.Join(executableDir, "..", "Resources", IDEHelperName()),
	}
	if artifactBinDir != "" {
		candidates = append(candidates, filepath.Join(artifactBinDir, IDEHelperName()))
	}
	for _, path := range candidates {
		info, err := os.Stat(path)
		if err == nil && info.Mode().IsRegular() {
			return filepath.Abs(path)
		}
	}
	return "", ErrIDEHelperMissing
}
