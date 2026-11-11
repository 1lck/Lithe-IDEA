package workbench

import (
	"bytes"
	"context"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/ui"
)

// Plugin tool windows (ui.toolWindows) dock in the tool stripes like the built-in ones:
// the kernel arranges them with the rest of the catalog, and the layout file keeps their
// places while their plugin is disabled. A text window shows its literal text; a web
// window shows a page of the plugin's package (pluginpages.go).

// pluginItemPrefix starts the chrome identifier of a plugin tool window, so it never
// meets a built-in identifier.
const pluginItemPrefix = "plugin:"

// isPluginItem reports whether a chrome identifier names a plugin tool window.
func isPluginItem(id string) bool { return strings.HasPrefix(id, pluginItemPrefix) }

// placementZone is the stripe zone a plugin tool window starts in.
func placementZone(placement string) zone {
	switch placement {
	case "left":
		return zoneLeftTop
	case "right":
		return zoneRightTop
	}
	return zoneBottomLeft
}

// pluginItems is the built-in catalog followed by an item for each plugin tool window.
// A window without its own icon has the generic tool window icon.
func pluginItems(windows []pluginservice.ToolWindow) []item {
	items := append(make([]item, 0, len(catalog)+len(windows)), catalog...)
	for i := range windows {
		window := &windows[i]
		title := window.Title
		items = append(items, item{
			id: pluginItemPrefix + window.ID, zone: placementZone(window.Placement), icon: &icons.LayoutGrid,
			label: func(*i18n.Messages) string { return title }, panel: true, tool: window,
		})
	}
	return items
}

// sameToolWindow reports whether two declarations show the same window from the same
// package, so a page open for one can stay open for the other.
func sameToolWindow(a, b *pluginservice.ToolWindow) bool {
	return a.PluginID == b.PluginID && a.PluginName == b.PluginName && a.Package == b.Package &&
		a.ID == b.ID && a.Title == b.Title && a.Placement == b.Placement && a.Order == b.Order &&
		a.Text == b.Text && a.Web == b.Web && bytes.Equal(a.Manifest, b.Manifest)
}

// setPluginTools makes the tool windows of the enabled plugins part of the window's
// catalog. Pages of windows that are gone or come from another package now close, and
// the arrangement is repaired against the new catalog, restoring the saved places of
// windows whose plugin is back.
func (a *App) setPluginTools(windows []pluginservice.ToolWindow) {
	current := a.chrome.catalog[len(catalog):]
	if len(current) == len(windows) {
		same := true
		for i := range windows {
			if !sameToolWindow(current[i].tool, &windows[i]) {
				same = false
				break
			}
		}
		if same {
			return
		}
	}
	restated := a.chrome.restated()
	// A drag holds catalog indices, which mean other items now.
	a.dnd.tool.Cancel()
	a.drag = dragState{}
	a.chrome.setItems(pluginItems(windows))
	a.closeStalePluginPages()
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	layout, _, err := a.kernel.ReduceChromeLayout(ctx, a.chrome.coreItems, restated, core.NormalizeChrome())
	if err != nil {
		a.notify(a.text.Errors.Core(err.Error()))
		layout = a.chrome.layout
	}
	a.chrome.apply(layout)
}

// pluginTextBody declares the literal text of a plugin text window.
func (a *App) pluginTextBody(c ui.C, tool *pluginservice.ToolWindow) {
	ui.Scroll(c).Fill().Children(func() {
		ui.Column(c).FillWidth().Pad(shellContentPad).Children(func() {
			ui.Wrap(c, tool.Text).Color(a.colors.Text)
		})
	})
}
