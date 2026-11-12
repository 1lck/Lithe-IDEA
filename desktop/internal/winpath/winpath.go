// Package winpath compares Windows paths whose text differs by 8.3 short names.
//
// A Windows process may see the same directory as C:\Users\RUNNER~1\... or as
// C:\Users\runneradmin\..., depending on whether the path came from an environment variable
// that was shortened or from a program that resolved it. Tests that compare such paths by text
// fail on a runner whose user name is longer than eight characters, so they compare long forms.
package winpath

// Long returns p with its 8.3 short components expanded, or p when it cannot be expanded.
func Long(p string) string {
	return long(p)
}

// Short returns p with its components shortened where Windows has a short name for them, or p
// when it cannot be shortened. A path that does not exist has no short form.
func Short(p string) string {
	return short(p)
}

// Equal reports whether a and b name the same path, comparing their long forms.
func Equal(a, b string) bool {
	if a == b {
		return true
	}
	return Long(a) == Long(b)
}

// Holds reports whether text contains p or the short form of p, for the checks that look for a
// path inside a configuration document written by another process.
func Holds(text, p string) bool {
	if holds(text, p) {
		return true
	}
	if short := Short(p); short != p {
		return holds(text, short)
	}
	return false
}

func holds(text, p string) bool {
	return len(p) > 0 && len(text) >= len(p) && indexOf(text, p) >= 0
}
