// Package winpath compares Windows paths whose text differs by 8.3 short names, path separators
// or letter case.
//
// A Windows process may see the same path as C:\Users\RUNNER~1\src\main.txt, as
// C:/Users/RUNNER~1/src/main.txt or as C:\Users\runneradmin\src\main.txt, depending on whether it
// came from an environment variable, a forward-slash join or a program that resolved it. Tests
// that compare such paths by text fail on a runner whose user name is longer than eight
// characters, so they compare long forms with one separator and one case.
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

// Equal reports whether a and b name the same path: compared in their long forms, with one
// separator and one case.
func Equal(a, b string) bool {
	if a == b {
		return true
	}
	return equal(Long(a), Long(b))
}
