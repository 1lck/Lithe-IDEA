package workbench

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// Native plugin panels: a tool window the plugin declares as a tree, a list or a form. The host draws the
// rows, fields, toolbar and context menu with its own controls. A click or an arrow key selects a node, Left
// and Right close and open a tree branch, and an action calls the plugin function with the selected ID. A
// form's values and a panel's selection and open branches are kept per project (plugin_native_state.go).

// nativePanelState is one panel's view state: what is selected, which tree nodes are open, the list's
// scroll, whether an action is running and the message the last action answered.
type nativePanelState struct {
	// declaration is the window's native object the state was made for; a changed package starts afresh.
	declaration json.RawMessage
	form        *pluginservice.NativeForm
	selected    string
	expanded    map[string]bool
	list        ui.ListState
	tree        ui.TreeState
	// rows are the visible rows of a tree or list this paint, which the tree's Node reads.
	rows    []nativeRow
	busy    bool
	message string
	// revealed says the toolbar shows: the pointer is over the panel, or the keyboard or assistive focus is on
	// one of its buttons. It is read from the previous paint, so the toolbar keeps its place either way.
	revealed       bool
	toolbarFocused bool
	// shown says the paint in progress declared this panel. A panel a paint leaves out is hidden: its
	// pending calls end (endNativePanels).
	shown bool
	// nodes are the rows of a source panel, read from its function; sourceLoaded says they are current,
	// sourceBusy that a read is out, and sourceFailure names why the last read failed, if it did.
	nodes         []pluginservice.NativeNode
	sourceLoaded  bool
	sourceBusy    bool
	sourceFailure string
	source        nativeCall
	action        nativeCall
	// form holds a form panel's fields: text for the string and number kinds, flags for checkboxes.
	// They are created once from the declaration and kept across repaints and reopening. savedForm holds
	// the values the project kept until the fields are created.
	formReady bool
	text      map[string]*string
	flags     map[string]*bool
	savedForm map[string]any
}

// nativeCall is the background call of a panel: its cancel ends it, and its generation tells the answer
// that the panel still wants it. A call that was stopped or superseded has an old generation and is dropped.
type nativeCall struct {
	cancel context.CancelFunc
	gen    uint64
}

// nativeRow is one visible row of a panel: a node and how deep it sits.
type nativeRow struct {
	node  pluginservice.NativeNode
	depth int
}

// nativeWindowKey names a native window within its project.
func nativeWindowKey(tool *pluginservice.ToolWindow) string {
	return tool.PluginID + "\x00" + tool.ID
}

// nativeState returns the state of a window in project p, creating it on first use. A window whose
// declaration changed (its package was replaced) starts from nothing but what the project kept for it.
func (a *App) nativeState(p *project, tool *pluginservice.ToolWindow) *nativePanelState {
	if p.nativePanels == nil {
		p.nativePanels = map[string]*nativePanelState{}
	}
	key := nativeWindowKey(tool)
	state := p.nativePanels[key]
	if state != nil && !bytes.Equal(state.declaration, tool.Native.Declaration) {
		state.hide()
		state = nil
	}
	if state == nil {
		state = newNativePanelState(p, key, tool)
		p.nativePanels[key] = state
	}
	return state
}

// newNativePanelState makes the state of a window, applying what the project kept for it: the selection,
// the open branches and the form values. A tree's Node describes its rows from this state.
func newNativePanelState(p *project, key string, tool *pluginservice.ToolWindow) *nativePanelState {
	state := &nativePanelState{declaration: tool.Native.Declaration, form: tool.Native.Form, expanded: map[string]bool{}}
	state.tree.RowHeight = debugRowHeight
	state.tree.Node = func(i int) ui.TreeNode {
		row := state.rows[i]
		return ui.TreeNode{
			Depth:    row.depth,
			Branch:   len(row.node.Children) > 0,
			Expanded: state.expanded[row.node.ID],
			Selected: row.node.ID == state.selected,
		}
	}
	if saved, ok := p.nativeSaved[key]; ok {
		state.selected = saved.Selected
		for _, id := range saved.Expanded {
			state.expanded[id] = true
		}
		state.savedForm = saved.Form
	}
	return state
}

// hide ends the calls of a panel that is no longer shown, so their answers are dropped. A reopened panel
// reads its source again and its action buttons are enabled.
func (s *nativePanelState) hide() {
	if s.source.cancel == nil && s.action.cancel == nil {
		return
	}
	s.source.stop()
	s.action.stop()
	s.sourceBusy, s.sourceLoaded, s.busy = false, false, false
}

// stop ends the call if one is out and makes its answer stale.
func (c *nativeCall) stop() {
	if c.cancel != nil {
		c.cancel()
		c.cancel = nil
	}
	c.gen++
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

// endNativePanels runs at the end of each paint: a native panel of the open project that the paint did not
// declare is hidden, and every panel is marked as not declared until the next paint declares it.
func (a *App) endNativePanels() {
	p := a.project
	if p == nil {
		return
	}
	for _, state := range p.nativePanels {
		if !state.shown {
			state.hide()
		}
		state.shown = false
	}
}

// startCall runs work for a panel in the background, with the project's context. Starting a call ends the
// previous one of the same kind. The answer is applied only while the call is still wanted and the project
// is open; the call ends with the project, when the panel is hidden, or at its timeout.
func (a *App) startCall(p *project, call *nativeCall, timeout time.Duration, work func(ctx context.Context) func(*App)) {
	call.stop()
	ctx, cancel := context.WithTimeout(p.ctx, timeout)
	call.cancel = cancel
	gen := call.gen
	a.tasks.running.Add(1)
	go func() {
		defer a.tasks.running.Done()
		apply := work(ctx)
		a.post(func(a *App) {
			if call.gen != gen || a.project != p {
				return
			}
			call.cancel = nil
			cancel()
			if apply != nil {
				apply(a)
			}
		})
	}()
}

// pluginNativeBody declares a native panel: its toolbar, its rows and the actions of its context menu.
func (a *App) pluginNativeBody(c ui.C, p *project, tool *pluginservice.ToolWindow) {
	panel := tool.Native
	state := a.nativeState(p, tool)
	state.shown = true
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
	state.rows = flattenNativeRows(nodes, state.expanded, 0, nil)
	rows := state.rows
	state.toolbarFocused = false
	root := ui.Column(c).Fill().Background(a.colors.Editor).Hit(ui.ID(c.Key("native-panel")), tool.Title)
	root.Children(func() {
		a.nativeFailure(c, state)
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
		switch {
		case len(rows) == 0:
			a.panelMessage(c, i18n.Shared(a.language(), "desktop.nativePanel.empty"), a.colors.Subtle)
		case panel.Kind == "tree":
			a.nativeTree(c, p, tool, state)
		default:
			a.nativeList(c, p, tool, state)
		}
		a.nativeMessage(c, state)
	})
	state.revealed = root.State().Hovered || state.toolbarFocused
}

// nativeFailure shows why the last source read failed, above the rows.
func (a *App) nativeFailure(c ui.C, state *nativePanelState) {
	if state.sourceFailure == "" {
		return
	}
	ui.Row(c).FillWidth().Height(28).Shrink(0).Items(ui.Center).PadX(8).Children(func() {
		ui.Text(c, state.sourceFailure).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning).Ellipsis()
	})
}

// nativeMessage shows the message the last action answered, under the rows.
func (a *App) nativeMessage(c ui.C, state *nativePanelState) {
	if state.message == "" {
		return
	}
	ui.Divider(c)
	ui.Row(c).FillWidth().Height(28).Shrink(0).Items(ui.Center).PadX(8).Children(func() {
		ui.Text(c, state.message).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
	})
}

// nativeTree declares a tree panel. The Tree answers the arrows: Right opens a closed branch and Left
// closes an open one (Toggled), a click or Enter chooses a row (Chosen), and a branch chosen that way
// opens or closes as well.
func (a *App) nativeTree(c ui.C, p *project, tool *pluginservice.ToolWindow, state *nativePanelState) {
	rows := state.rows
	ui.Tree(c, &state.tree, len(rows), func(i int) string { return rows[i].node.Label }, func(i int) {
		a.nativeRowContent(c.KeyInt(i), p, tool, state, rows[i])
	}).Label(tool.Title).Grow(1).FillWidth()
	toggled, didToggle := state.tree.Toggled()
	if didToggle && toggled < len(rows) {
		id := rows[toggled].node.ID
		c.After(func() { state.expanded[id] = !state.expanded[id] })
	}
	if i, ok := state.tree.Chosen(); ok && i < len(rows) {
		row := rows[i]
		opens := len(row.node.Children) > 0 && !(didToggle && toggled == i)
		c.After(func() {
			state.selected = row.node.ID
			if opens {
				state.expanded[row.node.ID] = !state.expanded[row.node.ID]
			}
		})
	}
}

// nativeRowContent declares what a tree row shows after its chevron, and its context menu.
func (a *App) nativeRowContent(c ui.C, p *project, tool *pluginservice.ToolWindow, state *nativePanelState, row nativeRow) {
	box := ui.Row(c).Grow(1).Shrink(1).Items(ui.Center).Gap(6)
	box.Children(func() {
		ui.Text(c, row.node.Label).Grow(1).Shrink(1).FontSize(12.5).Color(a.colors.Text).Ellipsis()
	})
	a.nativeContextMenu(c, box, p, tool, state, row.node.ID)
}

// nativeList declares a list panel: one row per node, a click selects it.
func (a *App) nativeList(c ui.C, p *project, tool *pluginservice.ToolWindow, state *nativePanelState) {
	rows := state.rows
	ui.List(c, &state.list, len(rows), func(row ui.ListRow) {
		item := rows[row.Index]
		row.Element.Height(debugRowHeight).PadX(10).Items(ui.Center).Gap(6).Hover(ui.Look{}.Background(a.colors.Hover))
		if item.node.ID == state.selected {
			row.Element.Background(a.colors.Selection)
		}
		row.Element.Children(func() {
			ui.Text(row.C, item.node.Label).Grow(1).Shrink(1).FontSize(12.5).Color(a.colors.Text).Ellipsis()
		})
		if row.Element.Clicked() {
			state.selected = item.node.ID
		}
		a.nativeContextMenu(row.C, row.Element, p, tool, state, item.node.ID)
	}).Label(tool.Title).Grow(1).FillWidth()
}

// nativeContextMenu attaches the panel's context menu to a row. An action selects the row it was opened on
// and then runs.
func (a *App) nativeContextMenu(c ui.C, target ui.Box, p *project, tool *pluginservice.ToolWindow, state *nativePanelState, id string) {
	panel := tool.Native
	if len(panel.ContextMenu) == 0 {
		return
	}
	ui.ContextMenu(c, target, func(menu *ui.MenuItems) {
		menu.WidthRange(160, 240)
		for _, actionID := range panel.ContextMenu {
			action := nativeAction(panel, actionID)
			if action == nil {
				continue
			}
			if menu.Item(action.Title).Disabled(state.busy).Clicked() {
				c.After(func() {
					state.selected = id
					a.runNativeAction(p, tool, state, *action, nil)
				})
			}
		}
	})
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

// initForm creates the fields of a form from its declaration, once. A value the project kept is used when
// its field still exists with the same kind and, for a choice, one of its options, and within the bounds of
// a stepper; anything else falls back to the declared value.
func initForm(state *nativePanelState, form *pluginservice.NativeForm) {
	if state.formReady {
		return
	}
	state.text, state.flags = map[string]*string{}, map[string]*bool{}
	for _, control := range form.Controls {
		saved, kept := state.savedForm[control.ID]
		switch control.Kind {
		case "checkbox":
			value, _ := control.Value.(bool)
			if flag, ok := saved.(bool); kept && ok {
				value = flag
			}
			state.flags[control.ID] = &value
		case "stepper":
			number, _ := control.Value.(float64)
			if kept {
				if value, ok := saved.(float64); ok && value >= control.Minimum && value <= control.Maximum {
					number = value
				}
			}
			text := strconv.FormatFloat(number, 'f', -1, 64)
			state.text[control.ID] = &text
		default:
			text, _ := control.Value.(string)
			if value, ok := saved.(string); kept && ok && savedTextFits(control, value) {
				text = value
			}
			state.text[control.ID] = &text
		}
	}
	state.savedForm = nil
	state.formReady = true
}

// savedTextFits reports whether a kept text value is still a value of its field: a choice must still have
// the option, and a text field keeps any text.
func savedTextFits(control pluginservice.NativeControl, value string) bool {
	if control.Kind != "select" && control.Kind != "segmented" {
		return true
	}
	for _, option := range control.Options {
		if option.ID == value {
			return true
		}
	}
	return false
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
// disabled. A change of a field with onCommit calls that action with every field's value. A form with a
// source reads it when it is shown, and again after each action with the current values.
func (a *App) pluginFormBody(c ui.C, p *project, tool *pluginservice.ToolWindow, state *nativePanelState) {
	form := tool.Native.Form
	initForm(state, form)
	if tool.Native.Source != nil && !state.sourceLoaded && !state.sourceBusy {
		a.loadNativeSource(p, tool, state)
	}
	ui.Column(c).Fill().Background(a.colors.Editor).Children(func() {
		a.nativeFailure(c, state)
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
						styled := ui.Button(c.Key("button-"+button.ID), button.Label)
						if !button.Primary {
							styled = styled.Outline()
						}
						if styled.Disabled(state.busy || state.sourceBusy || !button.Enabled).Clicked() {
							values := formValues(state, form)
							c.After(func() { a.runNativeAction(p, tool, state, *action, values) })
						}
						if button.Info != "" {
							// The information icon is inert, so its tip stays readable while the button is disabled.
							ui.Button(c.Key("info-"+button.ID), button.Label).Icon(icons.Info).IconOnly().Ghost().
								Size(shellHideSize, shellHideSize).Shrink(0).Tooltip(button.Info)
						}
					}
				})
			}
		})
		a.nativeMessage(c, state)
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
	disabled := state.busy || state.sourceBusy || !control.Enabled
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
		// The information icon sits under its field, and its tip stays readable while the field is disabled:
		// only the field itself is inert.
		if control.Info != "" {
			ui.Button(c.Key("info-"+control.ID), control.Label).Icon(icons.Info).IconOnly().Ghost().
				Size(shellHideSize, shellHideSize).Shrink(0).Tooltip(control.Info)
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

// runNativeAction runs an action. A refresh reads the source again, and a static panel has nothing to
// read, so it changes nothing; an invoke calls its function in the background and shows the message the
// answer carries. Only one action runs at a time.
func (a *App) runNativeAction(p *project, tool *pluginservice.ToolWindow, state *nativePanelState, action pluginservice.NativeAction, values map[string]any) {
	if p == nil || a.plugins == nil || state.busy {
		return
	}
	if action.Kind == "refresh" {
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
	a.startCall(p, &state.action, 70*time.Second, func(ctx context.Context) func(*App) {
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
// or several instances fail the read instead of guessing a root, as the contract requires. A form's source
// receives the form's values; its answer has no nodes, so only the failure is shown.
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
	var values map[string]any
	if tool.Native.Form != nil {
		values = formValues(state, tool.Native.Form)
	}
	state.sourceBusy = true
	plugins, root, pluginID, declaration, function, buildSystemID, instanceRoot := a.plugins, p.root, tool.PluginID, tool.Native.Declaration, source.Function, source.BuildSystemID, instances[0].Root
	a.startCall(p, &state.source, 30*time.Second, func(ctx context.Context) func(*App) {
		nodes, err := plugins.InvokeNativeSource(ctx, root, pluginID, declaration, function, buildSystemID, instanceRoot, values)
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
