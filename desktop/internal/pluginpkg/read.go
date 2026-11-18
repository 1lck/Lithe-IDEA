package pluginpkg

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

var (
	// ErrNotPackageFile reports a package path that leads through a symbolic link
	// at some level, or to something other than a regular file.
	ErrNotPackageFile = errors.New("plugin package path is not a regular package file")
	// ErrReadTooLarge reports a package file over the reader's limit.
	ErrReadTooLarge = errors.New("plugin package file exceeds the read limit")
)

// ReadFile reads the file of the installed package at root that segments name,
// following no symbolic link at any level, and at most limit bytes. Installed
// packages are read-only at runtime; this opens the file for reading only.
func ReadFile(root string, segments []string, limit int64) ([]byte, error) {
	if len(segments) == 0 {
		return nil, ErrNotPackageFile
	}
	path := root
	var info os.FileInfo
	for _, segment := range segments {
		path = filepath.Join(path, segment)
		var err error
		info, err = os.Lstat(path)
		if err != nil {
			return nil, err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return nil, ErrNotPackageFile
		}
	}
	// Opening a FIFO or device would block or reach outside the package.
	if !info.Mode().IsRegular() {
		return nil, ErrNotPackageFile
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return nil, err
	}
	linked, err := os.Lstat(path)
	// The file must still be the regular file checked above, not one a
	// concurrent change put in its place.
	if err != nil || !opened.Mode().IsRegular() || !os.SameFile(opened, linked) {
		return nil, ErrNotPackageFile
	}
	if opened.Size() > limit {
		return nil, fmt.Errorf("%w: %d bytes, limit %d", ErrReadTooLarge, opened.Size(), limit)
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("%w: limit %d", ErrReadTooLarge, limit)
	}
	return data, nil
}
