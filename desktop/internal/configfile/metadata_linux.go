package configfile

import (
	"errors"
	"os"
	"strings"

	"golang.org/x/sys/unix"
)

func copyExtendedMetadata(source, target *os.File) error {
	sourceRaw, err := source.SyscallConn()
	if err != nil {
		return err
	}
	targetRaw, err := target.SyscallConn()
	if err != nil {
		return err
	}
	var operationErr, targetControlErr error
	err = sourceRaw.Control(func(sourceFD uintptr) {
		targetControlErr = targetRaw.Control(func(targetFD uintptr) {
			operationErr = copyLinuxAttributes(int(sourceFD), int(targetFD))
		})
	})
	return errors.Join(err, targetControlErr, operationErr)
}

func copyLinuxAttributes(sourceFD, targetFD int) error {
	length, err := unix.Flistxattr(sourceFD, nil)
	// log-exempt: 预期的缺失：不支持扩展属性的文件系统没有可复制的属性。
	if errors.Is(err, unix.ENOTSUP) {
		return nil
	}
	if err != nil {
		return err
	}
	// Native Linux attribute lists and individual values are limited to 64 KiB.
	const maximumAttributeBytes = 65536
	if length > maximumAttributeBytes {
		return ErrTooLarge
	}
	if length == 0 {
		return nil
	}
	names := make([]byte, length)
	length, err = unix.Flistxattr(sourceFD, names)
	if err != nil {
		return err
	}
	for _, name := range strings.Split(string(names[:length]), "\x00") {
		if name == "" {
			continue
		}
		size, err := unix.Fgetxattr(sourceFD, name, nil)
		if err != nil {
			return err
		}
		if size > maximumAttributeBytes {
			return ErrTooLarge
		}
		value := make([]byte, size)
		if size > 0 {
			size, err = unix.Fgetxattr(sourceFD, name, value)
			if err != nil {
				return err
			}
		}
		if err := unix.Fsetxattr(targetFD, name, value[:size], 0); err != nil {
			return err
		}
	}
	return nil
}
