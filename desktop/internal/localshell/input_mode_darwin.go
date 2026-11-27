//go:build darwin

package localshell

import "golang.org/x/sys/unix"

const ioctlReadTermios = unix.TIOCGETA
