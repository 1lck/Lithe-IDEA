package workbench

import (
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	// problemsRowHeight is the height of a file header and of a diagnostic row.
	problemsRowHeight = 22
)

// drawProblemsPanel puts the Problems tool window in the room under the panel header.
//
// Transitional adapter: the window still paints through a Frame, so the component is hosted
// by a Page that is registered with the page host. Delete this function and call
// problemsPanel directly once the workbench root window is a Page.
func (a *App) drawProblemsPanel(f *ui.Frame, p *project) {
	if a.problemsHost.page == nil {
		a.problemsHost = a.newGitHost("problems", func(c ui.C) {
			if a.project != nil {
				a.problemsPanel(c, a.project)
			}
		}, nil, panelPage{wheel: verticalWheel})
	}
	f.Slot().Fill().Draw(a.problemsHost.draw)
}

// problemsPanel declares the Problems tool window of an open project: the files that have
// diagnostics, each as a header over its diagnostics, in the order Core gave them.
func (a *App) problemsPanel(c ui.C, p *project) {
	a.requestProblemsQuery(p)
	v := &a.problems
	switch {
	case v.failure != nil:
		a.panelMessage(c, a.text.Errors.Core(v.failure.Error()), a.theme.Danger)
		return
	case v.rows == 0:
		message := i18n.SharedFormat(a.language(), "native.noProblemsIn", map[string]string{"arg1": p.name})
		a.panelMessage(c, message, a.colors.Subtle)
		return
	}
	if v.list.Key == nil {
		v.list.Header = func(i int) bool { _, _, header := v.rowAt(i); return header }
		v.list.Label = v.rowLabel
	}
	opened := -1
	ui.List(c, &v.list, v.rows, func(row ui.ListRow) {
		group, index, header := v.rowAt(row.Index)
		if header {
			a.drawProblemsGroupHeader(row, v.result.Groups[group])
		} else if a.drawProblemsRow(row, v, group, index) {
			opened = row.Index
		}
	}).Label(i18n.Shared(a.language(), "native.problems")).FillWidth().Grow(1).Shrink(1).MinHeight(0)
	if row, ok := v.list.Submitted(); ok {
		opened = row
	}
	if group, index, header := v.rowAt(opened); opened >= 0 && !header {
		if item, ok := v.diagnostic(group, index); ok && item.FileKey != "" {
			c.After(func() {
				a.performed("workspace.problems.open", surfaceButton)
				a.openFileAtPosition(p, item.FileKey, item.Line, item.Column)
			})
		}
	}
}

// diagnostic is the diagnostic at index of group, and false when either is out of range.
func (v *problemsView) diagnostic(group, index int) (core.ProblemsDiagnostic, bool) {
	if group < 0 || group >= len(v.result.Groups) {
		return core.ProblemsDiagnostic{}, false
	}
	indices := v.result.Groups[group].Indices
	if index < 0 || index >= len(indices) || indices[index] < 0 || indices[index] >= len(v.diagnostics) {
		return core.ProblemsDiagnostic{}, false
	}
	return v.diagnostics[indices[index]], true
}

// rowLabel names row i to the list: a file's path, or a diagnostic's message.
func (v *problemsView) rowLabel(i int) string {
	group, index, header := v.rowAt(i)
	if header {
		return v.result.Groups[group].DisplayPath
	}
	if item, ok := v.diagnostic(group, index); ok {
		return item.Message
	}
	return ""
}

// drawProblemsGroupHeader declares one file's heading. It is not clickable: opening a file
// happens on one of its diagnostics. The heading of the file in view stays at the top.
func (a *App) drawProblemsGroupHeader(row ui.ListRow, group core.ProblemsGroup) {
	c := row.C
	row.Element.FillWidth().Height(problemsRowHeight).PadX(10).Items(ui.Center).Gap(6).Background(a.colors.Panel).Children(func() {
		ui.Text(c, group.DisplayPath).Grow(1).Shrink(1).FontSize(12.5).Bold().Color(a.colors.Text).Ellipsis()
		ui.Text(c, a.text.Status.Problems(len(group.Indices))).Shrink(0).FontSize(11.5).Color(a.colors.Subtle)
	})
}

// drawProblemsRow declares one diagnostic of a group and reports whether it was clicked.
func (a *App) drawProblemsRow(row ui.ListRow, v *problemsView, group, index int) bool {
	item, ok := v.diagnostic(group, index)
	if !ok {
		return false
	}
	c := row.C
	icon, tint := a.problemSeverityMark(item.Severity)
	position := strconv.Itoa(item.Line+1) + ":" + strconv.Itoa(item.Column+1)
	row.Element.FillWidth().Height(problemsRowHeight).PadX(10).Items(ui.Center).Gap(6).
		Hover(ui.Look{}.Background(a.colors.Hover)).Children(func() {
		ui.Icon(c, icon).Size(14, 14).Shrink(0).Color(tint)
		ui.Text(c, item.Message).Grow(1).Shrink(1).FontSize(12.5).Color(a.colors.Text).Ellipsis()
		if item.Source != "" {
			ui.Text(c, item.Source).Shrink(1).FontSize(11.5).Color(a.colors.Subtle).Ellipsis().MaxWidth(80)
		}
		ui.Text(c, position).Shrink(0).FontSize(11.5).Color(a.colors.Subtle)
	})
	return row.Element.Clicked()
}

// problemSeverityMark is the icon and tint of an LSP severity. Unknown
// severities read as information, as Core ranks them.
func (a *App) problemSeverityMark(severity int) (gfx.Icon, gfx.Color) {
	switch severity {
	case 1:
		return icons.CircleX, a.theme.Danger
	case 2:
		return icons.CircleAlert, a.colors.Warning
	default:
		return icons.Info, a.colors.Subtle
	}
}
