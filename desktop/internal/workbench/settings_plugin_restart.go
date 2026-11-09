package workbench

import (
	"context"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

func (a *App) pluginSettingsRuntime(id string) settingswindow.PluginRuntimeState {
	a.pluginServerMu.Lock()
	defer a.pluginServerMu.Unlock()
	_, pending := a.pluginSettingsRestart.Load(id)
	state := settingswindow.PluginRuntimeState{RestartRequired: pending, Restarting: a.pluginServerRestarting[id] != nil}
	server := a.pluginServers[id]
	if server != nil && server.session != nil && server.project != nil {
		state.Running, state.Version, state.Workspace = true, server.session.Version, server.project.root
	}
	return state
}

// restartSettingsPlugin follows an explicit settings-button click. It retires
// the old native owner before waiting for complete teardown off the UI thread;
// disable, uninstall and workspace closure revoke its continuation token.
func (a *App) restartSettingsPlugin(id, version, scope, workspace string) {
	if a.plugins == nil || a.project == nil {
		return
	}
	p := a.project
	a.pluginServerMu.Lock()
	server := a.pluginServers[id]
	if server == nil || server.session == nil || server.project != p || server.session.Version != version || (scope == "project" && workspace != p.root) {
		a.pluginServerMu.Unlock()
		return
	}
	if a.pluginServerRestarting == nil {
		a.pluginServerRestarting = make(map[string]*pluginServer)
	}
	a.pluginServerRestarting[id] = server
	if a.pluginServerSuppressed == nil {
		a.pluginServerSuppressed = make(map[string]bool)
	}
	a.pluginServerSuppressed[id] = true
	delete(a.pluginServers, id)
	for language, provider := range a.pluginServerLanguages {
		if provider == id {
			delete(a.pluginServerLanguages, language)
		}
	}
	a.pluginServerMu.Unlock()
	server.cancel()
	a.clearPluginDiagnostics(id)
	a.releasePluginDocuments(id)
	if a.settingsWindow != nil {
		a.settingsWindow.Invalidate()
	}
	a.background(nil, pluginServerStopTimeout, func(ctx context.Context) func(*App) {
		err := a.plugins.StopLanguageServer(ctx, server.session)
		select {
		case <-server.done:
		case <-ctx.Done():
			err = errors.Join(err, ctx.Err())
		}
		// Cleanup belongs to the detached native session, not to the project
		// context. Record failures even when its UI continuation was revoked.
		if err != nil {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_settings_restart", err))
		}
		return func(a *App) {
			a.pluginServerMu.Lock()
			if a.pluginServerRestarting[id] != server || a.project != p {
				a.pluginServerMu.Unlock()
				return
			}
			delete(a.pluginServerRestarting, id)
			if err == nil {
				delete(a.pluginServerSuppressed, id)
			}
			a.pluginServerMu.Unlock()
			if err != nil {
				a.notify(i18n.Shared(a.language(), "desktop.pluginSettings.restartFailed"))
			} else {
				a.startPluginServer(server.session.LanguageID)
			}
			if a.settingsWindow != nil {
				a.settingsWindow.Invalidate()
			}
		}
	})
}
