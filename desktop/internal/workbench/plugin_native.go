package workbench

import (
	"context"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/ui"
)

// Native plugin panels: a tool window the plugin declares as a tree or list of literal nodes. The host
// draws the rows, the toolbar and the context menu with its own controls; a click selects a node, and an
// action calls the plugin function with the selected ID. Forms and build-system sources are not drawn yet.

// nativePanelState is one panel's view state: what is selected, which tree nodes are open, the list's
// scroll, whether an action is running and the message the last action answered.
type nativePanelState struct {
	selected string
	expanded map[string]bool
	list     ui.ListState
	busy     bool
	message  string
	// nodes are the rows of a source panel, read from its function; sourceLoaded says they are current,
	// sourceBusy that a read is out, and sourceFailure names why the last read failed, if it did.
	nodes         []pluginservice.NativeNode
	sourceLoaded  bool
	sourceBusy    bool
	sourceFailure string
}

// nativeRow is one visible row of a panel: a node and how deep it sits.
type nativeRow struct {
	node  pluginservice.NativeNode
	depth int
}

// nativeState returns the state of a window, creating it on first use.
func (a *App) nativeState(tool *pluginservice.ToolWindow) *nativePanelState {
	if a.nativePanels == nil {
		a.nativePanels = map[string]*nativePanelState{}
	}
	key := tool.PluginID + "\x00" + tool.ID
	state := a.nativePanels[key]
	if state == nil {
		state = &nativePanelState{expanded: map[string]bool{}}
		a.nativePanels[key] = state
	}
	return state
}

// flattenNativeRows lists the rows a panel shows: every node, with the children of the open nodes.
func flattenNativeRows(nodes []pluginservice.NativeNode, expanded map[string]bool, depth int, rows []nativeRow) []nativeRow {
	for _, node := range nodes {
		rows = append(rows, nativeRow{node: node, depth: depth})
		if expanded[node.ID] && len(node.Children) > 0 {
			rows = flattenNativeRows(node.Children, expanded, depth+1, rows)
		}
	}
	return rows
}

// pluginNativeBody declares a native panel: its toolbar, its rows and the actions of its context menu.
func (a *App) pluginNativeBody(c ui.C, p *project, tool *pluginservice.ToolWindow) {
	panel := tool.Native
	state := a.nativeState(tool)
	nodes := panel.Nodes
	if panel.Source != nil {
		nodes = state.nodes
		if !state.sourceLoaded && !state.sourceBusy {
			a.loadNativeSource(p, tool, state)
		}
	}
	rows := flattenNativeRows(nodes, state.expanded, 0, nil)
	ui.Column(c).Fill().Background(a.colors.Editor).Children(func() {
		if state.sourceFailure != "" {
			ui.Row(c).FillWidth().Height(28).Shrink(0).Items(ui.Center).PadX(8).Children(func() {
				ui.Text(c, state.sourceFailure).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning).Ellipsis()
			})
		}
		if len(panel.Toolbar) > 0 {
			ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
				for _, id := range panel.Toolbar {
					action := nativeAction(panel, id)
					if action == nil {
						continue
					}
					button := ui.Button(c.Key("native-"+id), action.Title).Small().Outline()
					button.Disabled(state.busy || (action.RequiresSelection && state.selected == ""))
					if button.Clicked() {
						c.After(func() { a.runNativeAction(p, tool, state, *action) })
					}
				}
			})
		}
		if len(rows) == 0 {
			a.panelMessage(c, i18n.Shared(a.language(), "desktop.nativePanel.empty"), a.colors.Subtle)
		} else {
			ui.List(c, &state.list, len(rows), func(row ui.ListRow) {
				item := rows[row.Index]
				row.Element.Height(debugRowHeight).PadX(10).Items(ui.Center).Gap(6).Hover(ui.Look{}.Background(a.colors.Hover))
				if item.node.ID == state.selected {
					row.Element.Background(a.colors.Selection)
				}
				row.Element.Children(func() {
					ui.Spacer(row.C).Width(float32(item.depth) * 14)
					ui.Text(row.C, item.node.Label).Grow(1).Shrink(1).FontSize(12.5).Color(a.colors.Text).Ellipsis()
				})
				if len(item.node.Children) > 0 && row.Element.Clicked() {
					state.expanded[item.node.ID] = !state.expanded[item.node.ID]
				}
				if row.Element.Clicked() {
					state.selected = item.node.ID
				}
				if len(panel.ContextMenu) > 0 {
					ui.ContextMenu(row.C, row.Element, func(menu *ui.MenuItems) {
						menu.WidthRange(160, 240)
						for _, id := range panel.ContextMenu {
							action := nativeAction(panel, id)
							if action == nil {
								continue
							}
							if menu.Item(action.Title).Disabled(state.busy).Clicked() {
								row.C.After(func() {
									state.selected = item.node.ID
									a.runNativeAction(p, tool, state, *action)
								})
							}
						}
					})
				}
			}).Label(tool.Title).Grow(1).FillWidth()
		}
		if state.message != "" {
			ui.Divider(c)
			ui.Row(c).FillWidth().Height(28).Shrink(0).Items(ui.Center).PadX(8).Children(func() {
				ui.Text(c, state.message).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			})
		}
	})
}

// nativeAction finds a declared action by ID.
func nativeAction(panel *pluginservice.NativePanel, id string) *pluginservice.NativeAction {
	for index := range panel.Actions {
		if panel.Actions[index].ID == id {
			return &panel.Actions[index]
		}
	}
	return nil
}

// runNativeAction runs an action. A refresh has nothing to reload on a static panel, so it changes
// nothing; an invoke calls its function in the background and shows the message the answer carries.
// Only one action runs at a time.
func (a *App) runNativeAction(p *project, tool *pluginservice.ToolWindow, state *nativePanelState, action pluginservice.NativeAction) {
	if p == nil || a.plugins == nil || state.busy {
		return
	}
	if action.Kind == "refresh" {
		// A refresh reads the source again; a static panel has nothing to read.
		if tool.Native.Source != nil {
			state.sourceLoaded = false
			a.loadNativeSource(p, tool, state)
		}
		return
	}
	if action.Kind != "invoke" {
		return
	}
	state.busy, state.message = true, ""
	selected, root, plugins, pluginID, function := state.selected, p.root, a.plugins, tool.PluginID, action.Function
	reload := tool.Native.Source != nil
	a.background(p, 70*time.Second, func(ctx context.Context) func(*App) {
		message, err := plugins.InvokeToolWindowAction(ctx, root, pluginID, function, selected)
		return func(a *App) {
			state.busy = false
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_native_action", err))
				a.notify(i18n.Shared(a.language(), "desktop.nativePanel.failed"))
				return
			}
			state.message = message
			// The contract reloads a source after an invocation, since the invocation may have changed it.
			if reload {
				state.sourceLoaded = false
			}
		}
	})
}

// loadNativeSource reads a source panel's nodes for the one detected instance of its build system. Zero
// or several instances fail the read instead of guessing a root, as the contract requires.
func (a *App) loadNativeSource(p *project, tool *pluginservice.ToolWindow, state *nativePanelState) {
	source := tool.Native.Source
	var instances []buildInstance
	for _, instance := range p.build.instances {
		if instance.PluginID == tool.PluginID && instance.BuildSystemID == source.BuildSystemID {
			instances = append(instances, instance)
		}
	}
	language := a.language()
	switch {
	case len(instances) == 0:
		state.nodes, state.sourceLoaded = nil, true
		state.sourceFailure = i18n.Shared(language, "desktop.nativePanel.noInstance")
		return
	case len(instances) > 1:
		state.nodes, state.sourceLoaded = nil, true
		state.sourceFailure = i18n.Shared(language, "desktop.nativePanel.multipleInstances")
		return
	}
	state.sourceBusy = true
	plugins, root, pluginID, function, buildSystemID, instanceRoot := a.plugins, p.root, tool.PluginID, source.Function, source.BuildSystemID, instances[0].Root
	a.background(p, 30*time.Second, func(ctx context.Context) func(*App) {
		nodes, err := plugins.InvokeNativeSource(ctx, root, pluginID, function, buildSystemID, instanceRoot)
		return func(a *App) {
			state.sourceBusy = false
			state.sourceLoaded = true
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_native_source", err))
				state.nodes = nil
				state.sourceFailure = i18n.Shared(a.language(), "desktop.nativePanel.sourceFailed")
				return
			}
			state.nodes, state.sourceFailure = nodes, ""
		}
	})
}
