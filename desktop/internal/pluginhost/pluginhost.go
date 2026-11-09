// Package pluginhost applies this client's plugin policy to a package on disk.
//
// It deliberately does not import the Core bridge. The interface it declares
// uses only JSON and the standard library, so *core.Client satisfies it
// directly while this policy stays testable without a C toolchain. Work that
// needs Core's own types — the launch plan and the start request — is assembled
// by the caller that already speaks to Core.
//
// Two rules live here, and both are refusals rather than conveniences:
//
// A manifest is validated against the capabilities this client actually
// implements, so a plugin that needs an unwired capability is rejected at
// install time instead of failing when the user reaches for it.
//
// Every path a launch plan names is resolved against the installed package one
// segment at a time, refusing symbolic links at any level, so a package cannot
// point Core at a program outside itself.
package pluginhost

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

var (
	// ErrPackagePath reports a plan path that is missing, not a regular file, or
	// reached through something other than a directory inside the package.
	ErrPackagePath = errors.New("plugin package path is not usable")
	// ErrPackageSymlink reports a plan path that is, or passes through, a
	// symbolic link.
	ErrPackageSymlink = errors.New("plugin package path is a symbolic link")
	// ErrNotExecutable reports a program without an execute bit.
	ErrNotExecutable = errors.New("plugin program is not executable")
	// ErrCapabilityNotDeclared reports a capability set this client cannot serve.
	ErrCapabilityNotDeclared = errors.New("plugin capability is not implemented by this client")
)

// ManifestValidator is the part of the Core client this package needs. It is
// satisfied by *core.Client.
type ManifestValidator interface {
	ValidatePluginManifest(ctx context.Context, manifest json.RawMessage, capabilities map[string][]int) (json.RawMessage, error)
}

// Capabilities lists the contract capability versions this client implements, in
// the shape Core expects: capability name to the versions served.
type Capabilities map[string][]int

// Declared is what this client can serve today.
//
// It is deliberately empty. Extracting, installing and approving a package is
// implemented, but no editor, user interface, backend, build or debug capability
// is wired yet. Claiming one here would let a plugin install and then fail the
// first time a user reaches for the feature, which is exactly what the contract's
// capability negotiation exists to prevent.
func Declared() Capabilities {
	return Capabilities{}
}

// Clone returns a copy callers may modify without touching the original.
func (c Capabilities) Clone() Capabilities {
	cloned := make(Capabilities, len(c))
	for name, versions := range c {
		cloned[name] = append([]int(nil), versions...)
	}
	return cloned
}

// With returns a copy of c that additionally serves one capability version.
func (c Capabilities) With(name string, versions ...int) Capabilities {
	cloned := c.Clone()
	cloned[name] = append(cloned[name], versions...)
	sort.Ints(cloned[name])
	return cloned
}

// Validate normalises manifest and refuses any capability this client does not
// implement. The returned manifest is Core's normalised form; every later call
// must use it rather than the bytes read from disk.
func Validate(ctx context.Context, validator ManifestValidator, manifest json.RawMessage, capabilities Capabilities) (json.RawMessage, error) {
	if validator == nil {
		return nil, errors.New("pluginhost: no manifest validator")
	}
	normalised, err := validator.ValidatePluginManifest(ctx, manifest, capabilities.Clone())
	if err != nil {
		return nil, err
	}
	if len(normalised) == 0 {
		return nil, errors.New("pluginhost: the validator returned no manifest")
	}
	return normalised, nil
}

// ResolvePackagePath resolves a package-relative path against an installed
// package and proves it stays inside it.
//
// Every ancestor must be a real directory and the file itself must be a regular
// file. A symbolic link at any level is refused, because a link in the middle of
// a path would make a later segment resolve outside the package even though the
// path itself looks relative.
func ResolvePackagePath(packageDirectory, name string) (string, error) {
	return resolve(packageDirectory, name, false)
}

// ResolveExecutable is ResolvePackagePath for a program a launch plan will start.
// The file must also carry an execute bit.
func ResolveExecutable(packageDirectory, name string) (string, error) {
	return resolve(packageDirectory, name, true)
}

// ResolvePackagePaths resolves every path a launch plan names, in order.
func ResolvePackagePaths(packageDirectory string, required []string) ([]string, error) {
	resolved := make([]string, 0, len(required))
	for _, name := range required {
		path, err := ResolvePackagePath(packageDirectory, name)
		if err != nil {
			return nil, err
		}
		resolved = append(resolved, path)
	}
	return resolved, nil
}

func resolve(packageDirectory, name string, executable bool) (string, error) {
	if packageDirectory == "" || !filepath.IsAbs(packageDirectory) {
		return "", fmt.Errorf("%w: the package directory must be an absolute path", ErrPackagePath)
	}
	clean, err := pluginpkg.ValidatePath(name)
	if err != nil {
		return "", fmt.Errorf("%w: %w", ErrPackagePath, err)
	}
	segments := splitPath(clean)
	current := packageDirectory
	for i, segment := range segments {
		current = filepath.Join(current, segment)
		last := i == len(segments)-1
		info, statErr := os.Lstat(current)
		if errors.Is(statErr, os.ErrNotExist) {
			return "", fmt.Errorf("%w: %q does not exist", ErrPackagePath, name)
		}
		if statErr != nil {
			return "", statErr
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return "", fmt.Errorf("%w: %q", ErrPackageSymlink, name)
		}
		if last {
			if !info.Mode().IsRegular() {
				return "", fmt.Errorf("%w: %q is not a regular file", ErrPackagePath, name)
			}
			if executable && info.Mode().Perm()&0o111 == 0 {
				return "", fmt.Errorf("%w: %q", ErrNotExecutable, name)
			}
			continue
		}
		if !info.IsDir() {
			return "", fmt.Errorf("%w: %q passes through a file", ErrPackagePath, name)
		}
	}
	return current, nil
}

// splitPath splits a validated package-relative path into its segments.
func splitPath(name string) []string {
	var segments []string
	start := 0
	for i := 0; i < len(name); i++ {
		if name[i] == '/' {
			segments = append(segments, name[start:i])
			start = i + 1
		}
	}
	return append(segments, name[start:])
}
