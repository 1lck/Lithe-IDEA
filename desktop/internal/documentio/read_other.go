//go:build !darwin && !windows && !linux

package documentio

import "os"

func openReadable(string) (*os.File, os.FileInfo, error) { return nil, nil, ErrUnsupported }
