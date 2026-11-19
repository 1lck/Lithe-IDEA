package pluginview

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolicons"
	"github.com/vivaui/viva/gfx"
)

// HostIcon is the host icon a plugin names (plugin-manifest.schema.json#/$defs/uiIcon host):
// the IntelliJ New UI icon of a tool window where the workbench has one, a Lucide icon
// otherwise. ok is false for a name the host does not draw. A tool window's stripe button and
// a node of a view draw the same vocabulary, so the names mean the same in both.
func HostIcon(name string) (gfx.Icon, bool) {
	switch name {
	case "database", "services":
		return toolicons.Services, true
	case "terminal":
		return toolicons.Terminal, true
	case "search":
		return toolicons.Find, true
	case "refresh":
		return icons.RefreshCw, true
	case "reset":
		return icons.Undo2, true
	case "run":
		return toolicons.Run, true
	case "debug":
		return toolicons.Debug, true
	case "settings":
		return icons.Settings, true
	case "add":
		return icons.Plus, true
	case "remove":
		return icons.Minus, true
	case "git":
		return toolicons.Vcs, true
	case "problems":
		return toolicons.Problems, true
	case "plugin":
		return icons.Sparkles, true
	case "tool-window":
		return icons.LayoutGrid, true
	}
	return gfx.Icon{}, false
}
