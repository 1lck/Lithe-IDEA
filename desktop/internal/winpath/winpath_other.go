//go:build !windows

package winpath

import "strings"

func long(p string) string  { return p }
func short(p string) string { return p }

func indexOf(text, p string) int { return strings.Index(text, p) }
