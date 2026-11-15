package toolchain

import (
	"context"
	"errors"
	"os"
)

// directoryIdentity eagerly reads the native file ID. Windows os.Stat can defer
// that read until SameFile and then accidentally reopen a replacement pathname.
func directoryIdentity(ctx context.Context, path string) (info os.FileInfo, err error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	root, err := os.OpenRoot(path)
	if err != nil {
		return nil, err
	}
	defer func() { err = errors.Join(err, root.Close()) }()
	info, err = root.Stat(".")
	if err != nil {
		return nil, err
	}
	return info, ctx.Err()
}

func checkDirectoryIdentity(ctx context.Context, path string, expected os.FileInfo) error {
	if expected == nil {
		return ErrPinConflict
	}
	current, err := directoryIdentity(ctx, path)
	if err != nil {
		return errors.Join(ErrPinConflict, err)
	}
	if !os.SameFile(expected, current) {
		return ErrPinConflict
	}
	return nil
}

// CheckWorkspace accepts aliases of the captured directory, but refuses a new
// directory at the old path or a different active project. It performs native
// I/O and belongs on the settings worker.
func (s Snapshot) CheckWorkspace(ctx context.Context, currentRoot string) error {
	if err := checkDirectoryIdentity(ctx, s.Root, s.rootIdentity); err != nil {
		return err
	}
	return checkDirectoryIdentity(ctx, currentRoot, s.rootIdentity)
}
