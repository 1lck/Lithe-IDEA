//go:build !windows

package pluginhost

import "os"

func verifyNativeExecutable(_ string, info os.FileInfo) error {
	if info.Mode().Perm()&0o111 == 0 {
		return ErrNotExecutable
	}
	return nil
}
