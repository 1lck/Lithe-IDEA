package pluginpkg

import (
	"fmt"
	"strings"
)

// ValidatePath reports whether name is a package-relative path this host is
// willing to write, and returns it unchanged when it is. The rules come from the
// plugin contract for the path itself, plus the constraints a package needs to
// install on a case-insensitive Windows volume.
//
// The contract also says a package may not contain symbolic links; that is a
// property of an archive entry rather than of its name, so Extract enforces it.
func ValidatePath(name string) (string, error) {
	if name == "" {
		return "", fmt.Errorf("%w: empty path", ErrUnsafePath)
	}
	if len(name) > MaxPathLength {
		return "", fmt.Errorf("%w: %d bytes, limit %d", ErrUnsafePath, len(name), MaxPathLength)
	}
	if strings.ContainsRune(name, 0) {
		return "", fmt.Errorf("%w: %q contains a NUL byte", ErrUnsafePath, name)
	}
	if strings.ContainsRune(name, '\\') {
		return "", fmt.Errorf("%w: %q contains a backslash", ErrUnsafePath, name)
	}
	if strings.HasPrefix(name, "/") {
		return "", fmt.Errorf("%w: %q is absolute", ErrUnsafePath, name)
	}
	segments := strings.Split(name, "/")
	if len(segments) > MaxPathDepth {
		return "", fmt.Errorf("%w: %q has %d segments, limit %d", ErrUnsafePath, name, len(segments), MaxPathDepth)
	}
	for _, segment := range segments {
		if err := validateSegment(name, segment); err != nil {
			return "", err
		}
	}
	return name, nil
}

func validateSegment(name, segment string) error {
	if segment == "" {
		return fmt.Errorf("%w: %q has an empty segment", ErrUnsafePath, name)
	}
	if segment == "." || segment == ".." {
		return fmt.Errorf("%w: %q has a %q segment", ErrUnsafePath, name, segment)
	}
	for _, r := range segment {
		if r < 0x20 || r == 0x7f {
			return fmt.Errorf("%w: %q has a control character", ErrUnsafePath, name)
		}
		// A colon separates a drive letter and opens an alternate data stream on
		// Windows; neither has a place in a package.
		if r == ':' {
			return fmt.Errorf("%w: %q has a colon", ErrUnsafePath, name)
		}
	}
	// Windows silently drops a trailing dot or space, so two entries that differ
	// only there would land on one name.
	if strings.HasSuffix(segment, ".") || strings.HasSuffix(segment, " ") {
		return fmt.Errorf("%w: %q has a segment ending in a dot or a space", ErrUnsafePath, name)
	}
	if isDeviceName(segment) {
		return fmt.Errorf("%w: %q names a Windows device", ErrUnsafePath, name)
	}
	return nil
}

// isDeviceName reports whether segment names a Windows character device. Such a
// name cannot be created as a file there, and the extension does not change
// that: "CON.txt" is as reserved as "CON".
func isDeviceName(segment string) bool {
	name := segment
	if dot := strings.IndexByte(name, '.'); dot >= 0 {
		name = name[:dot]
	}
	upper := strings.ToUpper(name)
	switch upper {
	case "CON", "PRN", "AUX", "NUL":
		return true
	}
	if len(upper) == 4 {
		prefix := upper[:3]
		if prefix == "COM" || prefix == "LPT" {
			return upper[3] >= '1' && upper[3] <= '9'
		}
	}
	return false
}

// foldPath returns the key a case-insensitive volume would use for name, so that
// two entries differing only in case are treated as one file.
//
// Canonically equivalent spellings of the same name (NFC and NFD) are not
// collapsed here: doing so would need a Unicode normalisation dependency the
// desktop client does not otherwise carry. A package that carries both forms
// still cannot escape its staging directory, and the per-file digests checked
// before installation would not match the bytes that survived.
func foldPath(name string) string {
	return strings.ToLower(name)
}

// parentDirectories returns the folded keys of every directory name lies in,
// nearest ancestor last. A file path "a/b/c" yields "a" and "a/b".
func parentDirectories(name string) []string {
	segments := strings.Split(name, "/")
	if len(segments) < 2 {
		return nil
	}
	parents := make([]string, 0, len(segments)-1)
	for i := 1; i < len(segments); i++ {
		parents = append(parents, foldPath(strings.Join(segments[:i], "/")))
	}
	return parents
}
