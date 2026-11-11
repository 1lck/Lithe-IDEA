package workbench

import (
	"context"
	"errors"
	"os"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprovider"
	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

func (s pluginSettingsSources) actionWorkspaceCheck(editor pluginservice.SettingsEditor) func() error {
	publication := s.app.toolchainRoot.Load()
	return func() error {
		current := s.app.toolchainRoot.Load()
		if current != publication {
			return configfile.ErrConflict
		}
		source := editor.Snapshot.Workspace()
		if source == "" {
			if current != nil && *current != "" {
				return configfile.ErrConflict
			}
			return nil
		}
		if current == nil || *current == "" {
			return configfile.ErrConflict
		}
		old, err := os.Stat(source)
		if err != nil {
			return errors.Join(configfile.ErrConflict, err)
		}
		live, err := os.Stat(*current)
		if err != nil {
			return errors.Join(configfile.ErrConflict, err)
		}
		if !os.SameFile(old, live) {
			return configfile.ErrConflict
		}
		return nil
	}
}

// Action runs on the settings worker. Neither confirmation planning nor an
// unavailable action starts a process or publishes a settings draft.
func (s pluginSettingsSources) Action(ctx context.Context, editor pluginservice.SettingsEditor, id string, confirmed bool) (result pluginservice.SettingsActionResult, err error) {
	defer func() { (settingsToolchains{app: s.app}).recordFailure("plugin_settings_action", err) }()
	s.app.emit(core.LevelInfo, "app.action.performed", map[string]any{"action": "plugin.settingsAction", "surface": "settings"})
	check := s.actionWorkspaceCheck(editor)
	result.Plan, err = s.app.plugins.PlanSettingsEditorAction(ctx, editor, id, confirmed, check)
	if err != nil {
		return result, err
	}
	if result.Plan.Kind != "invoke" {
		if result.Plan.Kind == "unavailable" {
			s.app.emit(core.LevelWarn, "app.notification.operation_rejected", map[string]any{"operation": "plugin_settings_action", "reason": result.Plan.Reason})
		}
		return result, nil
	}
	// Capture the project on its owning window thread. The buffered reply lets a
	// cancelled settings page leave without blocking a later window callback.
	projectReply := make(chan *project, 1)
	s.app.post(func(a *App) { projectReply <- a.project })
	var p *project
	select {
	case p = <-projectReply:
	case <-ctx.Done():
		return result, ctx.Err()
	}
	if p == nil {
		return result, configfile.ErrConflict
	}
	if err := check(); err != nil {
		return result, err
	}
	if err := p.ctx.Err(); err != nil {
		return result, err
	}

	// A language server can serve functions without having received a build
	// request yet. Attach to its existing event owner; never add a second reader.
	s.app.pluginServerMu.Lock()
	server := s.app.pluginServers[result.Plan.PluginID]
	if server != nil && server.project != p {
		server = nil
	}
	s.app.pluginServerMu.Unlock()
	if server != nil {
		key := result.Plan.PluginID + "\x00" + server.session.LanguageID
		p.buildSessions.mu.Lock()
		attached, detached := p.buildSessions.shared[key], p.buildSessions.detached
		p.buildSessions.mu.Unlock()
		if attached == nil || attached.Closed() {
			if _, err := s.app.attachSharedBuildClient(ctx, p, buildInstance{}, key, server, detached); err != nil {
				return result, err
			}
		}
	}
	clients := p.buildSessions.functionClients(result.Plan.PluginID)
	candidates := make([]core.PluginFunctionProviderCandidate, 0, len(clients))
	for _, client := range clients {
		session := client.Session()
		candidates = append(candidates, core.PluginFunctionProviderCandidate{SessionID: session.ID, Version: session.Version})
	}
	selected, err := s.app.kernel.SelectPluginFunctionProvider(ctx, result.Plan.PluginID, result.Plan.Version, result.Plan.Function, p.root, candidates)
	if err != nil {
		return result, err
	}
	var target *buildprovider.Client
	for _, client := range clients {
		if client.Session().ID == selected {
			target = client
			break
		}
	}
	if target == nil {
		return result, pluginbackend.ErrNoSession
	}
	// Revalidate around the runtime query: a disabled/uninstalled package or
	// switched workspace cannot reuse a previously selected invocation target.
	live, err := s.app.plugins.PlanSettingsEditorAction(ctx, editor, id, confirmed, check)
	if err != nil {
		return result, err
	}
	if live.Kind != "invoke" {
		result.Plan = live
		s.app.emit(core.LevelWarn, "app.notification.operation_rejected", map[string]any{"operation": "plugin_settings_action", "reason": live.Reason})
		return result, nil
	}
	if err := ctx.Err(); err != nil {
		return result, err
	}
	if err := p.ctx.Err(); err != nil {
		return result, err
	}
	operation, err := target.ExecuteFunction(ctx, live.Function, live.Params)
	if err != nil {
		return result, err
	}
	// Progress is bounded by the shared client. Consume it here so a long-running
	// action cannot retain queued messages after its page has closed.
	for {
		select {
		case <-operation.Done():
			_, err = operation.Wait(ctx)
			result.Completed = err == nil
			return result, err
		case _, open := <-operation.Progress():
			if !open {
				_, err = operation.Wait(ctx)
				result.Completed = err == nil
				return result, err
			}
		case <-ctx.Done():
			return result, cancelSettingsAction(target, operation, ctx.Err())
		case <-p.ctx.Done():
			return result, cancelSettingsAction(target, operation, p.ctx.Err())
		}
	}
}

// Cancellation owns its cleanup budget independently of the page/project.
func cancelSettingsAction(target *buildprovider.Client, operation *buildprovider.Operation, cause error) error {
	cleanup, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	cancelErr := target.Cancel(cleanup, operation)
	_, waitErr := operation.Wait(cleanup)
	if errors.Is(waitErr, context.DeadlineExceeded) {
		return errors.Join(cancelErr, waitErr)
	}
	if cancelErr != nil {
		return cancelErr
	}
	// The normal Core cancellation terminal has already been recorded by Core.
	return cause
}

// functionClients enumerates native-owned handles; Core owns version, workspace,
// readiness and registered-function selection. No process starts during lookup.
func (r *buildRuntime) functionClients(plugin string) []*buildprovider.Client {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return nil
	}
	seen := make(map[string]bool)
	var result []*buildprovider.Client
	for _, group := range []map[string]*buildprovider.Client{r.providers, r.shared} {
		for _, client := range group {
			session := client.Session()
			if session.PluginID == plugin && !seen[session.ID] {
				seen[session.ID] = true
				result = append(result, client)
			}
		}
	}
	return result
}
