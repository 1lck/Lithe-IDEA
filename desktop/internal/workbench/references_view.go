package workbench

import (
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// referencesPanel declares the References tool window: a header per file over its references.
func (a *App) referencesPanel(c ui.C, p *project) {
	s := &a.editor.refs
	if s.project != p || s.rows == 0 {
		a.panelMessage(c, i18n.Shared(a.language(), "desktop.references.empty"), a.colors.Subtle)
		return
	}
	if s.list.Key == nil {
		s.list.Header = func(i int) bool { _, _, header := s.rowAt(i); return header }
		s.list.Label = s.rowLabel
	}
	opened := -1
	ui.List(c, &s.list, s.rows, func(row ui.ListRow) {
		group, index, header := s.rowAt(row.Index)
		if header {
			a.drawReferenceHeader(row, s.groups[group])
		} else if a.drawReferenceRow(row, group, index) {
			opened = row.Index
		}
	}).Label(i18n.Shared(a.language(), "desktop.semantics.references")).FillWidth().Grow(1).Shrink(1).MinHeight(0)
	if row, ok := s.list.Submitted(); ok {
		opened = row
	}
	if group, index, header := s.rowAt(opened); opened >= 0 && !header {
		if target, ok := s.target(group, index); ok {
			c.After(func() {
				a.performed("editor.references.open", surfaceButton)
				a.openReference(p, target)
			})
		}
	}
}

// target is the reference at index of group.
func (s *referencesState) target(group, index int) (core.PluginSemanticLocation, bool) {
	if group < 0 || group >= len(s.groups) || index < 0 || index >= len(s.groups[group].indices) {
		return core.PluginSemanticLocation{}, false
	}
	return s.targets[s.groups[group].indices[index]], true
}

// rowLabel names a row to assistive technology: a file's path, or a reference's line.
func (s *referencesState) rowLabel(i int) string {
	group, index, header := s.rowAt(i)
	if header {
		return s.groups[group].display
	}
	if s.groups[group].indices != nil && index >= 0 && index < len(s.groups[group].indices) {
		at := s.groups[group].indices[index]
		return s.groups[group].display + ":" + strconv.Itoa(s.targets[at].Range.Start.Line+1) + " " + s.previews[at]
	}
	return ""
}

func (a *App) drawReferenceHeader(row ui.ListRow, group usageGroup) {
	c := row.C
	row.Element.FillWidth().Height(referenceRowHeight).PadX(10).Items(ui.Center).Gap(6).Background(a.colors.Panel).Children(func() {
		ui.Text(c, group.display).Grow(1).Shrink(1).FontSize(12.5).Bold().Color(a.colors.Text).Ellipsis()
		ui.Text(c, strconv.Itoa(len(group.indices))).Shrink(0).FontSize(11.5).Color(a.colors.Subtle)
	})
}

// drawReferenceRow declares one reference and reports whether it was clicked.
func (a *App) drawReferenceRow(row ui.ListRow, group, index int) bool {
	s := &a.editor.refs
	target, ok := s.target(group, index)
	if !ok {
		return false
	}
	at := s.groups[group].indices[index]
	c := row.C
	position := strconv.Itoa(target.Range.Start.Line+1) + ":" + strconv.Itoa(target.Range.Start.UTF16Column+1)
	row.Element.FillWidth().Height(referenceRowHeight).PadX(10).Items(ui.Center).Gap(8).
		Hover(ui.Look{}.Background(a.colors.Hover)).Children(func() {
		ui.Text(c, position).Shrink(0).FontSize(11.5).Color(a.colors.Subtle).Width(52)
		ui.Text(c, s.previews[at]).Grow(1).Shrink(1).FontSize(12.5).Color(a.colors.Text).Ellipsis()
	})
	return row.Element.Clicked()
}
