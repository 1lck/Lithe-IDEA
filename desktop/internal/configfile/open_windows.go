package configfile

import "os"

func openSource(root *os.Root, name string, writable bool) (*os.File, error) {
	flags := os.O_RDONLY
	if writable {
		flags = os.O_RDWR
	}
	return root.OpenFile(name, flags, 0)
}
