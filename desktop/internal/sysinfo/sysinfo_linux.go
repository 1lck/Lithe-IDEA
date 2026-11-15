package sysinfo

import (
	"os"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

const osName = "Linux"

// Version is the kernel's release.
func Version() string {
	var name unix.Utsname
	if unix.Uname(&name) != nil {
		return ""
	}
	return unix.ByteSliceToString(name.Release[:])
}

// residentBytes reads the second field of /proc/self/statm, the resident pages.
func residentBytes() uint64 {
	data, err := os.ReadFile("/proc/self/statm")
	if err != nil {
		return 0
	}
	fields := strings.Fields(string(data))
	if len(fields) < 2 {
		return 0
	}
	pages, err := strconv.ParseUint(fields[1], 10, 64)
	if err != nil {
		return 0
	}
	return pages * uint64(os.Getpagesize())
}

func diskFree(volume string) uint64 {
	var stat unix.Statfs_t
	if volume == "" || unix.Statfs(volume, &stat) != nil {
		return 0
	}
	return stat.Bavail * uint64(stat.Bsize)
}
