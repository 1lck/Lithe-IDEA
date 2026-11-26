//go:build linux

package localshell

import "golang.org/x/sys/unix"

const ioctlReadTermios = unix.TCGETS
