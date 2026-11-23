// Package atomicfile installs immutable application resources using one atomic
// replacement policy. The target and its temporary file are in the same folder.
package atomicfile

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
)

// Install leaves an existing regular file with matching bytes untouched. A
// different or absent file is replaced with a synced temporary file with perm.
// A concurrent installer winning a Windows rename race is also accepted, but
// only when the resulting target holds the requested bytes.
func Install(path string, data []byte, perm os.FileMode) error {
	if holds(path, data) {
		return nil
	}
	err := Write(path, data, perm)
	if err != nil && holds(path, data) {
		return nil
	}
	return err
}

// Write atomically replaces path. A failure cannot leave a partial target or a
// leftover temporary file; all bytes and permissions are synced before rename.
func Write(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create directory: %w", err)
	}
	f, err := os.CreateTemp(dir, "."+filepath.Base(path)+".*")
	if err != nil {
		return fmt.Errorf("create temporary file: %w", err)
	}
	temporary := f.Name()
	defer os.Remove(temporary)
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return fmt.Errorf("write temporary file: %w", err)
	}
	if err := f.Chmod(perm); err != nil {
		_ = f.Close()
		return fmt.Errorf("set temporary file permissions: %w", err)
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return fmt.Errorf("sync temporary file: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("close temporary file: %w", err)
	}
	if err := os.Rename(temporary, path); err != nil {
		return fmt.Errorf("replace file: %w", err)
	}
	return nil
}

func holds(path string, data []byte) bool {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() != int64(len(data)) {
		return false
	}
	existing, err := os.ReadFile(path)
	return err == nil && bytes.Equal(existing, data)
}
