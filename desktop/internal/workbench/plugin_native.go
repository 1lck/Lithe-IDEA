package workbench

import (
	"context"
	"fmt"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/gfx"
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
	// revealed says the toolbar shows: the pointer is over the panel, or the keyboard or assistive focus is on
	// one of its buttons. It is read from the previous paint, so the toolbar keeps its place either way.
	revealed       bool
	toolbarFocused bool
	// nodes are the rows of a source panel, read from its function; sourceLoaded says they are current,
	// sourceBusy that a read is out, and sourceFailure names why the last read failed, if it did.
	nodes         []pluginservice.NativeNode
	sourceLoaded  bool
	sourceBusy    bool
	sourceFailure string
	// form holds a form panel's fields: text for the string and number kinds, flags for checkboxes.
	// They are created once from the declaration and kept across repaints and reopening.
	formReady bool
	text      map[string]*string
	flags     map[string]*bool
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
	if panel.Form != nil {
		a.pluginFormBody(c, p, tool, state)
		return
	}
	nodes := panel.Nodes
	if panel.Source != nil {
		nodes = state.nodes
		if !state.sourceLoaded && !state.sourceBusy {
			a.loadNativeSource(p, tool, state)
		}
	}
	rows := flattenNativeRows(nodes, state.expanded, 0, nil)
	state.toolbarFocused = false
	root := ui.Column(c).Fill().Background(a.colors.Editor).Hit(ui.ID(c.Key("native-panel")), tool.Title)
	root.Children(func() {
		if state.sourceFailure != "" {
			ui.Row(c).FillWidth().Height(28).Shrink(0).Items(ui.Center).PadX(8).Children(func() {
				ui.Text(c, state.sourceFailure).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning).Ellipsis()
			})
		}
		if len(panel.Toolbar) > 0 {
			// Icon-only actions. They keep their place and stay focusable while hidden; the opacity is
			// what the pointer or the keyboard reveals.
			opacity := float32(0)
			if state.revealed {
				opacity = 1
			}
			ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(2).PadX(8).Children(func() {
				for _, id := range panel.Toolbar {
					action := nativeAction(panel, id)
					if action == nil {
						continue
					}
					button := ui.Button(c.Key("native-"+id), action.Title).Icon(*nativeActionIcon(action)).IconOnly().Ghost().
						Size(shellHideSize, shellHideSize).Shrink(0).Tooltip(action.Title).Opacity(opacity)
					button = button.Disabled(state.busy || (action.RequiresSelection && state.selected == ""))
					if button.State().Focused {
						state.toolbarFocused = true
					}
					if button.Clicked() {
						c.After(func() { a.runNativeAction(p, tool, state, *action, nil) })
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
									a.runNativeAction(p, tool, state, *action, nil)
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
	state.revealed = root.State().Hovered || state.toolbarFocused
}

// nativeActionIcon is the host icon an action shows in the toolbar: its declared icon, else the refresh icon
// for a refresh and the generic run icon for an invoke.
func nativeActionIcon(action *pluginservice.NativeAction) *gfx.Icon {
	if action.Icon != "" {
		return pluginToolIcon(action.Icon)
	}
	if action.Kind == "refresh" {
		return &icons.RefreshCw
	}
	return &icons.Play
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
// initForm creates the fields of a form from its declaration, once.
func initForm(state *nativePanelState, form *pluginservice.NativeForm) {
	if state.formReady {
		return
	}
	state.text, state.flags = map[string]*string{}, map[string]*bool{}
	for _, control := range form.Controls {
		switch control.Kind {
		case "checkbox":
			value, _ := control.Value.(bool)
			state.flags[control.ID] = &value
		case "stepper":
			number, _ := control.Value.(float64)
			text := strconv.FormatFloat(number, 'f', -1, 64)
			state.text[control.ID] = &text
		default:
			text, _ := control.Value.(string)
			state.text[control.ID] = &text
		}
	}
	state.formReady = true
}

// formValues collects the current fields keyed by control ID, as the contract passes them to a button.
// A stepper's text is read as a number when it parses, and kept as text otherwise.
func formValues(state *nativePanelState, form *pluginservice.NativeForm) map[string]any {
	values := make(map[string]any, len(form.Controls))
	for _, control := range form.Controls {
		if flag, ok := state.flags[control.ID]; ok {
			values[control.ID] = *flag
			continue
		}
		text := *state.text[control.ID]
		if control.Kind == "stepper" {
			if number, err := strconv.ParseFloat(text, 64); err == nil {
				values[control.ID] = number
				continue
			}
		}
		values[control.ID] = text
	}
	return values
}

// pluginFormBody declares a form panel: its controls packed into the form's columns by their spans, then
// its buttons. Every field is disabled while a call is out, and a field the declaration disabled stays
// disabled. A change of a field with onCommit calls that action with every field's value.
func (a *App) pluginFormBody(c ui.C, p *project, tool *pluginservice.ToolWindow, state *nativePanelState) {
	form := tool.Native.Form
	initForm(state, form)
	ui.Column(c).Fill().Background(a.colors.Editor).Children(func() {
		ui.Column(c).FillWidth().Grow(1).Gap(10).PadX(10).PadY(10).Children(func() {
			for _, row := range packFormRows(form) {
				row := row
				ui.Row(c.Key(fmt.Sprintf("row-%d", row[0].index))).FillWidth().Gap(10).Items(ui.Start).Children(func() {
					for _, placed := range row {
						a.drawFormControl(c, p, tool, state, placed.control, placed.index, float32(placed.control.Span))
					}
				})
			}
			if len(form.Buttons) > 0 {
				ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
					for _, button := range form.Buttons {
						button := button
						action := nativeAction(tool.Native, button.Action)
						if action == nil {
							continue
						}
						if ui.Button(c.Key("button-"+button.ID), button.Label).Outline().Disabled(state.busy || !button.Enabled).Clicked() {
							values := formValues(state, form)
							c.After(func() { a.runNativeAction(p, tool, state, *action, values) })
						}
					}
				})
			}
		})
	})
}

// placedControl is a control with its place in the declaration.
type placedControl struct {
	control pluginservice.NativeControl
	index   int
}

// packFormRows packs the controls in declaration order into rows of the form's columns: a control wraps to
// the next row before its span would exceed the columns. Without a layout every control spans the one column.
func packFormRows(form *pluginservice.NativeForm) [][]placedControl {
	var rows [][]placedControl
	var current []placedControl
	used := 0
	for index, control := range form.Controls {
		if used+control.Span > form.Columns && len(current) > 0 {
			rows = append(rows, current)
			current, used = nil, 0
		}
		current = append(current, placedControl{control: control, index: index})
		used += control.Span
	}
	if len(current) > 0 {
		rows = append(rows, current)
	}
	return rows
}

// drawFormControl declares one field, filling its share of the row, and commits its change when it has an
// onCommit. The first paint after a change compares with the last committed values, so a commit is never
// repeated for the same value.
func (a *App) drawFormControl(c ui.C, p *project, tool *pluginservice.ToolWindow, state *nativePanelState, control pluginservice.NativeControl, index int, span float32) {
	disabled := state.busy || !control.Enabled
	key := c.Key("field-" + control.ID)
	commit := func() {
		if control.OnCommit == "" {
			return
		}
		action := nativeAction(tool.Native, control.OnCommit)
		if action == nil {
			return
		}
		values := formValues(state, tool.Native.Form)
		c.After(func() { a.runNativeAction(p, tool, state, *action, values) })
	}
	ui.Column(c.Key(fmt.Sprintf("cell-%d", index))).Grow(span).Basis(0).MinWidth(0).Gap(4).Children(func() {
		switch control.Kind {
		case "checkbox":
			if ui.Checkbox(key, state.flags[control.ID], control.Label).Disabled(disabled).Changed() {
				commit()
			}
		case "select":
			ids, labels := optionIDs(control.Options)
			before := *state.text[control.ID]
			ui.Select(key, state.text[control.ID], ids, func(id string) string { return labels[id] }).Label(control.Label).FillWidth().Disabled(disabled)
			if *state.text[control.ID] != before {
				commit()
			}
		case "segmented":
			ui.Text(c, control.Label).FontSize(12).Color(a.colors.Subtle)
			ui.Row(c.Key("seg-" + control.ID)).FillWidth().Gap(4).Children(func() {
				for _, option := range control.Options {
					option := option
					button := ui.Button(c.Key("seg-"+control.ID+"-"+option.ID), option.Label).Small()
					if *state.text[control.ID] != option.ID {
						button = button.Outline()
					}
					if button.Disabled(disabled).Clicked() && *state.text[control.ID] != option.ID {
						*state.text[control.ID] = option.ID
						commit()
					}
				}
			})
		case "stepper":
			ui.Row(c.Key("step-" + control.ID)).FillWidth().Gap(4).Items(ui.Center).Children(func() {
				ui.Text(c, control.Label).Grow(1).FontSize(12).Color(a.colors.Subtle).Ellipsis()
				if ui.Button(c.Key("step-down-"+control.ID), "−").Small().Outline().Disabled(disabled).Clicked() {
					*state.text[control.ID] = stepValue(*state.text[control.ID], -control.Step, control.Minimum, control.Maximum)
					commit()
				}
				ui.TextField(key, state.text[control.ID], "", control.Placeholder).Width(96).Disabled(disabled)
				if ui.Button(c.Key("step-up-"+control.ID), "+").Small().Outline().Disabled(disabled).Clicked() {
					*state.text[control.ID] = stepValue(*state.text[control.ID], control.Step, control.Minimum, control.Maximum)
					commit()
				}
			})
		case "editor":
			ui.TextArea(key, state.text[control.ID], control.Label, control.Placeholder).FillWidth().Height(float32(control.Rows) * 20).Disabled(disabled)
		case "input", "search":
			if ui.TextField(key, state.text[control.ID], control.Label, control.Placeholder).FillWidth().Disabled(disabled).Submitted() {
				commit()
			}
		default:
			ui.TextField(key, state.text[control.ID], control.Label, control.Placeholder).FillWidth().Disabled(disabled)
		}
	})
}

// optionIDs splits options into their IDs and a label lookup for a select.
func optionIDs(options []pluginservice.NativeOption) ([]string, map[string]string) {
	ids := make([]string, len(options))
	labels := make(map[string]string, len(options))
	for index, option := range options {
		ids[index], labels[option.ID] = option.ID, option.Label
	}
	return ids, labels
}

// stepValue moves a stepper's number by delta and keeps it inside its bounds. Text that is not a number
// starts from the minimum.
func stepValue(text string, delta, minimum, maximum float64) string {
	value, err := strconv.ParseFloat(text, 64)
	if err != nil {
		value = minimum
	}
	value = min(max(value+delta, minimum), maximum)
	return strconv.FormatFloat(value, 'f', -1, 64)
}

func (a *App) runNativeAction(p *project, tool *pluginservice.ToolWindow, state *nativePanelState, action pluginservice.NativeAction, values map[string]any) {
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
		message, err := plugins.InvokeToolWindowAction(ctx, root, pluginID, function, selected, values)
		return func(a *App) {
			state.busy = false
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_native_action", err))
				a.notifyError(i18n.Shared(a.language(), "desktop.nativePanel.failed"))
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
	plugins, root, pluginID, declaration, function, buildSystemID, instanceRoot := a.plugins, p.root, tool.PluginID, tool.Native.Declaration, source.Function, source.BuildSystemID, instances[0].Root
	a.background(p, 30*time.Second, func(ctx context.Context) func(*App) {
		nodes, err := plugins.InvokeNativeSource(ctx, root, pluginID, declaration, function, buildSystemID, instanceRoot)
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
