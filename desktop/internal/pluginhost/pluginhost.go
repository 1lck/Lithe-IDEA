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
//   - languageServers: this client resolves the launch Core plans (a packaged
//     program, a packaged runtime, a bare command found on PATH, a tool the
//     toolchain layers select for the workspace, or the command line the plugin
//     backend answers), starts the process and keeps the session's documents in
//     step with the editor. The editor presents its diagnostics, completion,
//     hover, signature help, code actions, inlay hints, definition, references,
//     rename, formatting, document symbols, document links and semantic tokens,
//     and applies validated server-initiated workspace edits. Plugin-owned sessions are wired: the
//     backend's languageServer/request and notify reach the server under Core's
//     session policy, and didReceiveNotification and didChangeState reach the
//     backend.
//   - backend and pluginFunctions: a backend starts on demand (onWorkspaceOpen,
//     a launch answer, or a call from another plugin) and is answered the host
//     services workspace/getFolders, listContexts and getContext (with
//     didChangeContexts), subscriptions/dispose, the languageServer methods, the
//     cross-plugin functions relay, credentials/get|set|delete, documents/list
//     and getSnapshot, editor/getActive, getSelections, open, reveal, insertText,
//     replaceSelections and applyEdits, editor/registerActions and
//     registerProviders (definition, hover, completion, codeLens, semanticTokens
//     and documentLink), window/showInformation|showWarning|showError,
//     browser/openExternal (http and https only), terminal/create|show|close|
//     reopen|dispose|onExit, documents/registerContentProvider, run/start|stop|
//     didExit, debug/start and workspace/readDirectory|stat|readFile|watch|
//     findFiles|findText (bounded disk reads, search and event projection through
//     Core, with Viva native watches). Window-bound methods are registered only when the
//     window attaches (Service.AttachWorkbench); getCapabilities lists only what
//     is registered. preview/openHTML is not registered, so a plugin that needs
//     it is refused when it asks for that permission.
//   - buildSystems and buildProviders: the Build window detects instances,
//     loads provider models, resolves the ordered executable candidates Core
//     returns, runs command and provider tasks, prepares application targets
//     and discovers and runs provider tests. Debug on a target, or on a
//     provider run configuration in the title bar, has the provider prepare
//     the program of a run that names the plugin's own adapter (debug.adapter)
//     and starts that adapter on it. Run on Current File asks the
//     providers of version 1 for the file's entrypoints and saves the first as a
//     run configuration. Run sessions a backend starts are owned by the host.
//   - runConfigurationTypes: the Run/Debug Configurations dialog lists the
//     kinds a build system declares after the built-in ones, edits them with the
//     form Core describes in the plugin's translation, saves them and runs them
//     with the command Core plans for the detected instance. buildSystems[].run[]
//     may also target a declared kind via configurationType and values so
//     discovered model targets materialize generated configurations under the
//     same group, icon, editor form and launch plan. A declared kind has no
//     debugger.
//   - beforeLaunchTasks: the Add New Task menu of every configuration's Before
//     launch list offers the tasks a build system declares, edits each with the
//     form Core describes in the plugin's translation, and runs the step with
//     the command Core plans for the detected instance before the configuration
//     starts.
//   - toolDefinitions: settings discovery, Build/Run selection and tool
//     launches use the shared Core resolver. Version 1 adds a definition's
//     category and audience, which group the tool on the Toolchains settings
//     page.
//   - toolchainProviders: the shared plugin backend discovers global and project
//     installations and requirements on demand. Core validates each answer with
//     native filesystem facts before the toolchain resolver can use it.
//   - commandInstallers: plugin management reports the commands a
//     systemCommand launch names but the machine lacks, and installs them with
//     the plugin's tool after the user confirms the command line, the network
//     use and the target (the plugin's managed directory or the tool's own);
//     systemCommand launches then find them there (CommandStore). Version 1
//     adds pinned archive downloads, which the host downloads, checks against
//     the pinned SHA-256 and extracts below the plugin's managed directory
//     after the user confirms the version and the URL.
//   - projectGenerators: the New Project window lists generators, evaluates
//     their forms through Core, discovers tools with the shared toolchain and
//     runs the plan in a staging directory.
//   - settings: pages per language and build system, sections, every control
//     type, the project layer, setting effects, page buttons and settingRegions
//     (search keywords and plugin views on a page or the plugin's own Settings tab).
//   - debugAdapters: stdio adapters, adapter processes that print the loopback
//     TCP endpoint they listen on (tcpAnnounced) and adapters inside the
//     plugin's language server over loopback TCP, launch and attach (a remote host after the user
//     confirms it), argument and environment bindings, features and defaults.
//   - outputLinkMatchers: Build, Run and Test console lines become links at the
//     ranges Core finds; a matcher with resolve asks the backend on click.
//   - ui: text, web (window.lithe bridge) and plugin view tool windows docked
//     in the tool stripes; a plugin view (pluginview) draws the host controls,
//     trees and canvases a backend view function returns.
//   - vcsProviders: each provider's roots get a version control tool window
//     with status, check-in, rollback, Diff and whatever else the provider
//     negotiated; its session starts when the window first needs it.
//
// Not presented yet (the plugin installs, the part has no surface):
//
//   - a plugin's foldingRange provider, which is not routed (language-server
//     foldingRange is served).
//   - tool discovery for system commands reads PATH and the plugin's installed
//     command directories only; a plan that depends on a project toolchain or a
//     user override must use a tool launch.
//   - build provider model inputs, native configuration, inline test reports
//     and runtime debug; build system instance options and task preparations.
//   - ui commands that belong to no tool window.
//   - VCS provider annotation, file history, file operations, metadata
//     watching, authentication, history entry diffs, status in the project tree
//     and the editor gutter, and lithe/vcs/execution console output.
//
// buildModelInputs, executionProviders, keymapImportProviders and packageTrust
// are not declared: nothing here serves them, so plugins requiring them are
// not offered for installation.
func Declared() Capabilities {
	baseline := []string{
		"backend",
		"beforeLaunchTasks",
		"buildProviders",
		"buildSystems",
		"commandInstallers",
		"debugAdapters",
		"languageServers",
		"languages",
		"managedRuntimes",
		"outputLinkMatchers",
		"pluginFunctions",
		"projectGenerators",
		"runConfigurationTypes",
		"settings",
		"sourceSettings",
		"toolDefinitions",
		"toolchainProviders",
		"ui",
		"vcsProviders",
	}
	declared := make(Capabilities, len(baseline))
	for _, name := range baseline {
		declared[name] = []int{0}
	}
	// Version 1 adds module sidebars, field sections and entry lists, which the
	// settings window's source forms render.
	declared["sourceSettings"] = []int{0, 1}
	// Version 1 adds command-sourced discovery in the Build test tree.
	// Version 2 adds registry connection debugging for provider applications.
	declared["buildSystems"] = []int{0, 1, 2}
	// Version 1 adds entrypoint runs, which Run on Current File starts.
	declared["buildProviders"] = []int{0, 1}
	// Version 1 adds a definition's category and audience, by which the
	// Toolchains settings page groups and folds the tools.
	declared["toolDefinitions"] = []int{0, 1}
	// Version 1 adds optional mirror URLs on managed runtime artifacts for automatic
	// fastest-source selection and failover.
	declared["managedRuntimes"] = []int{0, 1}
	// Version 1 adds installers that download a pinned archive instead of running
	// a tool; the host extracts it below the plugin's managed command directory.
	declared["commandInstallers"] = []int{0, 1}
	// Version 1 adds a server's executesProjectCode: in a project in safe mode Core
	// starts only the servers that declare false, and the status bar says why the
	// others wait for trust (#2208).
	declared["languageServers"] = []int{0, 1}
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
			return "", fmt.Errorf("%w: %q: %w", ErrPackagePath, name, os.ErrNotExist)
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
