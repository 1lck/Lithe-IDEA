package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

// debugSettingsError keeps native/Core diagnostics for logging while the UI
// renders one localized, actionable failure for the configuration read stage.
type debugSettingsError struct{ cause error }

func (e *debugSettingsError) Error() string { return e.cause.Error() }
func (e *debugSettingsError) Unwrap() error { return e.cause }

// debugAdapterUnresolved marks a preparation failure of the adapter's own launch, as opposed
// to the debuggee's: its settings, plan, program or state directories could not be resolved.
// Only these end the plugin's adapter start. The text is the cause's.
type debugAdapterUnresolved struct{ cause error }

func (e *debugAdapterUnresolved) Error() string { return e.cause.Error() }
func (e *debugAdapterUnresolved) Unwrap() error { return e.cause }

func adapterUnresolved(err error) error { return &debugAdapterUnresolved{cause: err} }

// preparedDebugLaunch contains only Core's plan and verified native executable paths.
type preparedDebugLaunch struct {
	Executable    string
	Arguments     []string
	Environment   map[string]string
	Configuration core.DebugLaunchConfiguration
	// DisabledCapabilities, Features and Defaults are the adapter's declaration
	// from the launch plan, handed to the debug engine with the session.
	DisabledCapabilities []string
	Features             json.RawMessage
	Defaults             json.RawMessage
	// Endpoint is the plan's endpoint descriptor, passed unchanged to Core when
	// it reads the output of a tcpAnnounced adapter for its announcement.
	Endpoint json.RawMessage
}

// resolveAdapterProcess resolves the program of a stdio or tcpAnnounced adapter
// from Core's plan:
// a packaged file, a system command, or a tool the toolchain registry resolves.
// Packaged paths are verified against the installed package, never the workspace.
func (a *App) resolveAdapterProcess(ctx context.Context, adapter debugAdapter, plan core.PluginBackendPlan, root, stateDirectory string) (string, []string, map[string]string, error) {
	var executable string
	processArguments := plan.Arguments
	var environment map[string]string
	if plan.Launch.Kind == "tool" {
		// The entry is absolute substitution text; package verification still uses
		// a relative path and rejects traversal or links at every component.
		relativeEntry, err := filepath.Rel(adapter.Directory, plan.Launch.Entry)
		if err != nil {
			return "", nil, nil, err
		}
		entry, err := pluginhost.ResolvePackagePath(adapter.Directory, filepath.ToSlash(relativeEntry))
		if err != nil {
			return "", nil, nil, err
		}
		if _, err := pluginhost.ResolvePackagePaths(adapter.Directory, plan.RequiredPackagePaths); err != nil {
			return "", nil, nil, err
		}
		manifests, _, err := a.usableToolchainManifests(ctx, "toolchain_debug_discovery")
		if err != nil {
			return "", nil, nil, err
		}
		var selected core.ToolchainSelection
		if plan.Launch.PackagedRuntime != "" {
			runtime, err := pluginhost.ResolveExecutable(adapter.Directory, plan.Launch.PackagedRuntime)
			if err != nil {
				return "", nil, nil, err
			}
			selected, err = toolchain.Resolve(ctx, a.kernel, root, ".", plan.Launch.Tool, plan.Launch.MinimumVersion, &toolchain.Fixed{Executable: runtime}, manifests, toolchain.Options{Platform: buildPlatform(), GlobalRoot: a.globalToolchainRoot()})
			if err != nil {
				return "", nil, nil, err
			}
		} else {
			selected, err = a.resolveToolchainSelectionFrom(ctx, root, ".", plan.Launch.Tool, plan.Launch.MinimumVersion, manifests)
			if err != nil {
				return "", nil, nil, err
			}
		}
		plugins := make([]core.ToolchainPlugin, 0, len(manifests))
		for _, manifest := range manifests {
			plugins = append(plugins, core.ToolchainPlugin{Manifest: manifest})
		}
		registry, err := json.Marshal(struct {
			Plugins []core.ToolchainPlugin `json:"plugins"`
		}{plugins})
		if err != nil {
			return "", nil, nil, err
		}
		home := ""
		if selected.Home != nil {
			home = *selected.Home
		}
		launch, err := a.kernel.InstantiateToolchainLaunch(ctx, registry, plan.Launch.Tool, selected.Executable, home, entry, plan.Launch.RuntimeArguments, plan.Arguments)
		if err != nil {
			return "", nil, nil, err
		}
		executable, processArguments = launch.Executable, launch.Arguments
		environment = applyToolchainSelection(nil, selected)
	} else {
		resolved, err := pluginhost.VerifyLaunch(adapter.Directory, pluginbackend.LaunchFromPlan(plan))
		if err != nil {
			return "", nil, nil, err
		}
		executable = resolved.Executable
		if plan.Launch.Kind == pluginhost.LaunchSystemCommand {
			lookup := a.installedCommands().Lookup(adapter.PluginID, func(name string) (string, error) { return debugLookupCommand(ctx, name) })
			executable, err = pluginhost.ResolveCommand(plan.Launch.Commands, lookup)
			if err != nil {
				return "", nil, nil, err
			}
		}
	}
	return executable, processArguments, environment, nil
}

// prepareDebugLaunch runs off the window thread. The Core owns template expansion
// and DAP argument bindings; this adapter only verifies and opens native resources.
// It reads only p's root and its workspace trust, which is atomic.
func (a *App) prepareDebugLaunch(ctx context.Context, start debugStart, stateDirectory string, p *project, targetPath string, generation uint64, unavailable string) (preparedDebugLaunch, error) {
	root := p.root
	adapter := start.adapter
	hosted := adapter.Declaration.Transport == "tcpLanguageServer"
	settings, err := a.loadPluginPreferenceSources(ctx, adapter.Manifest, root)
	if err != nil {
		return preparedDebugLaunch{}, adapterUnresolved(&debugSettingsError{cause: err})
	}
	directories := core.PluginBackendDirectories{
		PluginDirectory:         adapter.Directory,
		StateDirectory:          stateDirectory,
		WorkspaceStateDirectory: filepath.Join(stateDirectory, "workspace"),
		LogDirectory:            a.pluginLogDirectory(ctx, adapter.PluginID),
		TemporaryDirectory:      filepath.Join(stateDirectory, "tmp"),
		Architecture:            core.PluginArchitecture(),
		Settings:                settings.State.Settings,
		ProjectSettings:         settings.State.ProjectSettings,
		// A hosted adapter's launch is its language server's, which Core refuses in an
		// untrusted workspace when the server runs project code.
		ProjectCodeAllowed: p.trust.allowed(),
	}
	plan, err := a.kernel.PlanPluginDebugAdapter(ctx, adapter.Manifest, adapter.Declaration.ID, directories)
	if err != nil {
		return preparedDebugLaunch{}, adapterUnresolved(err)
	}
	var executable string
	processArguments := plan.Arguments
	var environment map[string]string
	// An adapter inside a language server has no process of its own: the plan's
	// launch is the server's, which its language session starts.
	if !hosted {
		executable, processArguments, environment, err = a.resolveAdapterProcess(ctx, adapter, plan, root, stateDirectory)
		if err != nil {
			return preparedDebugLaunch{}, adapterUnresolved(err)
		}
		if executable == "" {
			return preparedDebugLaunch{}, adapterUnresolved(errors.New(unavailable))
		}
	}
	target := core.DebugTargetFacts{Kind: "file", Path: targetPath, WorkingDirectory: root, Arguments: []string{}, Environment: map[string]string{}}
	// A backend's configuration names everything the debuggee needs: there is no
	// file to look up and no endpoint to ask the user about.
	if start.configuration != nil {
		// target stays the empty file fact.
	} else if start.launchTarget != nil {
		// A plugin run's process: the run resolved the program, and Core binds it
		// through the adapter's launch targetBindings.
		target = *start.launchTarget
	} else if start.request == "attach" && start.target != nil {
		// A remote debuggee: Core binds host, port and mappings through the
		// adapter's declared connection, so the host passes the facts unchanged.
		target = *start.target
	} else {
		lookup, err := a.kernel.PlanDebugExecutable(ctx, adapter.Manifest, adapter.Declaration.ID, root, targetPath, settings.State.Settings, settings.State.ProjectSettings)
		if err != nil {
			return preparedDebugLaunch{}, err
		}
		if lookup != nil {
			if lookup.Configured != nil {
				target.Executable, err = exec.LookPath(lookup.Configured.Path)
				if err != nil {
					return preparedDebugLaunch{}, err
				}
			} else {
				for _, candidate := range lookup.Candidates {
					info, statErr := os.Stat(candidate)
					if statErr == nil && (!info.Mode().IsRegular() || (runtime.GOOS != "windows" && info.Mode().Perm()&0o111 == 0)) {
						// log-exempt: 预期的缺失：自动候选中的目录和非程序文件不是可运行目标。
						continue
					}
					if statErr != nil && !errors.Is(statErr, os.ErrNotExist) {
						return preparedDebugLaunch{}, statErr
					}
					// log-exempt: 预期的缺失：自动查找允许候选不存在或不可运行。
					if found, lookupErr := exec.LookPath(candidate); lookupErr == nil {
						target.Executable = found
						break
					} else if !errors.Is(lookupErr, os.ErrNotExist) && !errors.Is(lookupErr, exec.ErrNotFound) {
						return preparedDebugLaunch{}, lookupErr
					}
				}
				if target.Executable == "" {
					return preparedDebugLaunch{}, errors.New(unavailable)
				}
			}
		}
	}
	// A backend's configuration goes to Core too, which puts it over the
	// adapter's arguments: the host sends the result as it is.
	planned, err := a.kernel.PlanDebugStart(ctx, adapter.Manifest, adapter.Declaration.ID, start.request, core.DebugStartFacts{
		Registration: core.DebugGeneration{Generation: generation, CurrentGeneration: generation},
		Target:       target,
	}, start.configuration)
	if err != nil {
		return preparedDebugLaunch{}, err
	}
	// Core says which endpoints it can prove local; every other one waits for the
	// user, and the answer is not remembered.
	if planned.Connection != nil && planned.Connection.Remote && !start.confirmed {
		return preparedDebugLaunch{}, &debugRemoteError{host: planned.Connection.Host, port: planned.Connection.Port}
	}
	for _, slot := range plan.RequiredDirectories {
		var directory string
		switch slot {
		case "state":
			directory = directories.StateDirectory
		case "workspaceState":
			directory = directories.WorkspaceStateDirectory
		case "log":
			directory = directories.LogDirectory
		case "temporary":
			directory = directories.TemporaryDirectory
		default:
			return preparedDebugLaunch{}, adapterUnresolved(errors.New(unavailable))
		}
		if directory == "" || !filepath.IsAbs(directory) {
			return preparedDebugLaunch{}, adapterUnresolved(errors.New(unavailable))
		}
		if slot != "log" {
			relative, err := filepath.Rel(stateDirectory, directory)
			if err != nil {
				return preparedDebugLaunch{}, adapterUnresolved(err)
			}
			if relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) || filepath.IsAbs(relative) {
				return preparedDebugLaunch{}, adapterUnresolved(errors.New(unavailable))
			}
		}
		if err := ctx.Err(); err != nil {
			return preparedDebugLaunch{}, err
		}
		if err := os.MkdirAll(directory, 0o700); err != nil {
			return preparedDebugLaunch{}, adapterUnresolved(err)
		}
	}
	prepared := preparedDebugLaunch{
		Executable:    executable,
		Arguments:     processArguments,
		Environment:   environment,
		Configuration: core.DebugLaunchConfiguration{Name: adapter.Declaration.DisplayName, Request: start.request, Arguments: planned.Arguments},
	}
	if descriptor := plan.DebugAdapter; descriptor != nil {
		prepared.DisabledCapabilities = descriptor.DisabledCapabilities
		prepared.Features = descriptor.Features
		prepared.Defaults = descriptor.Defaults
		prepared.Endpoint = descriptor.Endpoint
	}
	return prepared, ctx.Err()
}

// installedCommands is the record of the commands the host installed for plugins;
// nil, which looks up PATH only, before the plugin service opens.
func (a *App) installedCommands() *pluginhost.CommandStore {
	if a.plugins == nil {
		return nil
	}
	return a.plugins.Commands
}
