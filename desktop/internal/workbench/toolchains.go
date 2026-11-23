package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"runtime"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/loginenv"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

// buildExecution is the executable and environment Core's candidate order
// selected for one Build or Run action. A toolchain candidate contributes its
// declared exports and PATH entries; a bare command contributes neither.
type buildExecution struct {
	Executable  string
	Environment map[string]string
	PathPrepend []string
	// Source is the candidate the executable was found by, which the options dialog shows
	// beside a build's runtime.
	Source buildExecutionSource
}

// buildExecutionSource is where an executable came from: the candidate kind Core listed it under
// ("toolchain", "environment", "command", "setting", "projectFile"), the environment variable of
// an environment candidate, and the version and resolver layer of a toolchain selection.
type buildExecutionSource struct {
	Kind, Variable, Version, Layer string
}

// toolchainManifests reads the enabled plugins' manifests off the window
// thread. It is the only host-owned input the shared registry receives.
func (a *App) toolchainManifests(ctx context.Context) ([]json.RawMessage, error) {
	if a.plugins == nil {
		return nil, errors.New("the plugin host is not available")
	}
	entries, err := a.plugins.Manager.Installed()
	if err != nil {
		return nil, err
	}
	plugins, err := a.plugins.ToolchainPlugins(ctx, entries)
	manifests := make([]json.RawMessage, 0, len(plugins))
	for _, plugin := range plugins {
		manifests = append(manifests, plugin.Manifest)
	}
	return manifests, err
}

// usableToolchainManifests is the shared policy for partial plugin reads. A
// missing manifest must not conceal other valid tools; consumers still rely
// on Core to resolve the requested ID. Log the degradation once per discovery.
func (a *App) usableToolchainManifests(ctx context.Context, operation string) ([]json.RawMessage, bool, error) {
	manifests, readErr := a.toolchainManifests(ctx)
	usable, incomplete, err := partialToolchainCatalog(ctx, manifests, readErr)
	if incomplete {
		a.backgroundFailedIn(ctx, operation, readErr)
	}
	return usable, incomplete, err
}

// partialToolchainCatalog accepts valid manifests from a partially unreadable
// plugin set, but cancellation of the *whole request* is always terminal.
// A nested provider may time out independently without canceling ctx.
func partialToolchainCatalog(ctx context.Context, manifests []json.RawMessage, readErr error) ([]json.RawMessage, bool, error) {
	if err := ctx.Err(); err != nil {
		return nil, false, err
	}
	if readErr == nil {
		return manifests, false, nil
	}
	if len(manifests) == 0 {
		return nil, false, readErr
	}
	return manifests, true, nil
}

// resolveToolchainSelection resolves one tool for one operation. A caller may
// replace the selector in tests through toolchainResolve.
func (a *App) resolveToolchainSelection(ctx context.Context, root, directory, tool, minimumVersion string) (core.ToolchainSelection, error) {
	if a.toolchainResolve != nil {
		return a.toolchainResolve(ctx, root, directory, tool, minimumVersion)
	}
	return a.defaultToolchainSelection(ctx, root, directory, tool, minimumVersion)
}

func (a *App) globalToolchainRoot() string {
	if a.store == nil {
		return ""
	}
	return a.store.Dir()
}

func (a *App) managedToolchainOptions(ctx context.Context, manifests []json.RawMessage) (map[string][]string, map[string]string, []toolchain.ManagedDependency) {
	if a.plugins == nil {
		return nil, nil, nil
	}
	return a.plugins.ManagedToolchainFacts(ctx, manifests)
}

func (a *App) defaultToolchainSelection(ctx context.Context, root, directory, tool, minimumVersion string) (core.ToolchainSelection, error) {
	manifests, _, err := a.usableToolchainManifests(ctx, "toolchain_selection_discovery")
	if err != nil {
		return core.ToolchainSelection{}, err
	}
	return a.resolveToolchainSelectionFrom(ctx, root, directory, tool, minimumVersion, manifests)
}

// resolveToolchainSelectionFrom reuses a catalog read by a run or debugger.
// Looking it up a second time could report the same partial-manifest failure twice,
// or select a different plugin version between resolving and launching a tool.
func (a *App) resolveToolchainSelectionFrom(ctx context.Context, root, directory, tool, minimumVersion string, manifests []json.RawMessage) (core.ToolchainSelection, error) {
	if a.toolchainResolve != nil {
		return a.toolchainResolve(ctx, root, directory, tool, minimumVersion)
	}
	if directory == "" {
		directory = "."
	}
	return toolchain.Resolve(ctx, a.kernel, root, directory, tool, minimumVersion, nil, manifests, a.toolchainOptions(ctx, root, manifests))
}

func (a *App) toolchainOptions(ctx context.Context, root string, manifests []json.RawMessage) toolchain.Options {
	homes, tools, dependencies := a.managedToolchainOptions(ctx, manifests)
	return a.plugins.ToolchainOptions(root, toolchain.Options{
		Global: root == "", GlobalRoot: a.globalToolchainRoot(), Platform: buildPlatform(),
		ManagedHomes: homes, ManagedTools: tools, ManagedDependencies: dependencies,
	})
}

// applyToolchainSelection adds the selected installation's declarations to a
// Build or Run environment. Explicit environment from the build plan or provider
// wins; the tool only supplies what the consumer left unset.
func applyToolchainSelection(environment map[string]string, selection core.ToolchainSelection) map[string]string {
	if selection.Environment == nil && len(selection.PathPrepend) == 0 {
		return environment
	}
	merged := make(map[string]string, len(environment)+len(selection.Environment)+1)
	for key, value := range environment {
		merged[key] = value
	}
	for key, value := range selection.Environment {
		if _, set := merged[key]; !set {
			merged[key] = value
		}
	}
	if len(selection.PathPrepend) > 0 {
		current, set := merged["PATH"]
		if !set {
			current = loginenv.Path()
		}
		parts := append([]string(nil), selection.PathPrepend...)
		if current != "" {
			parts = append(parts, current)
		}
		merged["PATH"] = launchSearchPath(parts)
	}
	return merged
}

// selection is the Core selection shape this execution carries, so callers that
// only need its environment can reuse the same merge helper.
func (e buildExecution) selection() core.ToolchainSelection {
	return core.ToolchainSelection{Environment: e.Environment, PathPrepend: e.PathPrepend}
}

// launchSearchPath joins the PATH of a launch: the toolchain's directories first,
// then the inherited ones. Core owns the rule for empty entries and duplicates
// (ASCII case-folded on Windows); only the order is this host's choice, so the
// whole list is passed as the existing entries. If Core cannot answer, the plain
// join keeps the launch working.
func launchSearchPath(entries []string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resolved, err := core.NewClient().ResolveSearchPath(ctx, entries, nil, runtime.GOOS == "windows")
	if err != nil {
		return joinPathEntries(entries)
	}
	return joinPathEntries(resolved)
}

func joinPathEntries(entries []string) string {
	result := ""
	for _, entry := range entries {
		if entry == "" {
			continue
		}
		if result == "" {
			result = entry
			continue
		}
		result += string(filepath.ListSeparator) + entry
	}
	return result
}
