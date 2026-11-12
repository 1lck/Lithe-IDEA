//go:build windows

package winpath

import (
	"strings"

	"golang.org/x/sys/windows"
)

func long(p string) string {
	if expanded, ok := call(windows.GetLongPathName, p); ok {
		return expanded
	}
	return p
}

// short shortens each existing component. A path that does not exist has no short form, so the
// call fails and the long form stays for the caller's comparison.
func short(p string) string {
	if shortened, ok := call(windows.GetShortPathName, p); ok {
		return shortened
	}
	return p
}

func indexOf(text, p string) int { return strings.Index(strings.ToLower(text), strings.ToLower(p)) }

// call runs one of the KERNEL32 path conversions, which take and return UTF-16 buffers. A buffer
// that is too small answers the length it needs, so the call retries once with that size: paths on
// Windows are not limited to MAX_PATH.
func call(fn func(*uint16, *uint16, uint32) (uint32, error), p string) (string, bool) {
	in, err := windows.UTF16PtrFromString(p)
	if err != nil {
		return "", false
	}
	size := uint32(windows.MAX_PATH)
	for attempt := 0; attempt < 2; attempt++ {
		buf := make([]uint16, size)
		n, err := fn(in, &buf[0], size)
		if err != nil || n == 0 {
			return "", false
		}
		if n > size {
			size = n + 1
			continue
		}
		return windows.UTF16ToString(buf[:n]), true
	}
	return "", false
}
