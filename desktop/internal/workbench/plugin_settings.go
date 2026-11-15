package workbench

import (
	"context"
	"encoding/json"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
)

// loadPluginPreferenceSources supplies one operation's real native layers to
// Core. It runs on the operation worker; it never reads on the window thread.
func (a *App) loadPluginPreferenceSources(ctx context.Context, manifest json.RawMessage, workspace string) (pluginsettings.Snapshot, error) {
	root := ""
	if a.store != nil {
		root = a.store.Dir()
	}
	return pluginsettings.New(a.kernel, root).Load(ctx, manifest, workspace)
}
