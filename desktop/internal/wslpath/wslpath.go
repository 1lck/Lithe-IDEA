// Package wslpath recognizes WSL paths and converts between Lithe's wsl:// form and the Windows
// network forms of a distribution (\\wsl$\<distro>\... and \\wsl.localhost\<distro>\...). It also
// decides whether a move or a rename may cross a WSL boundary. Everything here is string work, so
// it runs on every platform; the operations that touch the distribution are done by the platform.
package wslpath

import (
	"errors"
	"strings"
)

// Scheme is the prefix of Lithe's own WSL path form: wsl://<distro>/<linux path>.
const Scheme = "wsl://"

// uncPrefixes are the Windows network forms of a distribution's file system, in the order they are
// recognized. Both are accepted; the one written is \\wsl.localhost, which current Windows uses.
var uncPrefixes = []string{`\\wsl.localhost\`, `\\wsl$\`}

// ErrCrossBoundary reports a move or a rename between two distributions, or between a distribution
// and a local folder. The client refuses it instead of copying across the boundary.
var ErrCrossBoundary = errors.New("moving or renaming between WSL distributions or local folders is not supported")

// Location is a path inside a WSL distribution: the distribution's name and the path on it.
type Location struct {
	Distro string
	Linux  string
}

// Parse reads a path in any WSL form. It reports false for a local path, and for a WSL form without a
// distribution name.
func Parse(path string) (Location, bool) {
	trimmed := strings.TrimSpace(path)
	if rest, ok := cutPrefixFold(trimmed, Scheme); ok {
		distro, linux, _ := strings.Cut(rest, "/")
		return location(distro, "/"+linux)
	}
	for _, prefix := range uncPrefixes {
		if rest, ok := cutPrefixFold(trimmed, prefix); ok {
			rest = strings.ReplaceAll(rest, "/", `\`)
			distro, linux, _ := strings.Cut(rest, `\`)
			return location(distro, "/"+strings.ReplaceAll(linux, `\`, "/"))
		}
	}
	return Location{}, false
}

// IsWSL reports that path is in a WSL form.
func IsWSL(path string) bool {
	_, ok := Parse(path)
	return ok
}

// location validates the distribution name and cleans the Linux path.
func location(distro, linux string) (Location, bool) {
	distro = strings.TrimSpace(distro)
	if distro == "" || strings.ContainsAny(distro, `/\`) {
		return Location{}, false
	}
	return Location{Distro: distro, Linux: cleanLinux(linux)}, true
}

// cleanLinux removes empty, "." and ".." parts of a Linux path, keeping it absolute.
func cleanLinux(linux string) string {
	var parts []string
	for _, part := range strings.Split(strings.ReplaceAll(linux, `\`, "/"), "/") {
		switch part {
		case "", ".":
		case "..":
			if len(parts) > 0 {
				parts = parts[:len(parts)-1]
			}
		default:
			parts = append(parts, part)
		}
	}
	if len(parts) == 0 {
		return "/"
	}
	return "/" + strings.Join(parts, "/")
}

// WSLURI is the wsl:// form of the location.
func (l Location) WSLURI() string {
	return Scheme + l.Distro + l.Linux
}

// UNC is the \\wsl.localhost form of the location, which Windows opens for the distribution.
func (l Location) UNC() string {
	rest := strings.ReplaceAll(strings.TrimPrefix(l.Linux, "/"), "/", `\`)
	if rest == "" {
		return uncPrefixes[0] + l.Distro
	}
	return uncPrefixes[0] + l.Distro + `\` + rest
}

// ToNative is the path a platform opens for path: a wsl:// path becomes its UNC form, and any
// other path is returned unchanged.
func ToNative(path string) string {
	if loc, ok := Parse(path); ok && strings.HasPrefix(strings.ToLower(strings.TrimSpace(path)), strings.ToLower(Scheme)) {
		return loc.UNC()
	}
	return path
}

// CheckMove decides whether a move or a rename from source to target may run. Two local paths and
// two paths in the same distribution may; a move between distributions, or between a distribution and
// a local folder, is refused with ErrCrossBoundary.
func CheckMove(source, target string) error {
	sourceLoc, sourceWSL := Parse(source)
	targetLoc, targetWSL := Parse(target)
	if !sourceWSL && !targetWSL {
		return nil
	}
	if sourceWSL && targetWSL && strings.EqualFold(sourceLoc.Distro, targetLoc.Distro) {
		return nil
	}
	return ErrCrossBoundary
}

// cutPrefixFold removes prefix from s when s starts with it, ignoring case.
func cutPrefixFold(s, prefix string) (string, bool) {
	if len(s) < len(prefix) || !strings.EqualFold(s[:len(prefix)], prefix) {
		return "", false
	}
	return s[len(prefix):], true
}
