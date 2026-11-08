//go:build darwin

package documentio

/*
#include <copyfile.h>
#include <errno.h>
static int copy_metadata(int from, int to) {
    if (fcopyfile(from, to, NULL, COPYFILE_METADATA) != 0) return errno;
    return 0;
}
*/
import "C"

import (
	"errors"
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

func openDocument(path string) (*os.File, os.FileInfo, error) {
	fd, err := unix.Open(path, unix.O_RDWR|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		if errors.Is(err, unix.ELOOP) {
			return nil, nil, ErrSymbolicLink
		}
		return nil, nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	file := os.NewFile(uintptr(fd), path)
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, nil, err
	}
	if !info.Mode().IsRegular() {
		file.Close()
		return nil, nil, ErrNotRegular
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Nlink != 1 {
		file.Close()
		return nil, nil, ErrHardLink
	}
	return file, info, nil
}

func copyMetadata(source, dest *os.File, _ os.FileInfo) error {
	if code := C.copy_metadata(C.int(source.Fd()), C.int(dest.Fd())); code != 0 {
		return syscall.Errno(code)
	}
	return nil
}

func replaceDocument(stage, target string) error { return os.Rename(stage, target) }

func installMissingDocument(stage, target string) error {
	return unix.RenameatxNp(unix.AT_FDCWD, stage, unix.AT_FDCWD, target, unix.RENAME_EXCL)
}
