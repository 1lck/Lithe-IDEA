package workbench

import (
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The sections under the Debug tool window's breakpoint list.
const (
	debugSectionFrames      = "frames"
	debugSectionVariables   = "variables"
	debugSectionExceptions  = "exceptions"
	debugSectionDisassembly = "disassembly"
	debugSectionMemory      = "memory"
)

// debugSections declares the section switch and the chosen section.
func (a *App) debugSections(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	if d.section == "" {
		d.section = debugSectionFrames
	}
	sections := []string{debugSectionFrames, debugSectionVariables, debugSectionExceptions, debugSectionDisassembly}
	if d.capabilities != nil && d.capabilities.SupportsReadMemoryRequest {
		sections = append(sections, debugSectionMemory)
	}
	if d.section == debugSectionMemory && len(sections) == 4 {
		d.section = debugSectionFrames
	}
	ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).PadX(8).Children(func() {
		ui.Tabs(c, &d.section, sections, func(section string) string {
			switch section {
			case debugSectionVariables:
				return t.Variables
			case debugSectionExceptions:
				return t.Exceptions
			case debugSectionDisassembly:
				return t.Disassembly
			case debugSectionMemory:
				return t.Memory
			}
			return t.Frames
		})
	})
	switch d.section {
	case debugSectionVariables:
		a.debugVariablesView(c, p)
	case debugSectionExceptions:
		a.debugExceptionsView(c, p)
	case debugSectionDisassembly:
		a.debugDisassemblyView(c, p)
	case debugSectionMemory:
		a.debugMemoryView(c, p)
	default:
		a.debugFrames(c, p)
	}
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

// debugVariablesView declares the Variables section: the tree or the JSON text
// of the loaded variables and the field that edits the selected one.
func (a *App) debugVariablesView(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	v := &d.vars
	a.debugWatchView(c, p)
	mode := "tree"
	if v.json {
		mode = "json"
	}
	ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
		ui.Tabs(c, &mode, []string{"tree", "json"}, func(m string) string {
			if m == "json" {
				return t.ViewJSON
			}
			return t.ViewTree
		})
		if v.failure != "" {
			ui.Text(c, v.failure).Shrink(1).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger).Ellipsis()
		}
	})
	v.json = mode == "json"
	switch {
	case d.session == nil || len(v.scopes) == 0:
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
		if node.moreFor != nil {
			a.debugVariableStatusRow(c, node, t.LoadingVariables, t.LoadMore)
			return
		}
		if node.ref > 0 {
			ui.Icon(c, icons.Folder).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
		}
		ui.Text(c, node.name).Shrink(0).FontSize(12.5).Color(treelist.Text(a.colors.Dark)).Weight(gfx.WeightMedium)
		if node.value != "" {
			ui.Text(c, "= "+node.value).Shrink(1).FontSize(12.5).Color(a.colors.Text).Ellipsis().Mono()
		}
		if node.typeName != "" {
			ui.Text(c, node.typeName).Shrink(0).FontSize(11.5).Color(a.colors.Subtle)
		}
	}).Grow(1).FillWidth()
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

// debugExceptionsView declares one checkbox per exception filter the adapter
// offers. The choice is the user's and outlives the session.
func (a *App) debugExceptionsView(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	if d.capabilities == nil || len(d.capabilities.ExceptionBreakpointFilters) == 0 {
		a.panelMessage(c, t.NoExceptionFilters, a.colors.Subtle)
		return
	}
	ui.Column(c).FillWidth().Grow(1).Pad(8).Gap(4).Children(func() {
		for _, filter := range d.capabilities.ExceptionBreakpointFilters {
			enabled := d.exceptions.exceptionEnabled(filter)
			if ui.Checkbox(c.Key(filter.Filter), &enabled, filter.Label).Clicked() {
				name, value := filter.Filter, enabled
				c.After(func() { a.setDebugException(p, name, value) })
			}
		}
	})
}

// debugDisassemblyView declares the instruction window of the selected frame.
func (a *App) debugDisassemblyView(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	w := &d.disassembly
	if !canDisassemble(d) {
		a.panelMessage(c, t.NoDisassembly, a.colors.Subtle)
		return
	}
	if len(w.rows) == 0 && !w.loading && w.failure == "" {
		c.After(func() { a.loadDisassembly(p) })
	}
	ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
		if ui.Button(c, t.LoadBefore).Outline().Disabled(w.loading || w.beforeDone || len(w.rows) == 0).Clicked() {
			c.After(func() { a.loadDisassemblyEdge(p, "before") })
		}
		if ui.Button(c, t.LoadAfter).Outline().Disabled(w.loading || w.afterDone || len(w.rows) == 0).Clicked() {
			c.After(func() { a.loadDisassemblyEdge(p, "after") })
		}
		if ui.Button(c, t.Reload).Outline().Disabled(w.loading).Clicked() {
			c.After(func() { a.loadDisassembly(p) })
		}
		// A disassembly view steps one instruction at a time; Core forwards the
		// granularity only when the adapter advertised it.
		if d.capabilities.SupportsSteppingGranularity {
			if ui.Button(c, t.StepInto).Outline().Clicked() {
				c.After(func() { a.executeDebugWithGranularity(p, "stepIn", "instruction") })
			}
			if ui.Button(c, t.StepOver).Outline().Clicked() {
				c.After(func() { a.executeDebugWithGranularity(p, "next", "instruction") })
			}
			if ui.Button(c, t.StepOut).Outline().Clicked() {
				c.After(func() { a.executeDebugWithGranularity(p, "stepOut", "instruction") })
			}
		}
		ui.Spacer(c)
		switch {
		case w.failure != "":
			ui.Text(c, w.failure).Shrink(1).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger).Ellipsis()
		case w.loading:
			ui.Text(c, t.LoadingVariables).Shrink(1).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		case w.beforeDone && w.afterDone:
			ui.Text(c, t.EndOfCode).Shrink(1).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		}
	})
	rows := w.rows
	w.list.Label = func(i int) string { return rows[i].Address + " " + rows[i].Instruction }
	ui.List(c, &w.list, len(rows), func(row ui.ListRow) {
		instruction := rows[row.Index]
		current := strings.EqualFold(strings.TrimSpace(instruction.Address), strings.TrimSpace(w.anchor))
		element := row.Element.Height(debugRowHeight).PadX(10).Items(ui.Center).Gap(10)
		if current {
			element.Background(a.colors.Hover)
		}
		ui.Text(row.C, instruction.Address).Shrink(0).FontSize(12).Color(a.colors.Subtle).Mono()
		if instruction.Symbol != "" {
			ui.Text(row.C, instruction.Symbol).Shrink(0).FontSize(12).Color(a.colors.Accent)
		}
		ui.Text(row.C, instruction.Instruction).Grow(1).Shrink(1).FontSize(12.5).Color(a.colors.Text).Mono().Ellipsis()
		if instruction.SourcePath != "" && instruction.Line != nil {
			ui.Text(row.C, debugFileName(instruction.SourcePath)+":"+strconv.FormatInt(*instruction.Line, 10)).Shrink(0).FontSize(11.5).Color(a.colors.Subtle)
		}
	}).Label(t.Disassembly).FillWidth().Grow(1)
}
