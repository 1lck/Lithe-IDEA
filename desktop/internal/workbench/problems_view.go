package workbench

import (
	"path"
	"path/filepath"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	// problemsTreeWidth is the tree's width beside the preview until the user drags the
	// splitter; the tree and the preview keep at least their minimums while it is dragged.
	problemsTreeWidth  = 380
	problemsTreeMin    = 180
	problemsPreviewMin = 200
)

// problemsGroupings are the groupings the View Options menu offers, in order.
var problemsGroupings = []string{core.ProblemsGroupByFile, core.ProblemsGroupBySeverity, core.ProblemsGroupByNone}

// problemsPanel declares the Problems tool window of an open project: the column of actions,
// and the tree of the chosen tab's diagnostics with, beside it, the preview of the selected one.
// The actions stay while the tree is empty, so the options that emptied it can be undone.
func (a *App) problemsPanel(c ui.C, p *project) {
	a.requestProblemsQuery(p)
	lang := a.language()
	ui.Row(c).Fill().Clip().Children(func() {
		a.problemsToolbar(c, lang)
		ui.Divider(c)
		ui.Column(c).Grow(1).Basis(0).Shrink(1).MinWidth(0).FillHeight().MinHeight(0).Children(func() {
			a.problemsContent(c, p, lang)
		})
	})
}

// problemsContent declares the tree and the preview, or why there is no tree: Core refused the
// query, no file is open on the File tab, or the chosen tab has no problems. Nothing shows
// until the first answer arrives, so an empty message does not flash before it.
func (a *App) problemsContent(c ui.C, p *project, lang i18n.Language) {
	v := &a.problems
	switch {
	case v.failure != nil:
		a.panelMessage(c, a.text.Errors.Core(v.failure.Error()), a.theme.Danger)
		return
	case !v.loaded:
		return
	case !v.project && v.file == "":
		a.panelMessage(c, i18n.Shared(lang, "desktop.problems.noOpenFile"), a.colors.Subtle)
		return
	case len(v.result.Rows) == 0:
		scope := p.name
		if !v.project {
			scope = filepath.Base(v.file)
		}
		a.panelMessage(c, i18n.SharedFormat(lang, "native.noProblemsIn", map[string]string{"arg1": scope}), a.colors.Subtle)
		return
	}
	if !v.show {
		a.problemsTree(c, p, lang)
		return
	}
	a.syncProblemsPreview(p, c.Canvas().Focused())
	if v.split.Pos <= 0 {
		v.split.Pos = problemsTreeWidth
	}
	ui.Row(c).Grow(1).Basis(0).Shrink(1).MinWidth(0).FillHeight().MinHeight(0).Children(func() {
		ui.Column(c).Width(v.split.Pos).Shrink(0).FillHeight().MinHeight(0).Children(func() { a.problemsTree(c, p, lang) })
		ui.Splitter(c, &v.split).Mins(problemsTreeMin, problemsPreviewMin).Label(a.text.Panel.Resize)
		a.problemsPreviewPane(c)
	})
}

// problemsToolbar declares the column of actions left of the tree, as IDEA's Problems tool
// window puts them: the View Options menu (the severities shown and the grouping), opening and
// closing every node, and turning the preview on or off. Each option is a preference that asks
// Core for the tree again.
func (a *App) problemsToolbar(c ui.C, lang i18n.Language) {
	v := &a.problems
	ui.Column(c).FillHeight().Shrink(0).Gap(2).Pad(4).Children(func() {
		eye, clicked := a.toolIconButton(c.Part("problemsOptions"), i18n.Shared(lang, "desktop.problems.viewOptions"), icons.Eye, v.optionsOpen, false)
		if clicked {
			v.optionsOpen = !v.optionsOpen
		}
		ui.Menu(c, eye, &v.optionsOpen, func(menu *ui.MenuItems) {
			menu.WidthRange(180, 260)
			menu.Label(i18n.Shared(lang, "desktop.problems.showHeading"))
			if menu.Item(i18n.Shared(lang, "desktop.problems.showErrors")).Checked(!v.hideErrors).Clicked() {
				c.After(func() { v.hideErrors = !v.hideErrors; a.markProblemsChanged() })
			}
			if menu.Item(i18n.Shared(lang, "desktop.problems.showWarnings")).Checked(!v.hideWarnings).Clicked() {
				c.After(func() { v.hideWarnings = !v.hideWarnings; a.markProblemsChanged() })
			}
			if menu.Item(i18n.Shared(lang, "desktop.problems.showInfo")).Checked(!v.hideInfo).Clicked() {
				c.After(func() { v.hideInfo = !v.hideInfo; a.markProblemsChanged() })
			}
			menu.Separator()
			menu.Label(i18n.Shared(lang, "desktop.problems.groupHeading"))
			for _, grouping := range problemsGroupings {
				if menu.Item(problemsGroupingText(lang, grouping)).Chosen(v.grouping() == grouping).Clicked() {
					c.After(func() {
						if v.grouping() != grouping {
							v.groupBy, v.reveal = grouping, true
							a.markProblemsChanged()
						}
					})
				}
			}
		})
		// The ungrouped list has no nodes to open or close.
		flat := v.grouping() == core.ProblemsGroupByNone || len(v.result.Rows) == 0
		if _, clicked := a.toolIconButton(c.Part("problemsExpand"), i18n.Shared(lang, "outline.expandAll"), icons.ChevronsUpDown, false, flat); clicked {
			c.After(func() { a.expandProblems(true) })
		}
		if _, clicked := a.toolIconButton(c.Part("problemsCollapse"), i18n.Shared(lang, "outline.collapseAll"), icons.ChevronsDownUp, false, flat); clicked {
			c.After(func() { a.expandProblems(false) })
		}
		if _, clicked := a.toolIconButton(c.Part("problemsPreview"), i18n.Shared(lang, "desktop.problems.showPreview"), icons.PanelRight, v.show, false); clicked {
			c.After(func() {
				a.performed("workspace.problems.preview", surfaceButton)
				v.show = !v.show
				if !v.show {
					a.closeSourcePreview(&v.preview)
				}
			})
		}
	})
}

// problemsTree declares the tree of diagnostics. A click selects a row, and the preview follows
// it; a double click or Enter opens a diagnostic, or opens or closes a node. With the preview
// off, a click on a diagnostic opens it, as there is nothing else to show it.
func (a *App) problemsTree(c ui.C, p *project, lang i18n.Language) {
	v := &a.problems
	if v.view.Node == nil {
		v.view.Node = v.node
		v.view.Key = v.key
		v.view.Label = a.problemsRowLabel
		v.view.RowHeight = treelist.RowHeight
		v.view.Indent = treelist.Indent
	}
	v.view.Disclosure = &components.TreeDisclosure{
		Collapsed: fileicons.TreeChevron(false, a.colors.Dark),
		Expanded:  fileicons.TreeChevron(true, a.colors.Dark),
		Size:      16,
	}
	a.syncProblemsSelection(c.Canvas())
	rows := v.result.Rows
	ui.Tree(c, &v.view, len(rows), v.view.Label, func(i int) {
		a.drawProblemsRow(c, i, lang)
	}).Scrollbars().Label(i18n.Shared(lang, "native.problems")).Grow(1).FillWidth().MinHeight(0).PadY(treelist.PadY)
	if i, ok := v.view.Toggled(); ok && i < len(rows) {
		key := rows[i].Key
		c.After(func() { a.toggleProblemsNode(key) })
	}
	i, ok := v.view.Chosen()
	if !ok || i >= len(rows) {
		return
	}
	info, clicked := c.Canvas().ClickInfo()
	repeated := clicked && info.Clicks >= 2
	row := rows[i]
	// The row a click chose takes the keyboard, so the arrow keys go on from it.
	c.Canvas().RequestFocus(v.view.RowID(i))
	c.After(func() {
		if !v.selectRow(row.Key) {
			return // a new answer in this frame no longer shows it
		}
		if clicked && !repeated && (row.Kind != core.ProblemsRowDiagnostic || v.show) {
			return // a single click only selects
		}
		if row.Kind != core.ProblemsRowDiagnostic {
			a.toggleProblemsNode(row.Key)
			return
		}
		if item, ok := v.shown(v.selectedRow); ok && item.FileKey != "" {
			a.performed("workspace.problems.open", surfaceButton)
			a.openFileAtPosition(p, item.FileKey, item.Line, item.Column)
		}
	})
}

// syncProblemsSelection makes the selection follow the keyboard: a row the arrow keys moved the
// focus to is selected. Only a move of the focus selects, so a selection Core moved stays while
// the focus is on another row. A selection asked to show is scrolled into view, and takes the
// keyboard when the tree has it.
func (a *App) syncProblemsSelection(canvas *gfx.Canvas) {
	v := &a.problems
	rows := v.result.Rows
	focused := canvas.Focused()
	inTree := false
	if focused != v.focus || v.reveal {
		i, found := treelist.FocusedRow(&v.view, len(rows), focused)
		inTree = found
		if found && focused != v.focus {
			v.selected, v.selectedRow = rows[i].Key, i
		}
		v.focus = focused
	}
	selected := v.selectedRow
	if selected >= len(rows) {
		selected = -1
	}
	if v.reveal && selected >= 0 {
		if first, last := v.view.Visible(); selected < first || selected > last {
			v.view.ScrollTo(selected, ui.ListCenter)
			canvas.RequestFrame()
		}
		if inTree {
			canvas.RequestFocus(v.view.RowID(selected))
		}
		v.reveal = false
	}
	if v.view.Selected() != selected {
		v.view.Select(selected)
	}
}

// problemsRowLabel names row i to assistive technology: a node with its file's path or its
// severity and number of problems, or a diagnostic with its file, line and message.
func (a *App) problemsRowLabel(i int) string {
	v := &a.problems
	if i < 0 || i >= len(v.result.Rows) {
		return ""
	}
	lang := a.language()
	r := v.result.Rows[i]
	if r.Kind == core.ProblemsRowGroup {
		g, ok := v.group(r.Group)
		if !ok {
			return ""
		}
		name := g.DisplayPath
		if g.Kind != core.ProblemsGroupByFile {
			name = problemsSeverityText(lang, g.Severity)
		}
		return name + " " + a.text.Status.Problems(len(g.Indices))
	}
	item, ok := v.shown(i)
	if !ok {
		return ""
	}
	return item.DisplayPath + ":" + strconv.Itoa(item.Line+1) + " " + item.Message
}

// group is the answer's group g, and false when it is out of range.
func (v *problemsView) group(g int) (core.ProblemsGroup, bool) {
	if g < 0 || g >= len(v.result.Groups) {
		return core.ProblemsGroup{}, false
	}
	return v.result.Groups[g], true
}

// drawProblemsRow declares what row i shows after its chevron: a file's icon, name, folder and
// number of problems; a severity's mark, name and number of problems; or a diagnostic's mark,
// message, source and line, with its file's name when the nodes are not files. A diagnostic
// under a node has no chevron, so it keeps the chevron's room empty and its mark lines up
// under its node's icon.
func (a *App) drawProblemsRow(c ui.C, i int, lang i18n.Language) {
	v := &a.problems
	r := v.result.Rows[i]
	g, ok := v.group(r.Group)
	if !ok {
		return
	}
	if r.Kind == core.ProblemsRowGroup {
		count := a.text.Status.Problems(len(g.Indices))
		if g.Kind == core.ProblemsGroupByFile {
			ui.Icon(c, fileicons.ForFile(g.Name, a.colors.Dark)).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
			ui.Text(c, g.Name).FontSize(treeFontSize).Color(a.colors.Text).Shrink(0)
			if g.Folder != "" {
				ui.Text(c, g.Folder).FontSize(treeFontSize).Color(a.colors.Subtle).Shrink(1).MinWidth(0).Ellipsis()
			}
		} else {
			icon, tint := a.problemSeverityMark(g.Severity)
			ui.Icon(c, icon).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(tint)
			ui.Text(c, problemsSeverityText(lang, g.Severity)).FontSize(treeFontSize).Color(a.colors.Text).Shrink(0)
		}
		ui.Text(c, count).FontSize(treeFontSize).Color(a.colors.Subtle).Shrink(0)
		return
	}
	item, ok := v.shown(i)
	if !ok {
		return
	}
	var indent float32
	if r.Depth > 0 {
		indent = treeChevron
	}
	location := ":" + strconv.Itoa(item.Line+1)
	if g.Kind != core.ProblemsGroupByFile {
		location = path.Base(item.DisplayPath) + location
	}
	icon, tint := a.problemSeverityMark(item.Severity)
	ui.Row(c).Shrink(1).MinWidth(0).Items(ui.Center).Gap(c.Theme().Metrics.GapItem).PadLeft(indent).Children(func() {
		ui.Icon(c, icon).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(tint)
		ui.Text(c, item.Message).FontSize(treeFontSize).Color(a.colors.Text).Shrink(1).MinWidth(0).Ellipsis()
		if item.Source != "" {
			// The message gives way first; a source keeps its name up to a cap.
			ui.Text(c, item.Source).FontSize(treeFontSize).Color(a.colors.Subtle).Shrink(0).MaxWidth(120).Ellipsis()
		}
		ui.Text(c, location).FontSize(treeFontSize).Color(a.colors.Subtle).Shrink(0)
	})
}

// problemsScopeTabs declares the header's tabs, File and Project, each with the number of
// problems it holds under the severity options, as IDEA's Problems tool window heads its tree.
// The current file is the selected editor tab's.
func (a *App) problemsScopeTabs(c ui.C) {
	v := &a.problems
	lang := a.language()
	labels := []string{problemsFileTabText(lang, v.fileCount), problemsProjectTabText(lang, v.projectCount)}
	selected := 0
	if v.project {
		selected = 1
	}
	a.toolTabsWith(c, selected, labels, func(i int) { a.chooseProblemsScope(i == 1) })
}

// problemsFileTabText is the File tab's name, followed by its number of problems when it holds any.
func problemsFileTabText(lang i18n.Language, count int) string {
	if count == 0 {
		return i18n.Shared(lang, "desktop.problems.scope.file")
	}
	return i18n.SharedFormat(lang, "desktop.problems.scope.fileCount", map[string]string{"count": strconv.Itoa(count)})
}

// problemsProjectTabText is the Project tab's name, followed by its number of problems when it
// holds any.
func problemsProjectTabText(lang i18n.Language, count int) string {
	if count == 0 {
		return i18n.Shared(lang, "desktop.problems.scope.project")
	}
	return i18n.SharedFormat(lang, "desktop.problems.scope.projectCount", map[string]string{"count": strconv.Itoa(count)})
}

// problemSeverityMark is the icon and color of an LSP severity: red for errors, yellow for
// warnings, and blue for information and hints. Unknown severities read as information, as Core
// ranks them. The preview colors a diagnostic's line with the same color.
func (a *App) problemSeverityMark(severity int) (gfx.Icon, gfx.Color) {
	switch severity {
	case 1:
		return icons.CircleX, a.theme.Danger
	case 2:
		return icons.CircleAlert, a.colors.Warning
	default:
		return icons.Info, a.colors.Accent
	}
}

// problemsSeverityText is the name of a severity node: an LSP severity 1-4, or 0 for the
// diagnostics whose severity is missing or unknown.
func problemsSeverityText(lang i18n.Language, severity int) string {
	switch severity {
	case 1:
		return i18n.Shared(lang, "desktop.problems.severity.error")
	case 2:
		return i18n.Shared(lang, "desktop.problems.severity.warning")
	case 3:
		return i18n.Shared(lang, "desktop.problems.severity.information")
	case 4:
		return i18n.Shared(lang, "desktop.problems.severity.hint")
	default:
		return i18n.Shared(lang, "desktop.problems.severity.unknown")
	}
}

// problemsGroupingText is the name of a grouping of the problems tree.
func problemsGroupingText(lang i18n.Language, grouping string) string {
	switch grouping {
	case core.ProblemsGroupBySeverity:
		return i18n.Shared(lang, "desktop.problems.group.severity")
	case core.ProblemsGroupByNone:
		return i18n.Shared(lang, "desktop.problems.group.none")
	default:
		return i18n.Shared(lang, "desktop.problems.group.file")
	}
}
