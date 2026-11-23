package pluginservice

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

// backendLaunch is a decoded backend-resolved launch and the directories it uses.
type backendLaunch struct {
	plan        *core.PluginBackendPlan
	directories pluginDirectories
	// configuration is set when the answer carried its own
	// workspaceConfiguration: that value follows the settings only through
	// the plugin's function, so an immediate change has to ask it again.
	configuration *launchConfiguration
}

// launchConfiguration is what a running backend-resolved server needs to
// answer its workspace configuration again: the request of its start, whose
// directories stay the server's until it ends, and what the host resolved
// for that start.
type launchConfiguration struct {
	pluginID   string
	manifest   json.RawMessage
	languageID string
	workspace  WorkspaceContext
	request    core.PluginBackendDirectories
	runtimes   RuntimeEnvironment
}

// resolveBackendLaunch runs the two steps of a backend-resolved language-server
// launch: Core plans the first step, the plugin backend answers
// the command line through its launch function, and Core checks the answer and
// returns the plan the host starts like any other.
//
// Every writable location is the platform's plugin storage, the log session's
// plugin directory start already carries, or a scratch directory under the
// system temporary directory. Nothing is derived from the installed
// package or the application bundle, which stay read-only so the next
// differential update still matches what the user installed.
func (s *Service) resolveBackendLaunch(ctx context.Context, pluginID, version string, manifest json.RawMessage, languageID string, workspace WorkspaceContext, start pluginbackend.StartRequest, runtimes RuntimeEnvironment) (backendLaunch, error) {
	if workspace.ContextID == "" {
		return backendLaunch{}, fmt.Errorf("%w: a backend-resolved server needs an open workspace", pluginbackend.ErrRequest)
	}
	base := pluginpkg.StateRoot(s.Root, pluginID)
	temporary, err := os.MkdirTemp("", "lithe-server-")
	if err != nil {
		return backendLaunch{}, err
	}
	directories := pluginDirectories{
		state:          start.StateDirectory,
		workspaceState: filepath.Join(base, "servers", languageID, "workspaces", WorkspaceKey(workspace.Path)),
		log:            start.LogDirectory,
		temporary:      temporary,
	}
	fail := func(err error) (backendLaunch, error) {
		removeTemporary(temporary)
		return backendLaunch{}, err
	}
	if err := directories.create(); err != nil {
		return fail(err)
	}
	// The host refreshes the directory's time on each start so retention can tell
	// open workspaces from abandoned ones.
	now := time.Now()
	_ = os.Chtimes(directories.workspaceState, now, now)
	request := core.PluginBackendDirectories{
		PluginDirectory:         start.PackageDirectory,
		StateDirectory:          directories.state,
		WorkspaceStateDirectory: directories.workspaceState,
		LogDirectory:            directories.log,
		TemporaryDirectory:      directories.temporary,
		Architecture:            start.Architecture,
		Settings:                start.Settings,
		ProjectSettings:         start.ProjectSettings,
		ProjectCodeAllowed:      start.ProjectCodeAllowed,
	}
	launch := launchConfiguration{pluginID: pluginID, manifest: manifest, languageID: languageID, workspace: workspace, request: request, runtimes: runtimes}
	decoded, carried, err := s.answerBackendLaunch(ctx, launch)
	if err != nil {
		return fail(err)
	}
	// The host creates the parents of the paths the server writes before the
	// start, as the contract requires; Core already refused any outside the four
	// directories.
	for _, path := range decoded.WritablePaths {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return fail(err)
		}
	}
	resolved := backendLaunch{plan: &decoded, directories: directories}
	if carried {
		resolved.configuration = &launch
	}
	return resolved, nil
}

// answerBackendLaunch plans the first step of the launch, calls the plugin's
// function and returns the plan Core decodes from its answer, and whether the
// answer carried its own workspaceConfiguration. Without one, Core fills the
// plan's configuration from the declaration.
func (s *Service) answerBackendLaunch(ctx context.Context, launch launchConfiguration) (core.PluginBackendPlan, bool, error) {
	plan, err := s.kernel.PlanPluginLanguageServer(ctx, launch.manifest, launch.languageID, launch.request)
	if err != nil {
		return core.PluginBackendPlan{}, false, err
	}
	if plan.Launch.Kind != "backend" || plan.Launch.Function == "" {
		return core.PluginBackendPlan{}, false, fmt.Errorf("%w: the plan is not a backend-resolved launch", pluginbackend.ErrRequest)
	}
	// The function's params are the plan's resolveParams themselves, as the
	// contract says: serverID, platform, the four directories and the settings.
	params, err := s.languageLaunchParamsWithRuntimes(ctx, launch.workspace.Path, launch.manifest, plan.ResolveParams, launch.runtimes)
	if err != nil {
		return core.PluginBackendPlan{}, false, err
	}
	reference, err := json.Marshal(launch.workspace.ContextRef)
	if err != nil {
		return core.PluginBackendPlan{}, false, err
	}
	timeout := time.Duration(plan.Launch.TimeoutMilliseconds) * time.Millisecond
	answer, err := s.Host.Call(ctx, launch.pluginID, plan.Launch.Function, params, reference, timeout)
	if err != nil {
		return core.PluginBackendPlan{}, false, fmt.Errorf("resolve the %s launch: %w", launch.languageID, err)
	}
	decoded, err := s.kernel.DecodePluginLanguageServerLaunch(ctx, launch.manifest, launch.languageID, launch.request, answer)
	if err != nil {
		return core.PluginBackendPlan{}, false, err
	}
	if decoded.Owner == nil {
		decoded.Owner = plan.Owner
	}
	return decoded, answerCarriesConfiguration(answer), nil
}

// answerCarriesConfiguration reports whether a launch answer Core accepted
// has a workspaceConfiguration of its own.
func answerCarriesConfiguration(answer json.RawMessage) bool {
	var fields struct {
		WorkspaceConfiguration json.RawMessage `json:"workspaceConfiguration"`
	}
	if json.Unmarshal(answer, &fields) != nil {
		return false
	}
	value := bytes.TrimSpace(fields.WorkspaceConfiguration)
	return len(value) > 0 && !bytes.Equal(value, []byte("null"))
}

// launchWorkspaceConfiguration asks the plugin's function again with the
// current settings and the directories of the running start, and returns
// the workspaceConfiguration of the plan Core decodes. The rest of the
// answer waits for the next start: an immediate setting changes nothing but
// the configuration.
func (s *Service) launchWorkspaceConfiguration(ctx context.Context, launch launchConfiguration, settings, projectSettings map[string]json.RawMessage) (json.RawMessage, error) {
	launch.request.Settings = settings
	launch.request.ProjectSettings = projectSettings
	plan, _, err := s.answerBackendLaunch(ctx, launch)
	if err != nil {
		return nil, err
	}
	if value := bytes.TrimSpace(plan.WorkspaceConfiguration); len(value) == 0 || bytes.Equal(value, []byte("null")) {
		return nil, nil
	}
	return plan.WorkspaceConfiguration, nil
}

// languageLaunchParams supplies native installation facts, without interpreting
// any tool's version or configuration. Core already validated requiresTools;
// the resolver uses the same user choices and discovery as Build and Run.
func (s *Service) languageLaunchParams(ctx context.Context, root string, manifest, params json.RawMessage) (json.RawMessage, error) {
	return s.languageLaunchParamsWithRuntimes(ctx, root, manifest, params, RuntimeEnvironment{})
}

func (s *Service) languageLaunchParamsWithRuntimes(ctx context.Context, root string, manifest, params json.RawMessage, runtimes RuntimeEnvironment) (json.RawMessage, error) {
	if s.LanguageTool == nil && len(runtimes.Runtimes) == 0 {
		return params, nil
	}
	var declaration struct {
		RequiresTools []string `json:"requiresTools"`
	}
	if err := json.Unmarshal(manifest, &declaration); err != nil {
		return nil, err
	}
	type installation struct {
		Executable string  `json:"executable"`
		Home       *string `json:"home,omitempty"`
		Version    string  `json:"version,omitempty"`
	}
	tools := make(map[string]installation)
	for _, tool := range declaration.RequiresTools {
		if managed, found := runtimes.Facts[tool]; found {
			home := managed.Home
			tools[tool] = installation{managed.Executable, &home, managed.Version}
			continue
		}
		if s.LanguageTool == nil {
			continue
		}
		selected, err := s.LanguageTool(ctx, root, tool)
		if err != nil {
			return nil, err
		}
		if selected != nil && !selected.ProjectCode {
			tools[tool] = installation{selected.Executable, selected.Home, selected.Version}
		}
	}
	if len(tools) == 0 && len(runtimes.Runtimes) == 0 {
		return params, nil
	}
	var value map[string]json.RawMessage
	if err := json.Unmarshal(params, &value); err != nil {
		return nil, err
	}
	encoded, err := json.Marshal(tools)
	if err != nil {
		return nil, err
	}
	value["tools"] = encoded
	if len(runtimes.Runtimes) > 0 {
		value["runtimes"], err = json.Marshal(runtimes.Runtimes)
		if err != nil {
			return nil, err
		}
	}
	return json.Marshal(value)
}
