//go:build darwin || linux

package documentio

import (
	"errors"
	"golang.org/x/sys/unix"
	"os"
)

func openReadable(path string) (*os.File, os.FileInfo, error) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_NOCTTY|unix.O_CLOEXEC, 0)
	if err != nil {
		if errors.Is(err, unix.ELOOP) {
			return nil, nil, ErrSymbolicLink
		}
		return nil, nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	file := os.NewFile(uintptr(fd), path)
	info, err := file.Stat()
	if err != nil {
		return nil, nil, errors.Join(err, file.Close())
	}
	if !info.Mode().IsRegular() {
		return nil, nil, errors.Join(ErrNotRegular, file.Close())
	}
	return file, info, nil
}
