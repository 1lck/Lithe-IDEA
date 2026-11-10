package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/mcpconfig"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// mcpSettingsLoader is the loader of the MCP Configuration page: the tools' real files and
// Core's library commands. It is nil, which leaves the page unavailable, when the kernel is
// not the real Core client (a test double) or the platform directories cannot be found. The
// page works on the global files; per-project registration belongs to the IDE connection.
func (a *App) mcpSettingsLoader() settingswindow.MCPLoader {
	client, ok := a.kernel.(*core.Client)
	if !ok {
		return nil
	}
	loader, err := mcpconfig.NewLoader(client)
	if err != nil {
		a.gitOperationFailed("mcp_settings_loader", err)
		return nil
	}
	return loader
}
