package workbench

import (
	"context"
	"encoding/json"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
)

// loadPluginPreferenceSources supplies one operation's real native layers to
// Core. It runs on the operation worker; it never reads on the window thread.
func (a *App) loadPluginPreferenceSources(ctx context.Context, manifest json.RawMessage, workspace string) (core.PluginSettingsState, error) {
	if binding := core.RemoteWorkspaceOf(ctx); binding != nil {
		connection := binding.CapturedConnection(ctx)
		if !connection.IsCurrent() {
			return core.PluginSettingsState{}, &core.Error{Code: core.CodeConnectionClosed, Message: "The workspace connection changed."}
		}
		if a.plugins == nil {
			return core.PluginSettingsState{}, pluginservice.ErrAssembly
		}
		return a.plugins.ReadWorkspacePluginSettings(ctx, manifest, workspace, connection)
	}
	root := ""
	if a.store != nil {
		root = a.store.Dir()
	}
	snapshot, err := pluginsettings.New(a.kernel, root).Load(ctx, manifest, workspace)
	return snapshot.State, err
}
