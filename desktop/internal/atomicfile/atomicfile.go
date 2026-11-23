// Package atomicfile installs immutable resources and writes owned files with
// one synced, same-directory atomic replacement policy.
package atomicfile

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// Install reuses unchanged regular files, including executables currently in use.
func Install(path string, data []byte, perm os.FileMode) error {
	return InstallWithRename(path, data, perm, os.Rename)
}

// InstallWithRename permits the caller to inject a competing installation in
// tests. A failed rename succeeds only if the destination has identical bytes.
func InstallWithRename(path string, data []byte, perm os.FileMode, rename func(string, string) error) error {
	if holds(path, data) {
		return nil
	}
	err := writeWithRename(path, perm, func(w io.Writer) error {
		_, err := w.Write(data)
		return err
	}, rename)
	if err != nil && holds(path, data) {
		return nil
	}
	return err
}

// Write atomically replaces a file with a complete byte buffer.
func Write(path string, data []byte, perm os.FileMode) error {
	return WriteWith(path, perm, func(w io.Writer) error {
		_, err := w.Write(data)
		return err
	})
}

// WriteWith streams to a private sibling and syncs it before publishing. It
// does not make a second complete copy of the buffer being written.
func WriteWith(path string, perm os.FileMode, write func(io.Writer) error) error {
	return writeWithRename(path, perm, write, os.Rename)
}

func writeWithRename(path string, perm os.FileMode, write func(io.Writer) error, rename func(string, string) error) (err error) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create directory: %w", err)
	}
	f, err := os.CreateTemp(dir, "."+filepath.Base(path)+".*")
	if err != nil {
		return fmt.Errorf("create temporary file: %w", err)
	}
	temp := f.Name()
	defer func() {
		if cleanup := os.Remove(temp); cleanup != nil && !errors.Is(cleanup, os.ErrNotExist) {
			err = errors.Join(err, fmt.Errorf("remove temporary file: %w", cleanup))
		}
	}()
	if err := write(f); err != nil {
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
	if err := rename(temp, path); err != nil {
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
