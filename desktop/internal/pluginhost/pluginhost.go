// Package pluginhost applies this client's plugin policy to a package on disk.
//
// It deliberately does not import the Core bridge. The interface it declares
// uses JSON and native file APIs, so *core.Client satisfies it
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
	// ErrNotExecutable reports a file that fails native executable validation.
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
// A plugin language needs a grammar file and a few editor delimiters, and both are
// wired: the grammar is decoded by Core and registered with the editor, and the
// delimiters reach the language's comment and bracket rules.
//
// A language server is served at versions 1 and 3. This client resolves the
// launch Core plans (a packaged program, a packaged runtime, a bare command the
// host finds on PATH, or, for serverProcess 3, the command line the plugin backend
// answers), starts the process, keeps the session's documents in step with the
// editor, and draws the diagnostics it publishes. languageServers 3 plugin-owned
// sessions are wired: the backend's languageServer/request and notify reach the
// server under Core's session policy, and didReceiveNotification and
// didChangeState reach the backend.
//
// A plugin backend (backend 1 and 2) is started on demand: when a workspace opens
// for a plugin that declares onWorkspaceOpen, when its language server needs a
// launch answer, or when another plugin calls it. It is answered the host
// services workspace/getFolders, listContexts and getContext (with
// didChangeContexts), subscriptions/dispose, the languageServer methods, the
// cross-plugin functions relay (pluginFunctions 1), credentials/get|set|delete
// (the platform secret store), documents/list and getSnapshot,
// editor/getActive, getSelections, open, reveal, insertText, replaceSelections
// and applyEdits, window/showInformation|showWarning|showError,
// browser/openExternal (http and https only), terminal/create|show|close|reopen|
// dispose|onExit, and documents/registerContentProvider. The window-bound ones
// are registered only when the window attaches (Service.AttachWorkbench), so a
// session without a window is never granted a method nobody can answer.
// getCapabilities lists only what is registered. Run, debug, workspace file and
// search services, editor/registerActions and registerProviders and
// preview/openHTML are not registered, so a plugin that needs one is refused when
// it asks for the permission's methods.
//
// Three things the contract can ask for are still missing:
//
//   - a language server launch answer of {kind: "tool"} (serverProcess 4) is
//     refused at start, because the tool is not resolved through the toolchain
//     registry yet; the plugin's packaged answer works. requiresTools is accepted.
//   - only diagnostics are presented. Completion, hover, navigation, rename and
//     formatting have no editor surface, so a server runs and reports problems but
//     cannot yet answer a question about the code.
//   - tool discovery for system commands reads PATH only. A plan that depends on a
//     project toolchain or a user override is refused rather than started with
//     whatever PATH holds.
//
// Run sessions a backend starts (run/start, run/stop, run/didExit) are served
// by the host: it owns the process, the console and the end of the run, and
// resolves the plugin's required tools or packaged executable.
//
// Build systems are served through both provider processes and command plans.
// The Build window detects instances, loads their model, resolves the ordered
// executable candidates Core returns, runs command and provider tasks, and
// prepares application targets. A shared provider attaches to the language
// server of the same plugin. Run preparation, tests and debug preparation are
// not served. Everything else a manifest can ask for — user
// interface contributions, project generators — is likewise not served,
// and claiming one would let a plugin install and then fail the first time a
// user reaches for it.
func Declared() Capabilities {
	return Capabilities{
		"languages":       {1, 3},
		"languageServers": {1, 3},
		"serverProcess":   {1, 3, 4},
		"backend":         {1, 2},
		"pluginFunctions": {1},
		// The Build tool window detects the declared build systems, loads
		// provider models and runs command or provider tasks. Version 2 is
		// provider task execution. Run preparation (4), tests, debug and
		// toolchain resolution remain undeclared until their native surfaces
		// are complete.
		"buildSystems":   {1},
		"buildProviders": {1, 2},
		// Tool definitions and strict executable resolution behind them are
		// wired: settings discovery and Build/Run selection use the shared Core
		// resolver. Provider queries are not, so toolchainProviders stays out
		// rather than admitting a backend whose answers this client cannot read.
		"executableResolution": {2},
		"toolDefinitions":      {1},
		// The New Project window lists plugin generators, evaluates their forms
		// through Core, discovers tool and runtime installations with the shared
		// toolchain, and runs the plan (files, commands, archives) in a staging
		// directory. Version 2 adds tool fields.
		"projectGenerators": {1, 2},
		// Settings v2: pages per language and build system, sections, every
		// control type, the project layer, setting effects and page buttons.
		"settings": {1, 2},
		// Debug adapters run over stdio, or inside the plugin's language server
		// over loopback TCP (tcpLanguageServer). Launch and attach (including a
		// remote host and port after the user confirms it), argument and
		// environment bindings, and the declared features and defaults reach the
		// shared debug engine.
		"debugAdapters": {1, 2, 3},
		// Console lines of Build, Run and Test output become links at the ranges
		// Core finds; a matcher with resolve asks the plugin's backend on click.
		"outputLinkMatchers": {1},
		// Plugin tool windows dock in the tool stripes: plain text (1), a
		// page of the package behind the window.lithe bridge (2), or a
		// host-rendered native tree, list or form (3) whose data Core checks.
		"ui": {1, 2, 3},
	}
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
// The file must also pass the running platform's native executable check.
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
			if executable {
				if err := verifyNativeExecutable(current, info); err != nil {
					return "", fmt.Errorf("%w: %q", err, name)
				}
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
