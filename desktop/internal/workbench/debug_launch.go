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
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

// debugSettingsError keeps native/Core diagnostics for logging while the UI
// renders one localized, actionable failure for the configuration read stage.
type debugSettingsError struct{ cause error }

func (e *debugSettingsError) Error() string { return e.cause.Error() }
func (e *debugSettingsError) Unwrap() error { return e.cause }

// preparedDebugLaunch contains only Core's plan and verified native executable paths.
type preparedDebugLaunch struct {
	Executable    string
	Arguments     []string
	Environment   map[string]string
	Configuration core.DebugLaunchConfiguration
}

// prepareDebugLaunch runs off the window thread. The Core owns template expansion
// and DAP argument bindings; this adapter only verifies and opens native resources.
func (a *App) prepareDebugLaunch(ctx context.Context, adapter debugAdapter, stateDirectory, root, targetPath string, generation uint64, unavailable string) (preparedDebugLaunch, error) {
	preferenceRoot := ""
	if a.store != nil {
		preferenceRoot = a.store.Dir()
	}
	settings, err := pluginsettings.New(a.kernel, preferenceRoot).Load(ctx, adapter.Manifest, root)
	if err != nil {
		return preparedDebugLaunch{}, &debugSettingsError{cause: err}
	}
	directories := core.PluginBackendDirectories{
		PluginDirectory:         adapter.Directory,
		StateDirectory:          stateDirectory,
		WorkspaceStateDirectory: filepath.Join(stateDirectory, "workspace"),
		LogDirectory:            filepath.Join(stateDirectory, "log"),
		TemporaryDirectory:      filepath.Join(stateDirectory, "tmp"),
		Architecture:            core.PluginArchitecture(),
		Settings:                settings.State.Settings,
		ProjectSettings:         settings.State.ProjectSettings,
	}
	plan, err := a.kernel.PlanPluginDebugAdapter(ctx, adapter.Manifest, adapter.Declaration.ID, directories)
	if err != nil {
		return preparedDebugLaunch{}, err
	}
	var executable string
	processArguments := plan.Arguments
	var environment map[string]string
	if plan.Launch.Kind == "tool" {
		// The entry is absolute substitution text; package verification still uses
		// a relative path and rejects traversal or links at every component.
		relativeEntry, err := filepath.Rel(adapter.Directory, plan.Launch.Entry)
		if err != nil {
			return preparedDebugLaunch{}, err
		}
		entry, err := pluginhost.ResolvePackagePath(adapter.Directory, filepath.ToSlash(relativeEntry))
		if err != nil {
			return preparedDebugLaunch{}, err
		}
		if _, err := pluginhost.ResolvePackagePaths(adapter.Directory, plan.RequiredPackagePaths); err != nil {
			return preparedDebugLaunch{}, err
		}
		manifests, err := a.toolchainManifests()
		if err != nil {
			return preparedDebugLaunch{}, err
		}
		var selected core.ToolchainSelection
		if plan.Launch.PackagedRuntime != "" {
			runtime, err := pluginhost.ResolveExecutable(adapter.Directory, plan.Launch.PackagedRuntime)
			if err != nil {
				return preparedDebugLaunch{}, err
			}
			selected, err = toolchain.Resolve(ctx, a.kernel, root, ".", plan.Launch.Tool, plan.Launch.MinimumVersion, &toolchain.Fixed{Executable: runtime}, manifests, toolchain.Options{Platform: buildPlatform()})
			if err != nil {
				return preparedDebugLaunch{}, err
			}
		} else {
			selected, err = a.resolveToolchainSelection(ctx, root, ".", plan.Launch.Tool, plan.Launch.MinimumVersion)
			if err != nil {
				return preparedDebugLaunch{}, err
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
			return preparedDebugLaunch{}, err
		}
		home := ""
		if selected.Home != nil {
			home = *selected.Home
		}
		launch, err := a.kernel.InstantiateToolchainLaunch(ctx, registry, plan.Launch.Tool, selected.Executable, home, entry, plan.Launch.RuntimeArguments, plan.Arguments)
		if err != nil {
			return preparedDebugLaunch{}, err
		}
		executable, processArguments = launch.Executable, launch.Arguments
		environment = applyToolchainSelection(nil, selected)
	} else {
		resolved, err := pluginhost.VerifyLaunch(adapter.Directory, pluginbackend.LaunchFromPlan(plan))
		if err != nil {
			return preparedDebugLaunch{}, err
		}
		executable = resolved.Executable
		if plan.Launch.Kind == pluginhost.LaunchSystemCommand {
			executable, err = pluginhost.ResolveCommand(plan.Launch.Commands, func(name string) (string, error) { return debugLookupCommand(ctx, name) })
			if err != nil {
				return preparedDebugLaunch{}, err
			}
		}
	}
	if executable == "" {
		return preparedDebugLaunch{}, errors.New(unavailable)
	}
	lookup, err := a.kernel.PlanDebugExecutable(ctx, adapter.Manifest, adapter.Declaration.ID, root, targetPath, settings.State.Settings, settings.State.ProjectSettings)
	if err != nil {
		return preparedDebugLaunch{}, err
	}
	target := core.DebugTargetFacts{Kind: "file", Path: targetPath, WorkingDirectory: root, Arguments: []string{}, Environment: map[string]string{}}
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
	arguments, err := a.kernel.DebugStartArguments(ctx, adapter.Manifest, adapter.Declaration.ID, "launch", core.DebugStartFacts{
		Registration: core.DebugGeneration{Generation: generation, CurrentGeneration: generation},
		Target:       target,
	})
	if err != nil {
		return preparedDebugLaunch{}, err
	}
	for _, directory := range plan.RequiredDirectories {
		relative, err := filepath.Rel(stateDirectory, directory)
		if err != nil {
			return preparedDebugLaunch{}, err
		}
		if relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) || filepath.IsAbs(relative) {
			return preparedDebugLaunch{}, errors.New(unavailable)
		}
		if err := ctx.Err(); err != nil {
			return preparedDebugLaunch{}, err
		}
		if err := os.MkdirAll(directory, 0o700); err != nil {
			return preparedDebugLaunch{}, err
		}
	}
	return preparedDebugLaunch{
		Executable:    executable,
		Arguments:     processArguments,
		Environment:   environment,
		Configuration: core.DebugLaunchConfiguration{Name: adapter.Declaration.DisplayName, Request: "launch", Arguments: arguments},
	}, ctx.Err()
}
