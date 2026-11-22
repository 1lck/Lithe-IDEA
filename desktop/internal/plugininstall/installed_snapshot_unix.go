//go:build unix

package plugininstall

import "syscall"

// A replaced package entry must never block an open if it became a FIFO.
const snapshotReadFlags = syscall.O_RDONLY | syscall.O_NONBLOCK | syscall.O_NOFOLLOW
