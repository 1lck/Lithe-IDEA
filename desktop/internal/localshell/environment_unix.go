//go:build !windows

package localshell

import "strings"

// shellLocale is the locale a local shell starts in when the environment it
// inherits names none. It changes the character type only: messages, collation
// and number and date formatting stay those of the C locale, which is what the
// shell would otherwise get.
const shellLocale = "C.UTF-8"

// withUTF8Locale returns the environment a local shell starts in. A program
// opened from Finder or a desktop launcher is given no locale at all, so the C
// locale reaches the shell, and the tools it runs cannot tell a non-ASCII name
// from control characters: macOS ls prints "?" for every Chinese character of a
// file name. A shell whose environment names a locale is left alone: the user
// chose it, and a non-UTF-8 session can still be switched to UTF-8 explicitly.
func withUTF8Locale(environment []string) []string {
	named := false
	result := make([]string, 0, len(environment)+1)
	for _, entry := range environment {
		name, value, _ := strings.Cut(entry, "=")
		if name == "LC_ALL" || name == "LC_CTYPE" || name == "LANG" {
			if value == "" {
				continue // an empty setting selects the C locale: treat it as absent
			}
			named = true
		}
		result = append(result, entry)
	}
	if named {
		return result
	}
	return append(result, "LANG="+shellLocale)
}
