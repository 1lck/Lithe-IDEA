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

// Declared is what this client can serve today, in plugin contract v1 terms.
//
// Every capability starts at version 0. A host declares a capability version
// when it accepts every manifest form of that version and speaks its protocol.
// Features a plugin offers may go unpresented: this client leaves such a part
// out of the surface (no button, menu or window) instead of failing when a user
// reaches for it, and the parts still missing are listed below so the table
// never hides them. Host services a plugin needs are discovered at runtime
// through getCapabilities and permissions, not through this table.
//
// Starting plugin processes and resolving executables are base contract rules,
// not capabilities: every section that starts a process uses them.
//
// Served:
//
//   - languages: the grammar is decoded by Core and registered with the editor,
//     and the delimiters reach the language's comment and bracket rules.
//   - languageServers: this client resolves the launch Core
//     plans (a packaged program, a packaged runtime, a bare command found on
//     PATH, or the command line the plugin backend answers), starts the process,
//     keeps the session's documents in step with the editor and draws the
//     diagnostics it publishes. Plugin-owned sessions are wired: the backend's
//     languageServer/request and notify reach the server under Core's session
//     policy, and didReceiveNotification and didChangeState reach the backend.
//   - backend and pluginFunctions: a backend starts on demand (onWorkspaceOpen,
//     a launch answer, or a call from another plugin) and is answered the host
//     services workspace/getFolders, listContexts and getContext (with
//     didChangeContexts), subscriptions/dispose, the languageServer methods, the
//     cross-plugin functions relay, credentials/get|set|delete, documents/list
//     and getSnapshot, editor/getActive, getSelections, open, reveal, insertText,
//     replaceSelections and applyEdits, window/showInformation|showWarning|
//     showError, browser/openExternal (http and https only), terminal/create|
//     show|close|reopen|dispose|onExit and documents/registerContentProvider.
//     Window-bound methods are registered only when the window attaches
//     (Service.AttachWorkbench); getCapabilities lists only what is registered.
//     Run, debug, workspace file and search services, editor/registerActions
//     and registerProviders and preview/openHTML are not registered, so a
//     plugin that needs one is refused when it asks for that permission.
//   - buildSystems and buildProviders: the Build window detects instances,
//     loads provider models, resolves the ordered executable candidates Core
//     returns, runs command and provider tasks and prepares application targets.
//     Run sessions a backend starts (run/start, run/stop, run/didExit) are owned
//     by the host.
//   - toolDefinitions: settings discovery and Build/Run selection use the
//     shared Core resolver.
//   - projectGenerators: the New Project window lists generators, evaluates
//     their forms through Core, discovers tools with the shared toolchain and
//     runs the plan in a staging directory.
//   - settings: pages per language and build system, sections, every control
//     type, the project layer, setting effects and page buttons.
//   - debugAdapters: stdio adapters and adapters inside the plugin's language
//     server over loopback TCP, launch and attach (a remote host after the user
//     confirms it), argument and environment bindings, features and defaults.
//   - outputLinkMatchers: Build, Run and Test console lines become links at the
//     ranges Core finds; a matcher with resolve asks the backend on click.
//   - ui: text, web (window.lithe bridge) and native tree, list or form tool
//     windows docked in the tool stripes.
//
// Not presented yet (the plugin installs, the part has no surface):
//
//   - a language server launch answer of {kind: "tool"} is refused at start,
//     because the tool is not resolved through the toolchain registry yet.
//   - only diagnostics are presented; completion, hover, navigation, rename and
//     formatting have no editor surface.
//   - tool discovery for system commands reads PATH only; a plan that depends
//     on a project toolchain or a user override is refused.
//   - build provider run preparation, tests, debug preparation, model inputs,
//     native configuration, inline test reports and runtime debug; build system
//     instance options and task preparations.
//   - ui commands that belong to no tool window.
//
// buildModelInputs, executionProviders, keymapImportProviders, packageTrust,
// toolchainProviders and vcsProviders are not declared: nothing here serves
// them, so a plugin that needs one is not offered for installation.
func Declared() Capabilities {
	baseline := []string{
		"backend",
		"buildProviders",
		"buildSystems",
		"debugAdapters",
		"languageServers",
		"languages",
		"outputLinkMatchers",
		"pluginFunctions",
		"projectGenerators",
		"settings",
		"toolDefinitions",
		"ui",
	}
	declared := make(Capabilities, len(baseline))
	for _, name := range baseline {
		declared[name] = []int{0}
	}
	return declared
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
