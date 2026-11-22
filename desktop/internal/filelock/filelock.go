// Package filelock owns the native, process-scoped locks for writable caches.
package filelock

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"time"
)

// ErrInvalidFile means the lock path does not name the opened regular file.
var ErrInvalidFile = errors.New("lock path is not a regular file")

// Acquire uses an OS lock, not a pid or timestamp lease: process death releases
// ownership automatically. The file stays in place so another opener cannot
// lock a different inode while a previous waiter still holds the old one. The
// caller bounds the wait through ctx.
func Acquire(ctx context.Context, name string) (unlock func() error, err error) {
	defer func() {
		if err != nil && unlock != nil {
			err = errors.Join(err, unlock())
			unlock = nil
		}
	}()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	root, err := os.OpenRoot(filepath.Dir(name))
	if err != nil {
		return nil, err
	}
	defer func() { err = errors.Join(err, root.Close()) }()
	base := filepath.Base(name)
	file, err := root.OpenFile(base, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	owned := false
	defer func() {
		if !owned {
			err = errors.Join(err, file.Close())
		}
	}()
	info, err := root.Lstat(base)
	if err != nil {
		return nil, err
	}
	opened, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || !os.SameFile(info, opened) {
		return nil, ErrInvalidFile
	}
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		locked, err := tryLock(file)
		if err != nil {
			return nil, err
		}
		if locked {
			owned = true
			return file.Close, nil
		}
		// Native advisory locks have no cross-platform cancellable wait. The
		// bounded timer performs no filesystem scanning and owns no goroutine.
		timer := time.NewTimer(100 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil, ctx.Err()
		case <-timer.C:
		}
	}
}
