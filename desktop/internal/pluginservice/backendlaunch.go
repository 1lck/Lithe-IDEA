package pluginservice

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
)

// backendLaunch is a decoded backend-resolved launch and the directories it uses.
type backendLaunch struct {
	plan        *core.PluginBackendPlan
	directories pluginDirectories
}

// resolveBackendLaunch runs the two steps of a backend-resolved language-server
// launch (serverProcess 3): Core plans the first step, the plugin backend answers
// the command line through its launch function, and Core checks the answer and
// returns the plan the host starts like any other.
//
// Every writable location is the platform's plugin storage or a scratch directory
// under the system temporary directory. Nothing is derived from the installed
// package or the application bundle, which stay read-only so the next
// differential update still matches what the user installed.
func (s *Service) resolveBackendLaunch(ctx context.Context, pluginID, version string, manifest json.RawMessage, languageID string, workspace WorkspaceContext, start pluginbackend.StartRequest) (backendLaunch, error) {
	if workspace.ContextID == "" {
		return backendLaunch{}, fmt.Errorf("%w: a backend-resolved server needs an open workspace", pluginbackend.ErrRequest)
	}
	base := filepath.Join(s.Root, pluginStateDirectory, pluginID)
	temporary, err := os.MkdirTemp("", "lithe-server-")
	if err != nil {
		return backendLaunch{}, err
	}
	directories := pluginDirectories{
		state:          start.StateDirectory,
		workspaceState: filepath.Join(base, "servers", languageID, "workspaces", WorkspaceKey(workspace.Path)),
		log:            filepath.Join(base, "logs"),
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
	}
	plan, err := s.kernel.PlanPluginLanguageServer(ctx, manifest, languageID, request)
	if err != nil {
		return fail(err)
	}
	if plan.Launch.Kind != "backend" || plan.Launch.Function == "" {
		return fail(fmt.Errorf("%w: the plan is not a backend-resolved launch", pluginbackend.ErrRequest))
	}
	// The function's params are the plan's resolveParams themselves, as the
	// contract says: serverID, platform, the four directories and the settings.
	params := plan.ResolveParams
	reference, err := json.Marshal(workspace.ContextRef)
	if err != nil {
		return fail(err)
	}
	timeout := time.Duration(plan.Launch.TimeoutMilliseconds) * time.Millisecond
	answer, err := s.Host.Call(ctx, pluginID, plan.Launch.Function, params, reference, timeout)
	if err != nil {
		return fail(fmt.Errorf("resolve the %s launch: %w", languageID, err))
	}
	decoded, err := s.kernel.DecodePluginLanguageServerLaunch(ctx, manifest, languageID, request, answer)
	if err != nil {
		return fail(err)
	}
	if decoded.Owner == nil {
		decoded.Owner = plan.Owner
	}
	// The host creates the parents of the paths the server writes before the
	// start, as the contract requires; Core already refused any outside the four
	// directories.
	for _, path := range decoded.WritablePaths {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return fail(err)
		}
	}
	return backendLaunch{plan: &decoded, directories: directories}, nil
}
