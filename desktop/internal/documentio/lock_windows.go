//go:build windows

package documentio

import (
	"os"

	"golang.org/x/sys/windows"
)

// lockShared takes an exclusive lock on the whole file for an in-place write.
func lockShared(file *os.File) (func(), error) {
	handle := windows.Handle(file.Fd())
	overlapped := new(windows.Overlapped)
	const whole = ^uint32(0)
	if err := windows.LockFileEx(handle, windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, whole, whole, overlapped); err != nil {
		return nil, &os.PathError{Op: "lock", Path: file.Name(), Err: err}
	}
	return func() { _ = windows.UnlockFileEx(handle, 0, whole, whole, overlapped) }, nil
}
