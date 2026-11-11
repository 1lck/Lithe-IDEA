//go:build darwin || linux

package documentio

import (
	"os"

	"golang.org/x/sys/unix"
)

// lockShared takes an exclusive advisory lock on the file for an in-place write. Writers
// that do not lock are not held off.
func lockShared(file *os.File) (func(), error) {
	fd := int(file.Fd())
	if err := unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB); err != nil {
		return nil, &os.PathError{Op: "lock", Path: file.Name(), Err: err}
	}
	return func() { _ = unix.Flock(fd, unix.LOCK_UN) }, nil
}
