//go:build !windows

package toolchain

import "os"

func publishProtectedFile(temporary, target string, check func() error) error {
	if err := check(); err != nil {
		return err
	}
	return os.Rename(temporary, target)
}
