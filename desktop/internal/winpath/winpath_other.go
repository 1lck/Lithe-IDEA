//go:build !windows

package winpath

func long(p string) string   { return p }
func short(p string) string  { return p }
func equal(a, b string) bool { return a == b }
