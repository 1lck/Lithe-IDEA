//go:build !windows

package keymapimport

import (
	"os"
	"syscall"
)

// Nonblocking open prevents a file-to-FIFO replacement from hanging before fstat.
func openSelectedSource(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
}
