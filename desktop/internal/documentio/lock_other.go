//go:build !darwin && !linux && !windows

package documentio

import "os"

func lockShared(*os.File) (func(), error) { return nil, ErrUnsupported }
