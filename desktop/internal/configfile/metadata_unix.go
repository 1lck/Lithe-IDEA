//go:build darwin || linux

package configfile

import (
	"os"
	"syscall"
)

func copyNativeMetadata(source, target *os.File) error {
	info, err := source.Stat()
	if err != nil {
		return err
	}
	targetInfo, err := target.Stat()
	if err != nil {
		return err
	}
	original := info.Sys().(*syscall.Stat_t)
	prepared := targetInfo.Sys().(*syscall.Stat_t)
	if original.Uid != prepared.Uid || original.Gid != prepared.Gid {
		if err := target.Chown(int(original.Uid), int(original.Gid)); err != nil {
			return err
		}
	}
	if err := target.Chmod(info.Mode()); err != nil {
		return err
	}
	return copyExtendedMetadata(source, target)
}
