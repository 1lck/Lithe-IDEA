package pluginpkg

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	// stagingDirectory and trashDirectory are reserved names below the plugin
	// root. A directory whose name starts with a dot is never an installed
	// plugin, which is also why a plugin ID may not start with one.
	stagingDirectory = ".staging"
	trashDirectory   = ".trash"
	// StateDirectory is where the programs of installed plugins keep their
	// writable state, one directory per plugin ID; see RemoveState.
	StateDirectory = ".state"
)

// Installed is one plugin package version present in the root.
type Installed struct {
	// ID is the plugin identifier the package was installed under.
	ID string
	// Version is the package version.
	Version string
	// Path is the directory this version occupies.
	Path string
}

// Sweep removes what an interrupted install or uninstall left behind.
//
// Nothing else cleans the staging and trash areas: a process killed mid-install, or
// a delete that failed, leaves a complete extracted package there. Call it before
// any installation can start, so it never races one.
func Sweep(root string) error {
	if err := checkRoot(root); err != nil {
		return err
	}
	var failures []error
	for _, name := range []string{stagingDirectory, trashDirectory} {
		directory := filepath.Join(root, name)
		entries, err := os.ReadDir(directory)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			failures = append(failures, err)
			continue
		}
		for _, entry := range entries {
			if err := os.RemoveAll(filepath.Join(directory, entry.Name())); err != nil {
				failures = append(failures, err)
			}
		}
	}
	return errors.Join(failures...)
}

// NewStaging creates a fresh staging directory below root.
//
// It lives under the root so that Install can rename it into place atomically:
// a rename across file systems is a copy, and an interrupted copy would leave a
// partial package behind.
func NewStaging(root string) (string, error) {
	if err := checkRoot(root); err != nil {
		return "", err
	}
	staging := filepath.Join(root, stagingDirectory)
	if err := os.MkdirAll(staging, 0o700); err != nil {
		return "", err
	}
	return os.MkdirTemp(staging, "package-")
}

// Install moves the validated staging directory into root as one plugin version.
// Staging must be on the same file system as root, which it is when it was
// created below the root's staging directory, because a rename across file
// systems is a copy and would not be atomic.
//
// Install does not read the manifest, check a signature or approve execution;
// callers do that before they get here, and the archive is already extracted
// into staging by then.
func Install(root, id, version, staging string) (Installed, error) {
	if err := checkRoot(root); err != nil {
		return Installed{}, err
	}
	if err := checkIdentity("plugin ID", id); err != nil {
		return Installed{}, err
	}
	if err := checkIdentity("plugin version", version); err != nil {
		return Installed{}, err
	}
	if staging == "" || !filepath.IsAbs(staging) {
		return Installed{}, fmt.Errorf("%w: staging directory must be an absolute path", ErrUnsafePath)
	}
	target := filepath.Join(root, id, version)
	switch _, err := os.Lstat(target); {
	case err == nil:
		return Installed{}, fmt.Errorf("%w: %s", ErrPackageExists, target)
	case !errors.Is(err, fs.ErrNotExist):
		return Installed{}, err
	}
	if err := os.MkdirAll(filepath.Join(root, id), 0o700); err != nil {
		return Installed{}, err
	}
	if err := os.Rename(staging, target); err != nil {
		return Installed{}, fmt.Errorf("install %s %s: %w", id, version, err)
	}
	return Installed{ID: id, Version: version, Path: target}, nil
}

// Uninstall removes one installed plugin version from root. The plugin's state
// directory is left untouched; RemoveState removes it when the whole plugin goes.
//
// The version directory is renamed into the trash area before it is deleted, so
// a failed delete never leaves a half-removed package that still looks installed.
func Uninstall(root, id, version string) error {
	if err := checkRoot(root); err != nil {
		return err
	}
	if err := checkIdentity("plugin ID", id); err != nil {
		return err
	}
	if err := checkIdentity("plugin version", version); err != nil {
		return err
	}
	target := filepath.Join(root, id, version)
	switch _, err := os.Lstat(target); {
	case errors.Is(err, fs.ErrNotExist):
		return fmt.Errorf("%w: %s", ErrNotInstalled, target)
	case err != nil:
		return err
	}
	trash := filepath.Join(root, trashDirectory)
	if err := os.MkdirAll(trash, 0o700); err != nil {
		return err
	}
	// A unique name that does not exist yet, so the rename cannot merge into an
	// earlier failure's leftovers.
	scratch, err := os.MkdirTemp(trash, "uninstall-")
	if err != nil {
		return err
	}
	if err := os.Remove(scratch); err != nil {
		return err
	}
	if err := os.Rename(target, scratch); err != nil {
		return fmt.Errorf("uninstall %s %s: %w", id, version, err)
	}
	removeErr := os.RemoveAll(scratch)
	// The version is gone even when the delete failed, so drop the ID directory
	// instead of leaving an empty one behind. It only succeeds when it is empty.
	_ = os.Remove(filepath.Join(root, id))
	return removeErr
}

// RemoveState removes the state directory of plugin id below root, which its
// programs wrote while it was installed. The user's plugin settings live in the
// application preferences, not here. A missing directory is not an error.
//
// Like Uninstall, it renames the directory into the trash area before deleting
// it, so a failed delete never leaves half the state where a later installation
// of the plugin would read it.
func RemoveState(root, id string) error {
	if err := checkRoot(root); err != nil {
		return err
	}
	if err := checkIdentity("plugin ID", id); err != nil {
		return err
	}
	target := filepath.Join(root, StateDirectory, id)
	switch info, err := os.Lstat(target); {
	case errors.Is(err, fs.ErrNotExist):
		return nil
	case err != nil:
		return err
	case !info.IsDir():
		// Only a plugin's directory is its state; anything else below the state
		// root belongs to the host.
		return fmt.Errorf("plugin state %s is not a directory", target)
	}
	trash := filepath.Join(root, trashDirectory)
	if err := os.MkdirAll(trash, 0o700); err != nil {
		return err
	}
	scratch, err := os.MkdirTemp(trash, "state-")
	if err != nil {
		return err
	}
	if err := os.Remove(scratch); err != nil {
		return err
	}
	if err := os.Rename(target, scratch); err != nil {
		return fmt.Errorf("remove the state of %s: %w", id, err)
	}
	return os.RemoveAll(scratch)
}

// List reports every installed plugin version, ordered by ID then version.
func List(root string) ([]Installed, error) {
	if err := checkRoot(root); err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(root)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var installed []Installed
	for _, entry := range entries {
		if !entry.IsDir() || strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		versions, err := os.ReadDir(filepath.Join(root, entry.Name()))
		if err != nil {
			return nil, err
		}
		for _, version := range versions {
			if !version.IsDir() || strings.HasPrefix(version.Name(), ".") {
				continue
			}
			installed = append(installed, Installed{
				ID:      entry.Name(),
				Version: version.Name(),
				Path:    filepath.Join(root, entry.Name(), version.Name()),
			})
		}
	}
	sort.Slice(installed, func(i, j int) bool {
		if installed[i].ID != installed[j].ID {
			return installed[i].ID < installed[j].ID
		}
		return installed[i].Version < installed[j].Version
	})
	return installed, nil
}

// checkRoot refuses a root that is not an absolute path, because every directory
// this package writes is derived from it.
func checkRoot(root string) error {
	if root == "" || !filepath.IsAbs(root) {
		return fmt.Errorf("%w: plugin root must be an absolute path", ErrUnsafePath)
	}
	return nil
}

// checkIdentity refuses a plugin ID or version that cannot be a directory name.
func checkIdentity(what, value string) error {
	if value == "" {
		return fmt.Errorf("%w: empty %s", ErrInvalidIdentity, what)
	}
	if strings.HasPrefix(value, ".") {
		return fmt.Errorf("%w: %s %q starts with a dot", ErrInvalidIdentity, what, value)
	}
	if strings.ContainsAny(value, `/\`) {
		return fmt.Errorf("%w: %s %q contains a path separator", ErrInvalidIdentity, what, value)
	}
	if _, err := ValidatePath(value); err != nil {
		return fmt.Errorf("%w: %s %q is not a safe path segment", ErrInvalidIdentity, what, value)
	}
	return nil
}
