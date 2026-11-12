//go:build linux

package documentio

import (
	"errors"
	"fmt"
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

func openDocument(path string) (*os.File, os.FileInfo, fileIdentity, error) {
	fd, err := unix.Open(path, unix.O_RDWR|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		if errors.Is(err, unix.ELOOP) {
			return nil, nil, fileIdentity{}, ErrSymbolicLink
		}
		return nil, nil, fileIdentity{}, &os.PathError{Op: "open", Path: path, Err: err}
	}
	file := os.NewFile(uintptr(fd), path)
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, nil, fileIdentity{}, err
	}
	if !info.Mode().IsRegular() {
		file.Close()
		return nil, nil, fileIdentity{}, ErrNotRegular
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		file.Close()
		return nil, nil, fileIdentity{}, ErrNotRegular
	}
	return file, info, fileIdentity{links: uint64(stat.Nlink), id: fmt.Sprintf("%d:%d", stat.Dev, stat.Ino)}, nil
}

func copyMetadata(source, dest *os.File, info os.FileInfo) error {
	// Preserve mode and xattrs, including POSIX ACLs. If a filesystem rejects an
	// attribute, fail rather than replacing the source with incomplete metadata.
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return errors.New("missing document ownership")
	}
	var stage unix.Stat_t
	if err := unix.Fstat(int(dest.Fd()), &stage); err != nil {
		return err
	}
	if stage.Uid != stat.Uid || stage.Gid != stat.Gid {
		if err := unix.Fchown(int(dest.Fd()), int(stat.Uid), int(stat.Gid)); err != nil {
			return err
		}
	}
	if err := unix.Fchmod(int(dest.Fd()), stat.Mode&07777); err != nil {
		return err
	}
	fd, dst := int(source.Fd()), int(dest.Fd())
	size, err := unix.Flistxattr(fd, nil)
	if err != nil {
		return err
	}
	names := make([]byte, size)
	if size > 0 {
		size, err = unix.Flistxattr(fd, names)
		if err != nil {
			return err
		}
		names = names[:size]
	}
	for len(names) > 0 {
		end := 0
		for end < len(names) && names[end] != 0 {
			end++
		}
		if end == len(names) {
			return errors.New("invalid xattr list")
		}
		name := string(names[:end])
		names = names[end+1:]
		length, err := unix.Fgetxattr(fd, name, nil)
		if err != nil {
			return err
		}
		value := make([]byte, length)
		if length > 0 {
			length, err = unix.Fgetxattr(fd, name, value)
			if err != nil {
				return err
			}
			value = value[:length]
		}
		if err = unix.Fsetxattr(dst, name, value, 0); err != nil {
			return err
		}
	}
	return nil
}

func replaceDocument(stage, target string) error { return os.Rename(stage, target) }

func installMissingDocument(stage, target string) error {
	return unix.Renameat2(unix.AT_FDCWD, stage, unix.AT_FDCWD, target, unix.RENAME_NOREPLACE)
}
