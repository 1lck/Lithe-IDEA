package workbench

import (
	"context"
	"errors"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// applyPluginSettingsEffects runs on the workbench window after publication.
// Effects come from Core; this adapter only dispatches native session/model I/O.
// It never starts a process merely because a preference was saved.
func (a *App) applyPluginSettingsEffects(owner core.PluginSettingsOwner, effects []string) {
	p := a.project
	if p == nil || a.plugins == nil {
		return
	}
	id := owner.PluginID
	for _, effect := range effects {
		switch effect {
		case "restart":
			a.pluginServerMu.Lock()
			server := a.pluginServers[id]
			running := server != nil && server.project == p && server.session != nil && server.session.Version == owner.Version
			a.pluginServerMu.Unlock()
			if running {
				a.pluginSettingsRestart.Store(id, true)
			}
		case "immediate":
			a.applyLivePluginSettings(p, id, owner.Version)
		case "reload":
			a.reloadPluginBuildModels(p, id)
		}
	}
	if a.settingsWindow != nil {
		a.settingsWindow.Invalidate()
	}
}

func (a *App) applyLivePluginSettings(p *project, id, version string) {
	a.pluginServerMu.Lock()
	server := a.pluginServers[id]
	if server != nil && server.settingsGate == nil {
		server.settingsGate = make(chan struct{}, 1)
	}
	a.pluginServerMu.Unlock()
	if server == nil || server.project != p || server.session == nil || server.session.Version != version {
		return
	}
	revision := server.settingsRevision.Add(1)
	gate := server.settingsGate
	a.background(p, 15*time.Second, func(ctx context.Context) func(*App) {
		var err error
		select {
		case gate <- struct{}{}:
			defer func() { <-gate }()
			if server.settingsRevision.Load() != revision || !a.isCurrentPluginServer(id, server) {
				return nil
			}
			_, err = a.plugins.ApplyLanguageSettings(ctx, server.session)
		case <-ctx.Done():
			err = ctx.Err()
		}

		// log-exempt: 用户取消：工作区关闭、会话退役或新的保存取代了这次发送。
		if errors.Is(err, context.Canceled) || server.settingsRevision.Load() != revision || !a.isCurrentPluginServer(id, server) {
			return nil
		}
		return func(a *App) {
			if err != nil && server.settingsRevision.Load() == revision && a.isCurrentPluginServer(id, server) {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_settings_immediate", err))
				a.pluginSettingsRestart.Store(id, true)
				if a.settingsWindow != nil {
					a.settingsWindow.Invalidate()
				}
			}
		}
	})
}

// reloadPluginBuildModels invalidates only this plugin's native model reads.
// Running tasks retain their captured operation and provider. An in-flight read
// is allowed to finish, then only the selected instance reads the latest source.
func (a *App) reloadPluginBuildModels(p *project, id string) {
	for index := range p.build.instances {
		instance := &p.build.instances[index]
		if instance.PluginID != id {
			continue
		}
		instance.modelLoaded = false
		instance.modelError = ""
		if instance.modelLoading {
			instance.modelReloadPending = true
			continue
		}
		if index == p.build.selected {
			a.loadBuildModel(p, index)
		}
	}
}
