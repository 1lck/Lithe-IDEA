package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginruntime"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

// ErrRuntimeIncomplete reports a resolver that did not accept a fully prepared dependency set.
var ErrRuntimeIncomplete = errors.New("plugin runtime preparation did not produce a verified environment")

type managedRuntimeKernel interface {
	PlanManagedRuntimes(context.Context, json.RawMessage, core.ManagedRuntimePlatform) (core.ManagedRuntimePlan, error)
	DecodeManagedRuntimeResolution(context.Context, json.RawMessage, core.ManagedRuntimePlatform, json.RawMessage) (core.ManagedRuntimeResolution, error)
}

// RuntimeTool is a native installation fact supplied to the plugin's compatibility check.
type RuntimeTool struct {
	Executable string `json:"executable"`
	Home       string `json:"home,omitempty"`
	Version    string `json:"version,omitempty"`
	Provider   string `json:"provider,omitempty"`
	Layer      string `json:"layer,omitempty"`
}

// RuntimeEnvironment belongs to one verified package and one launch. It never changes the
// global tool catalog or the project's tools; only explicitly bound dependency tools appear.
type RuntimeEnvironment struct {
	Runtimes map[string]core.ManagedRuntimeInstallation
	Tools    map[string]pluginbackend.ToolExecutable
	Facts    map[string]RuntimeTool
}

// SetRuntimeLanguage supplies the UI's current language without reading view state on an I/O worker.
func (s *Service) SetRuntimeLanguage(language string) { s.runtimeLanguage.Store(&language) }

// HasManagedRuntimes is a dispatch check, not manifest validation. Core validates the declaration
// before any process or I/O; old plugins keep their existing path without a new service call.
func HasManagedRuntimes(manifest json.RawMessage) bool {
	var value struct {
		Runtimes json.RawMessage `json:"managedRuntimes"`
	}
	return json.Unmarshal(manifest, &value) == nil && len(value.Runtimes) > 0 && string(value.Runtimes) != "null"
}

// EnsureRuntimes prepares an approved package's environment before publication, or repairs it
// before a language-server launch. Installation verifies every recorded file; launches use the
// inventory's cheap metadata check plus the plugin's bounded compatibility check. Download and
// extraction are native I/O; the declaration, artifact identity and reply validation are Core's.
//
// packageDirectory may be the approved installation staging tree. Neither this method nor the
// runtime manager writes there. A failed update leaves the previously installed package usable.
func (s *Service) EnsureRuntimes(ctx context.Context, manifest json.RawMessage, packageDirectory, pluginID, version string, installing bool, progress func(pluginruntime.Progress)) (RuntimeEnvironment, error) {
	return s.ensureRuntimes(ctx, manifest, packageDirectory, pluginID, version, installing, nil, progress)
}

// EnsureRuntimesWithSettings uses the same effective settings snapshot as the following
// language-server start. Installation uses EnsureRuntimes and the global preference layer.
func (s *Service) EnsureRuntimesWithSettings(ctx context.Context, manifest json.RawMessage, packageDirectory, pluginID, version string, installing bool, settings core.PluginSettingsState, progress func(pluginruntime.Progress)) (RuntimeEnvironment, error) {
	return s.ensureRuntimes(ctx, manifest, packageDirectory, pluginID, version, installing, &settings, progress)
}

func (s *Service) ensureRuntimes(ctx context.Context, manifest json.RawMessage, packageDirectory, pluginID, version string, installing bool, effectiveSettings *core.PluginSettingsState, progress func(pluginruntime.Progress)) (_ RuntimeEnvironment, resultErr error) {
	if !HasManagedRuntimes(manifest) {
		return RuntimeEnvironment{}, nil
	}
	ctx, preparation, err := s.beginRuntimePreparation(ctx, pluginID)
	if err != nil {
		return RuntimeEnvironment{}, err
	}
	var cleanupErr error
	defer func() { preparation.finish(cleanupErr) }()
	kernel, ok := s.kernel.(managedRuntimeKernel)
	if !ok {
		return RuntimeEnvironment{}, fmt.Errorf("%w: managed runtime service unavailable", ErrAssembly)
	}
	platform := core.ManagedRuntimePlatform{OS: toolchain.PlatformName(runtime.GOOS), Arch: core.PluginArchitecture()}
	plan, err := kernel.PlanManagedRuntimes(ctx, manifest, platform)
	if err != nil {
		return RuntimeEnvironment{}, err
	}
	if len(plan.Dependencies) == 0 {
		return RuntimeEnvironment{}, nil
	}
	if effectiveSettings == nil {
		settings, err := s.Settings.Load(ctx, manifest, "")
		if err != nil {
			return RuntimeEnvironment{}, err
		}
		effectiveSettings = &settings.State
	}
	// Core already projected inheritance, validity and defaults in these rows.
	// Settings/ProjectSettings remain raw launch layers, not effective values.
	resolvedSettings := make(map[string]json.RawMessage, len(effectiveSettings.Rows))
	for _, row := range effectiveSettings.Rows {
		resolvedSettings[row.Declaration.ID] = row.Effective.Value
	}
	tools, err := s.runtimeTools(ctx, manifest, plan)
	if err != nil {
		return RuntimeEnvironment{}, err
	}
	manager := pluginruntime.Manager{Root: filepath.Join(pluginpkg.StateRoot(s.Root, pluginID), "runtimes"), Downloader: s.RuntimeDownloader}
	candidates := make(map[string]string, len(plan.Dependencies))
	report := func(value pluginruntime.Progress) {
		if value.Cause != nil && s.RuntimeIssue != nil {
			s.RuntimeIssue(ctx, value.Cause)
		}
		if progress != nil {
			progress(value)
		}
	}
	for _, dependency := range plan.Dependencies {
		report(pluginruntime.Progress{ID: dependency.ID, Phase: "checking"})
		inspect := manager.Find
		if installing {
			inspect = manager.Verify
		}
		installation, found, err := inspect(ctx, runtimeArtifact(dependency))
		if errors.Is(err, pluginruntime.ErrCorrupt) {
			if s.RuntimeIssue != nil {
				s.RuntimeIssue(ctx, err)
			}
			report(pluginruntime.Progress{ID: dependency.ID, Phase: "repairing"})
			continue
		}
		if err != nil {
			return RuntimeEnvironment{}, err
		}
		if found {
			candidates[dependency.ID] = installation.Home
		}
	}
	// The preparation process uses exactly the package being reviewed, even when an older
	// backend of the same plugin is running. Its lifetime ends before installation commits.
	backend, cleanup, err := s.runtimeBackend(ctx, manifest, packageDirectory, pluginID, version, *effectiveSettings)
	if err != nil {
		return RuntimeEnvironment{}, err
	}
	preparation.retryCleanup = cleanup
	defer func() {
		stopCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), backendStopTimeout)
		defer cancel()
		cleanupErr = cleanup(stopCtx)
		resultErr = errors.Join(resultErr, cleanupErr)
	}()
	resolve := func(ctx context.Context) (core.ManagedRuntimeResolution, error) {
		language := ""
		if selected := s.runtimeLanguage.Load(); selected != nil {
			language = *selected
		}
		params, err := json.Marshal(struct {
			Platform     core.ManagedRuntimePlatform     `json:"platform"`
			Dependencies []core.ManagedRuntimeDependency `json:"dependencies"`
			Candidates   map[string]string               `json:"candidates"`
			Tools        map[string]RuntimeTool          `json:"tools"`
			Settings     map[string]json.RawMessage      `json:"settings"`
			Language     string                          `json:"language,omitempty"`
		}{platform, plan.Dependencies, candidates, tools, resolvedSettings, language})
		if err != nil {
			return core.ManagedRuntimeResolution{}, err
		}
		timeout := time.Duration(plan.Resolve.TimeoutMilliseconds) * time.Millisecond
		callCtx, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()
		answer, err := backend.Call(callCtx, plan.Resolve.Function, params, nil, timeout)
		if err != nil {
			return core.ManagedRuntimeResolution{}, err
		}
		return kernel.DecodeManagedRuntimeResolution(ctx, manifest, platform, answer)
	}
	resolution, err := resolve(ctx)
	if err != nil {
		return RuntimeEnvironment{}, err
	}
	for _, id := range resolution.Missing {
		// Core checked the complete partition, so every ID names exactly one selected artifact.
		for _, dependency := range plan.Dependencies {
			if dependency.ID != id {
				continue
			}
			installation, err := manager.Prepare(ctx, runtimeArtifact(dependency), func(ctx context.Context, staged pluginruntime.Installation) error {
				previous, present := candidates[id]
				candidates[id] = staged.Home
				defer func() {
					if present {
						candidates[id] = previous
					} else {
						delete(candidates, id)
					}
				}()
				checked, err := resolve(ctx)
				if err != nil {
					return err
				}
				for _, item := range checked.Runtimes {
					if item.ID == id {
						accepted, acceptedErr := os.Stat(item.Home)
						candidate, candidateErr := os.Stat(staged.Home)
						if acceptedErr == nil && candidateErr == nil && accepted.IsDir() && candidate.IsDir() && os.SameFile(accepted, candidate) {
							return nil
						}
					}
				}
				return fmt.Errorf("%w: %s", ErrRuntimeIncomplete, id)
			}, report)
			if err != nil {
				return RuntimeEnvironment{}, err
			}
			candidates[id] = installation.Home
		}
	}
	resolution, err = resolve(ctx)
	if err != nil {
		return RuntimeEnvironment{}, err
	}
	if len(resolution.Missing) != 0 {
		return RuntimeEnvironment{}, ErrRuntimeIncomplete
	}
	environment := RuntimeEnvironment{
		Runtimes: make(map[string]core.ManagedRuntimeInstallation),
		Tools:    make(map[string]pluginbackend.ToolExecutable), Facts: make(map[string]RuntimeTool),
	}
	for _, installation := range resolution.Runtimes {
		environment.Runtimes[installation.ID] = installation
		for _, dependency := range plan.Dependencies {
			if dependency.ID != installation.ID || dependency.Tool == "" {
				continue
			}
			executable := filepath.Join(installation.Home, filepath.FromSlash(dependency.Executable))
			info, err := os.Stat(executable)
			if err != nil || !info.Mode().IsRegular() || (runtime.GOOS != "windows" && info.Mode()&0o111 == 0) {
				return RuntimeEnvironment{}, fmt.Errorf("%w: executable for %s", ErrRuntimeIncomplete, dependency.ID)
			}
			environment.Tools[dependency.Tool] = pluginbackend.ToolExecutable{Path: executable}
			environment.Facts[dependency.Tool] = RuntimeTool{Executable: executable, Home: installation.Home, Version: installation.Version}
		}
		report(pluginruntime.Progress{ID: installation.ID, Phase: "ready"})
	}
	return environment, nil
}

func runtimeArtifact(dependency core.ManagedRuntimeDependency) pluginruntime.Artifact {
	return pluginruntime.Artifact{ID: dependency.ID, Version: dependency.Version, CacheKey: dependency.CacheKey,
		URL: dependency.URL, SHA256: dependency.SHA256, Archive: dependency.Archive,
		StripPrefix: dependency.StripPrefix, Home: dependency.Home, Executable: dependency.Executable}
}

func (s *Service) runtimeTools(ctx context.Context, manifest json.RawMessage, plan core.ManagedRuntimePlan) (map[string]RuntimeTool, error) {
	tools := make(map[string]RuntimeTool)
	kernel, ok := s.kernel.(toolchain.Kernel)
	if !ok {
		return tools, fmt.Errorf("%w: tool discovery unavailable", ErrAssembly)
	}
	for _, dependency := range plan.Dependencies {
		if dependency.Tool == "" {
			continue
		}
		selected, err := toolchain.Resolve(ctx, kernel, "", ".", dependency.Tool, "", nil, []json.RawMessage{manifest}, toolchain.Options{
			Global: true, GlobalRoot: s.Settings.PreferenceDirectory(),
		})
		var unavailable *toolchain.UnavailableError
		if errors.As(err, &unavailable) && !unavailable.Terminal {
			// log-exempt: 预期的缺失：缺少工具是声明式运行环境准备流程的正常输入。
			continue
		}
		if err != nil {
			return nil, err
		}
		if selected.ProjectCode {
			continue
		}
		fact := RuntimeTool{Executable: selected.Executable, Version: selected.Version, Provider: selected.Provider, Layer: selected.Layer}
		if selected.Home != nil {
			fact.Home = *selected.Home
		}
		tools[dependency.Tool] = fact
	}
	return tools, nil
}

func (s *Service) runtimeBackend(ctx context.Context, manifest json.RawMessage, directory, pluginID, version string, settings core.PluginSettingsState) (*BackendSession, func(context.Context) error, error) {
	root := pluginpkg.StateRoot(s.Root, pluginID)
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, nil, err
	}
	state, err := os.MkdirTemp(root, "runtime-check-")
	if err != nil {
		return nil, nil, err
	}
	startCtx, cancelStart := context.WithTimeout(ctx, backendStartTimeout)
	defer cancelStart()
	started, err := s.Backend.Start(startCtx, pluginbackend.StartRequest{
		Manifest: manifest, PackageDirectory: directory, PluginID: pluginID,
		ProviderID: pluginID + "/runtime-check", StateDirectory: state,
		LogDirectory: s.logDirectory(ctx, pluginID), Architecture: core.PluginArchitecture(),
		RootURI: fileURI(state), WorkingDirectory: state,
		Preparation: true, Settings: settings.Settings, ProjectSettings: settings.ProjectSettings,
	})
	if err != nil {
		return nil, nil, errors.Join(err, os.RemoveAll(state))
	}
	serveCtx, cancel := context.WithCancel(ctx)
	session := &BackendSession{
		host: s.Host, PluginID: pluginID, Version: version, Session: started,
		cancel: cancel, done: make(chan struct{}), functions: make(map[string]bool),
		waiters: make(map[string]chan core.BackendEvent), progress: make(map[string]func(json.RawMessage)), changed: make(chan struct{}),
	}
	go session.serve(serveCtx)
	// A failed stop retains ownership and state, and a later lifecycle attempt can
	// retry it. The gate also serializes simultaneous window shutdown requests.
	gate := make(chan struct{}, 1)
	gate <- struct{}{}
	stopObserved := false
	var stopErr error
	cleanup := func(ctx context.Context) error {
		select {
		case <-gate:
		case <-ctx.Done():
			return ctx.Err()
		}
		defer func() { gate <- struct{}{} }()
		session.cancel()
		select {
		case <-session.done:
		case <-ctx.Done():
			return ctx.Err()
		}
		if !stopObserved {
			stopErr = s.runtimeStopFailure(ctx, session.disposed, session.stopErr)
			stopObserved = true
		} else if stopErr != nil {
			disposed, err := s.Backend.StopAndDispose(ctx, session.Session)
			stopErr = s.runtimeStopFailure(ctx, disposed, err)
		}
		if stopErr != nil {
			return stopErr
		}
		return os.RemoveAll(state)
	}
	return session, cleanup, nil
}

// A failed graceful shutdown remains a diagnostic when disposal already proved
// the process cannot use its files. Only an undisposed process retains ownership.
func (s *Service) runtimeStopFailure(ctx context.Context, disposed bool, err error) error {
	if disposed {
		if err != nil && s.RuntimeIssue != nil {
			s.RuntimeIssue(ctx, err)
		}
		return nil
	}
	return err
}
