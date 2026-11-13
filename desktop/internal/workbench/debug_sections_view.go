package workbench

import (
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The tabs of the Debug tool window under its toolbar, as IntelliJ IDEA names them: the threads
// and variables of the shown session and its console, then the disassembly and, for an adapter
// that reads memory, the memory. The breakpoints are the toolbar's View Breakpoints dialog.
const (
	debugSectionThreads     = "threads"
	debugSectionConsole     = "console"
	debugSectionDisassembly = "disassembly"
	debugSectionMemory      = "memory"
)

// Minimum widths of the two panes of Threads & Variables, and the share of the call stack
// before the user moves the divider.
const (
	debugFramesMinWidth    = 160
	debugVariablesMinWidth = 220
	debugFramesRatio       = 0.4
)

// debugSections declares the tabs and the chosen tab.
func (a *App) debugSections(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	lang := a.language()
	sections := []string{debugSectionThreads, debugSectionConsole, debugSectionDisassembly}
	labels := []string{i18n.Shared(lang, "debugger.threadsAndVariables"), i18n.Shared(lang, "debugger.console"), t.Disassembly}
	if d.capabilities != nil && d.capabilities.SupportsReadMemoryRequest {
		sections = append(sections, debugSectionMemory)
		labels = append(labels, t.Memory)
	}
	selected := slices.Index(sections, d.section)
	if selected < 0 {
		selected, d.section = 0, debugSectionThreads
	}
	ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).PadX(6).Children(func() {
		a.toolTabsWith(c.Part("debug-tabs"), selected, labels, func(index int) { d.section = sections[index] })
	})
	ui.Divider(c)
	switch d.section {
	case debugSectionConsole:
		a.debugConsole(c, p)
	case debugSectionDisassembly:
		a.debugDisassemblyView(c, p)
	case debugSectionMemory:
		a.debugMemoryView(c, p)
	default:
		a.debugThreadsAndVariables(c, p)
	}
}

// debugThreadsAndVariables declares the Threads & Variables tab: the call stack on the left and,
// past a divider the user moves, the variables of the selected frame.
func (a *App) debugThreadsAndVariables(c ui.C, p *project) {
	split := &p.panels.debugSplit
	if split.Ratio <= 0 {
		split.Ratio = debugFramesRatio
	}
	var frames, variables ui.Box
	ui.Row(c).Fill().Clip().Children(func() {
		frames = ui.Column(c.Part("frames")).Children(func() { a.debugFrames(c, p) })
		ui.Splitter(c, split).Mins(debugFramesMinWidth, debugVariablesMinWidth).Label(a.text.Panel.Resize)
		variables = ui.Column(c.Part("variables")).Children(func() { a.debugVariablesView(c, p) })
	})
	frames.FillHeight().MinWidth(debugFramesMinWidth).Shrink(1)
	variables.Fill().MinWidth(debugVariablesMinWidth)
}

// debugVariableLabel is the text assistive technology reads for one row.
func debugVariableLabel(node *debugVarNode) string {
	switch {
	case node.moreFor != nil:
		return "…"
	case node.value == "":
		return node.name
	}
	return node.name + " = " + node.value
}

// describe, key and label are the Tree's accessors for the flattened rows.
func (v *debugVariables) describe(i int) ui.TreeNode {
	node := v.rows[i]
	return ui.TreeNode{Depth: node.depth, Branch: node.ref > 0 && node.moreFor == nil, Expanded: node.expanded, Selected: node == v.selected}
}

func (v *debugVariables) key(i int) int {
	node := v.rows[i]
	if node.id == 0 {
		v.nextID++
		node.id = v.nextID
	}
	return node.id
}

func (v *debugVariables) label(i int) string { return debugVariableLabel(v.rows[i]) }

// debugVariablesView declares the right pane of Threads & Variables: the field that evaluates an
// expression or adds it as a watch, the watches, and the tree or the JSON text of the selected
// frame's variables with the field that edits the selected one.
func (a *App) debugVariablesView(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	v := &d.vars
	a.debugEvaluateField(c, p)
	a.debugExceptionInfo(c, p)
	a.debugWatchView(c, p)
	if v.registersScope() != nil || v.failure != "" {
		ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
			a.debugRegistersTabs(c, p)
			if v.failure != "" {
				ui.Text(c, v.failure).Shrink(1).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger).Ellipsis()
			}
		})
	}
	switch {
	case d.activeSession() == nil || len(v.scopes) == 0:
		message := t.NoVariables
		if v.loading {
			message = t.LoadingVariables
		}
		a.panelMessage(c, message, a.colors.Subtle)
		return
	case v.json:
		a.debugVariablesJSON(c, p)
	default:
		a.debugVariablesTree(c, p)
	}
	a.debugVariableEdit(c, p)
	a.debugVariableBreak(c, p)
}

func (a *App) debugVariablesTree(c ui.C, p *project) {
	t := a.text.Debug
	v := &p.debug.vars
	if v.tree.Node == nil {
		v.tree.Node, v.tree.Key, v.tree.Label = v.describe, v.key, v.label
		v.tree.RowHeight, v.tree.Indent = debugRowHeight, treelist.Indent
	}
	rows := v.flatten()
	ui.Tree(c, &v.tree, len(rows), v.label, func(i int) {
		node := rows[i]
		a.debugVariablePointer(c, p, i, node)
		if node.moreFor != nil {
			a.debugVariableStatusRow(c, node, t.LoadingVariables, t.LoadMore)
			return
		}
		a.debugVariableRow(c, node)
	}).Grow(1).FillWidth()
	a.debugVariableMenu(c, p)
	if i, ok := v.tree.Toggled(); ok && i < len(rows) {
		node := rows[i]
		c.After(func() {
			if node.expanded {
				a.collapseDebugNode(p, node)
			} else {
				a.expandDebugNode(p, node)
			}
		})
	}
	if i, ok := v.tree.Chosen(); ok && i < len(rows) {
		node := rows[i]
		c.After(func() { a.chooseDebugVariable(p, node) })
	}
}

// debugVariableRow declares one variable as IntelliJ IDEA writes it, "name = {type} value", after
// an icon that tells a value with children from a plain one. A scope is its name alone.
func (a *App) debugVariableRow(c ui.C, node *debugVarNode) {
	icon := icons.Variable
	switch {
	case node.scope:
		icon = icons.Folder
	case node.ref > 0:
		icon = icons.Braces
	}
	ui.Icon(c, icon).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
	ui.Text(c, node.name).Shrink(0).FontSize(12.5).Color(treelist.Text(a.colors.Dark)).Weight(gfx.WeightMedium)
	if node.scope || (node.value == "" && node.typeName == "") {
		return
	}
	ui.Text(c, "=").Shrink(0).FontSize(12.5).Color(a.colors.Subtle)
	if node.typeName != "" {
		ui.Text(c, "{"+node.typeName+"}").Shrink(0).FontSize(12.5).Color(a.colors.Subtle)
	}
	if node.value != "" {
		ui.Text(c, node.value).Shrink(1).FontSize(12.5).Color(a.colors.Text).Ellipsis().Mono()
	}
}

// debugVariableStatusRow is the last row of a container that has more children,
// is loading them or failed: it loads the next page when clicked.
func (a *App) debugVariableStatusRow(c ui.C, node *debugVarNode, loading, more string) {
	container := node.moreFor.container
	text, color := more, a.colors.Accent
	switch {
	case container.failure != "":
		text, color = container.failure, a.theme.Danger
	case container.loading:
		text, color = loading, a.colors.Subtle
	}
	ui.Text(c, text).Shrink(1).FontSize(12).Color(color).Ellipsis()
}

// chooseDebugVariable selects a row, or loads the next page for the status row.
func (a *App) chooseDebugVariable(p *project, node *debugVarNode) {
	v := &p.debug.vars
	if node.moreFor != nil {
		if node.moreFor.container.failure != "" {
			node.moreFor.container.failure = ""
		}
		a.loadDebugContainer(p, node.moreFor)
		return
	}
	v.selected = node
}

// debugVariablesJSON shows the loaded variables as JSON text. The text is
// rebuilt only when the tree changed.
func (a *App) debugVariablesJSON(c ui.C, p *project) {
	v := &p.debug.vars
	if v.jsonVersion != v.version || v.jsonLines == nil {
		v.jsonLines = strings.Split(debugJSONText(v.scopes), "\n")
		v.jsonVersion = v.version
	}
	lines := v.jsonLines
	v.jsonList.Label = func(i int) string { return lines[i] }
	ui.List(c, &v.jsonList, len(lines), func(row ui.ListRow) {
		row.Element.Height(debugRowHeight).PadX(10).Items(ui.Center)
		ui.Text(row.C, lines[row.Index]).FontSize(12.5).Color(a.colors.Text).Mono()
	}).Label(a.text.Debug.ViewJSON).FillWidth().Grow(1)
}

// debugVariableEdit declares the field that gives the selected variable a new
// value. It is shown only for a variable Core would let the user change.
func (a *App) debugVariableEdit(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	v := &d.vars
	if !canEditDebugVariable(d, v.selected) || v.json {
		return
	}
	if v.edit.node != v.selected {
		v.edit.node = v.selected
		v.edit.field.SetText(v.selected.value)
	}
	ui.Divider(c)
	ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
		ui.Text(c, v.selected.name).Shrink(0).FontSize(12.5).Color(a.colors.Text).Weight(gfx.WeightMedium)
		ui.TextField(c, &v.edit.field, t.EditValue, t.EditValue).Grow(1)
		if ui.Button(c, t.SetValue).Clicked() {
			node, text := v.selected, v.edit.field.Text()
			c.After(func() { a.setDebugVariable(p, node, text) })
		}
	})
}

// debugExceptionsView declares the breakpoints dialog's exception breakpoints: one checkbox per
// filter the adapter offers. The choice is the user's and outlives the session.
func (a *App) debugExceptionsView(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	ui.Text(c, t.Exceptions).Color(a.colors.Text).Weight(gfx.WeightMedium)
	if d.capabilities == nil || len(d.capabilities.ExceptionBreakpointFilters) == 0 {
		ui.Text(c, t.NoExceptionFilters).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		return
	}
	ui.Column(c).FillWidth().Gap(4).PadX(8).Children(func() {
		for _, filter := range d.capabilities.ExceptionBreakpointFilters {
			enabled := d.exceptions.exceptionEnabled(filter)
			if ui.Checkbox(c.Key(filter.Filter), &enabled, filter.Label).Clicked() {
				name, value := filter.Filter, enabled
				c.After(func() { a.setDebugException(p, name, value) })
			}
		}
	})
}

// debugDisassemblyView declares the instruction window of the selected frame as IntelliJ IDEA
// shows it: no actions of its own. The toolbar's steps take one instruction while this tab is
// shown (see debugStepGranularity), the toolbar's More menu goes back to the current
// instruction, scrolling to either end loads more code, and a click in the gutter sets or
// removes an instruction breakpoint, drawn as the editor draws a line breakpoint.
func (a *App) debugDisassemblyView(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	w := &d.disassembly
	if !canDisassemble(d) {
		a.panelMessage(c, t.NoDisassembly, a.colors.Subtle)
		return
	}
	if len(w.rows) == 0 && !w.loading && w.failure == "" {
		// Ask on this paint, as the memory section does: the section is also shown by a menu's
		// Show Disassembly, after which an ordinary paint declares it, and a deferred callback
		// of an ordinary paint is dropped. The load marks itself loading before it returns.
		a.loadDisassembly(p)
	}
	if w.failure != "" {
		ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).PadX(10).Children(func() {
			ui.Text(c, w.failure).Shrink(1).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger).Ellipsis()
		})
	}
	if len(w.rows) == 0 {
		if w.loading {
			a.panelMessage(c, t.LoadingVariables, a.colors.Subtle)
		}
		return
	}
	// The last paint's rows say whether the user scrolled to an end; asked on this paint for
	// the same reason as the first window.
	a.loadDisassemblyAtEdges(p)
	rows := w.rows
	breakpoints := d.capabilities.SupportsInstructionBreakpoints
	execution := a.colors.Accent
	execution.Alpha *= debugExecutionAlpha
	w.list.Label = func(i int) string { return rows[i].Address + " " + rows[i].Instruction }
	ui.List(c, &w.list, len(rows), func(row ui.ListRow) {
		instruction := rows[row.Index]
		current := strings.EqualFold(strings.TrimSpace(instruction.Address), strings.TrimSpace(w.anchor))
		element := row.Element.Height(debugRowHeight).PadSides(0, 10, 0, 4).Items(ui.Center).Gap(10)
		if current {
			element.Background(execution)
		}
		if breakpoints {
			a.debugInstructionGutter(row.C, p, instruction.Address)
		}
		ui.Text(row.C, instruction.Address).Shrink(0).FontSize(12).Color(a.colors.Subtle).Mono()
		if instruction.Symbol != "" {
			ui.Text(row.C, instruction.Symbol).Shrink(0).FontSize(12).Color(a.colors.Accent)
		}
		ui.Text(row.C, instruction.Instruction).Grow(1).Shrink(1).FontSize(12.5).Color(a.colors.Text).Mono().Ellipsis()
		if instruction.SourcePath != "" && instruction.Line != nil {
			ui.Text(row.C, debugFileName(instruction.SourcePath)+":"+strconv.FormatInt(*instruction.Line, 10)).Shrink(0).FontSize(11.5).Color(a.colors.Subtle)
		}
		a.debugInstructionMenu(row.C, row.Element, p, instruction)
	}).Label(t.Disassembly).FillWidth().Grow(1)
}

// debugInstructionGutter declares the breakpoint mark at the start of one instruction's row,
// the dot the editor's gutter draws for a line breakpoint: filled while the instruction has a
// breakpoint, an outline while the breakpoints are muted, and a faint dot under the pointer
// where a click would set one. A click sets or removes the breakpoint.
func (a *App) debugInstructionGutter(c ui.C, p *project, address string) {
	d := &p.debug
	lang := a.language()
	index := slices.IndexFunc(d.instructionBreakpoints, func(b core.DebugInstructionBreakpoint) bool {
		return b.InstructionReference == address
	})
	label := i18n.Shared(lang, "debugger.disassembly.setBreakpoint")
	if index >= 0 {
		label = i18n.Shared(lang, "debugger.disassembly.removeBreakpoint")
	}
	k := c.Part("insn-bp")
	// The dot is the target; its pointer region reaches the whole gutter cell of the row.
	reach := float32(debugRowHeight-debugGutterDot) / 2
	dot := ui.Column(k).Width(debugGutterDot).Height(debugGutterDot).Shrink(0).Radius(debugGutterDot/2).
		HitWith(ui.ID(k), label, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).
		HitOutset(reach, 4, reach, 4)
	color := a.theme.Danger
	switch {
	case index < 0:
		faint := color
		faint.Alpha *= debugGutterHintAlpha
		dot.Hover(ui.Look{}.Background(faint))
	case d.muted || !d.instructionBreakpoints[index].Enabled:
		dot.Border(debugGutterRing, color)
	default:
		dot.Background(color)
	}
	if dot.Clicked() {
		c.After(func() {
			a.performed("debug.instruction.toggleBreakpoint", surfaceButton)
			a.toggleInstructionBreakpoint(p, address)
		})
	}
}
