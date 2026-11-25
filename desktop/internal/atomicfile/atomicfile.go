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
	if err := validateTargetPath(path); err != nil {
		return err
	}
	if rename == nil {
		rename = os.Rename
	}
	if holds(path, data) {
		return nil
	}
	return writeWithRename(path, perm, func(w io.Writer) error {
		_, err := w.Write(data)
		return err
	}, rename, nil, func() bool {
		return holds(path, data)
	})
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
	return WriteWithCheck(path, perm, write, nil)
}

// WriteWithCheck provides a last check immediately before rename, after the
// temporary file has been synced and closed. Runtime downloads use ctx.Err so
// cancellation after a slow fsync cannot publish an unwanted archive.
func WriteWithCheck(path string, perm os.FileMode, write func(io.Writer) error, beforeRename func() error) error {
	return writeWithRename(path, perm, write, os.Rename, beforeRename, nil)
}

func validateTargetPath(path string) error {
	if path == "" {
		return errors.New("atomicfile: empty path")
	}
	base := filepath.Base(path)
	if base == "." || base == ".." || base == string(filepath.Separator) {
		return fmt.Errorf("atomicfile: invalid target path %q", path)
	}
	return nil
}

func writeWithRename(path string, perm os.FileMode, write func(io.Writer) error, rename func(string, string) error, beforeRename func() error, acceptOnRenameError func() bool) (err error) {
	if err := validateTargetPath(path); err != nil {
		return err
	}
	if write == nil {
		return errors.New("atomicfile: nil writer callback")
	}
	if rename == nil {
		rename = os.Rename
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create directory: %w", err)
	}
	f, err := os.CreateTemp(dir, "."+filepath.Base(path)+".*")
	if err != nil {
		return fmt.Errorf("create temporary file: %w", err)
	}
	temp := f.Name()
	closed := false
	defer func() {
		if !closed {
			if closeErr := f.Close(); closeErr != nil {
				err = errors.Join(err, fmt.Errorf("close temporary file: %w", closeErr))
			}
		}
		// log-exempt: 预期的缺失：成功改名已移走本次独占临时文件。
		if cleanup := os.Remove(temp); cleanup != nil && !errors.Is(cleanup, os.ErrNotExist) {
			err = errors.Join(err, fmt.Errorf("remove temporary file: %w", cleanup))
		}
	}()
	if err := write(f); err != nil {
		return fmt.Errorf("write temporary file: %w", err)
	}
	if err := f.Chmod(perm); err != nil {
		return fmt.Errorf("set temporary file permissions: %w", err)
	}
	if err := f.Sync(); err != nil {
		return fmt.Errorf("sync temporary file: %w", err)
	}
	closed = true
	if err := f.Close(); err != nil {
		return fmt.Errorf("close temporary file: %w", err)
	}
	if beforeRename != nil {
		if err := beforeRename(); err != nil {
			return fmt.Errorf("check before replace: %w", err)
		}
	}
	if err := rename(temp, path); err != nil {
		if acceptOnRenameError != nil && acceptOnRenameError() {
			return nil
		}
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
