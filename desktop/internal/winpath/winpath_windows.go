//go:build windows

package winpath

import (
	"strings"

	"golang.org/x/sys/windows"
)

func long(p string) string {
	if expanded, err := windows.GetLongPathName(p); err == nil && expanded != "" {
		return expanded
	}
	return p
}

// short shortens each existing component. GetShortPathName needs the path to exist, so a missing
// path keeps its own text and the comparison falls back to the long form.
func short(p string) string {
	if shortened, err := windows.GetShortPathName(p); err == nil && shortened != "" {
		return shortened
	}
	return p
}

func indexOf(text, p string) int { return strings.Index(strings.ToLower(text), strings.ToLower(p)) }
