package projectgen

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// errEscape reports a plan path that is not a plain relative path below the
// directory it is written into.
var errEscape = errors.New("projectgen: the path leaves the project directory")

// splitRelative validates a slash-separated project-relative path. Core already
// checked it; this is the second line, because the host performs the write.
func splitRelative(path string) ([]string, error) {
	if path == "" || strings.ContainsRune(path, 0) || strings.Contains(path, "\\") ||
		strings.HasPrefix(path, "/") || filepath.IsAbs(path) || filepath.VolumeName(path) != "" {
		return nil, fmt.Errorf("%w: %q", errEscape, path)
	}
	segments := strings.Split(path, "/")
	for _, segment := range segments {
		if segment == "" || segment == "." || segment == ".." || strings.Contains(segment, ":") {
			return nil, fmt.Errorf("%w: %q", errEscape, path)
		}
	}
	return segments, nil
}

// ensureDirectory creates the directory chain of segments below root one
// component at a time and refuses to pass through a symbolic link or a file, so
// a link planted by an earlier command step cannot redirect a later write.
func ensureDirectory(root string, segments []string) (string, error) {
	current := root
	for _, segment := range segments {
		next := filepath.Join(current, segment)
		info, err := os.Lstat(next)
		switch {
		case errors.Is(err, os.ErrNotExist):
			if err := os.Mkdir(next, 0o755); err != nil {
				return "", err
			}
		case err != nil:
			return "", err
		case info.Mode()&os.ModeSymlink != 0:
			return "", fmt.Errorf("%w: %s is a symbolic link", errEscape, next)
		case !info.IsDir():
			return "", fmt.Errorf("projectgen: %s is not a directory", next)
		}
		current = next
	}
	return current, nil
}

// writeFile writes one planned file below root. The bytes go to a sibling
// temporary file that is renamed into place, so an interrupted write never
// leaves a half-written project file.
func writeFile(root, path, contents string, executable bool) error {
	segments, err := splitRelative(path)
	if err != nil {
		return err
	}
	directory, err := ensureDirectory(root, segments[:len(segments)-1])
	if err != nil {
		return err
	}
	target := filepath.Join(directory, segments[len(segments)-1])
	if info, err := os.Lstat(target); err == nil {
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("%w: %s is a symbolic link", errEscape, target)
		}
		if info.IsDir() {
			return fmt.Errorf("projectgen: %s is a directory", target)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	temporary, err := os.CreateTemp(directory, ".lithe-write-*")
	if err != nil {
		return err
	}
	name := temporary.Name()
	cleanup := func() { _ = os.Remove(name) }
	if _, err := temporary.WriteString(contents); err != nil {
		_ = temporary.Close()
		cleanup()
		return err
	}
	mode := os.FileMode(0o644)
	if executable {
		mode = 0o755
	}
	if err := temporary.Chmod(mode); err != nil {
		_ = temporary.Close()
		cleanup()
		return err
	}
	if err := temporary.Close(); err != nil {
		cleanup()
		return err
	}
	if err := os.Rename(name, target); err != nil {
		cleanup()
		return err
	}
	return nil
}

// collectDirectory moves the contents of the subdirectory a scaffolding tool
// created up into root, as a step's collect asks. The subdirectory is renamed
// out of the way first, so a child named like it cannot collide with it.
func collectDirectory(root, path string) error {
	segments, err := splitRelative(path)
	if err != nil {
		return err
	}
	source := root
	for _, segment := range segments {
		source = filepath.Join(source, segment)
		info, err := os.Lstat(source)
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return fmt.Errorf("%w: %s is not a plain directory", errEscape, source)
		}
	}
	parked, err := os.MkdirTemp(root, ".lithe-collect-*")
	if err != nil {
		return err
	}
	moved := filepath.Join(parked, "source")
	if err := os.Rename(source, moved); err != nil {
		_ = os.Remove(parked)
		return err
	}
	entries, err := os.ReadDir(moved)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		destination := filepath.Join(root, entry.Name())
		if _, err := os.Lstat(destination); err == nil {
			return fmt.Errorf("projectgen: %s already exists in the project root", entry.Name())
		}
		if err := os.Rename(filepath.Join(moved, entry.Name()), destination); err != nil {
			return err
		}
	}
	return os.RemoveAll(parked)
}
