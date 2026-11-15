//go:build !windows

package configfile

import (
	"os"
	"syscall"
)

// O_NONBLOCK prevents a file-to-FIFO replacement from hanging before fstat.
func openSource(root *os.Root, name string, writable bool) (*os.File, error) {
	flags := os.O_RDONLY | syscall.O_NONBLOCK
	if writable {
		flags = os.O_RDWR | syscall.O_NONBLOCK
	}
	return root.OpenFile(name, flags, 0)
}
