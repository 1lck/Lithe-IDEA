// Package idehelp carries the lithe-mcp stdio helper inside the client binary and installs it
// below the client's own application-data directory.
//
// The helper is a Rust executable built by the desktop packaging step from the pinned Core
// revision. It is embedded at build time (build tag lithe_bundled_helper) instead of being
// copied beside the client: the installed app bundle and installation directory stay
// byte-identical, the client never has to locate its own executable, and the copy that runs
// lives in a writable user-data directory together with the IDE connection descriptors.
package idehelp

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// ErrNotBundled means this build has no embedded helper: development builds without the
// packaging tag have none, and the IDE Connection page shows the helper as missing.
var ErrNotBundled = errors.New("this build does not embed the lithe-mcp helper")

// installBytes is the embedded helper. A test replaces it to exercise installation without a
// Rust binary; production always reads the embedded file.
var installBytes = bundled

// Install makes the bundled helper available below dir and returns its absolute path. An
// existing file with the same bytes is reused, so a client start does not rewrite it. A file
// with other bytes (a stale helper from another release) is replaced atomically; a partial
// file is never left where a later run could execute it. The file is private and executable
// by the user only.
func Install(dir, name string) (string, error) {
	data := installBytes()
	if len(data) == 0 {
		return "", ErrNotBundled
	}
	if name == "" {
		return "", errors.New("idehelp: the helper needs a file name")
	}
	bin := filepath.Join(dir, "bin")
	target := filepath.Join(bin, name)
	want := sha256.Sum256(data)
	if info, err := os.Stat(target); err == nil && info.Mode().IsRegular() {
		if existing, err := os.ReadFile(target); err == nil && sha256.Sum256(existing) == want {
			return target, nil
		}
	}
	if err := os.MkdirAll(bin, 0o700); err != nil {
		return "", fmt.Errorf("create the helper directory: %w", err)
	}
	temporary, err := os.CreateTemp(bin, "."+name+".*")
	if err != nil {
		return "", fmt.Errorf("create the helper file: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath) // no-op once the rename succeeded
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return "", fmt.Errorf("write the helper: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return "", fmt.Errorf("sync the helper: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return "", fmt.Errorf("close the helper: %w", err)
	}
	if err := os.Chmod(temporaryPath, 0o700); err != nil {
		return "", fmt.Errorf("make the helper executable: %w", err)
	}
	if err := os.Rename(temporaryPath, target); err != nil {
		return "", fmt.Errorf("install the helper: %w", err)
	}
	return target, nil
}
