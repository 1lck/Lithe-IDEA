package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// debugSessionRow lists the live sessions at the top of the Debug window. The window
// shows the one picked, and its threads, stack, variables, output and evaluation
// follow it. A child session is labeled with the session that started it.
func (a *App) debugSessionRow(c ui.C, p *project) {
	d := &p.debug
	if len(d.sessions) == 0 {
		return
	}
	indexes := make([]int, len(d.sessions))
	for index := range indexes {
		indexes[index] = index
	}
	selected := d.current
	label := i18n.Shared(a.language(), "desktop.debug.session")
	ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).PadX(8).Items(ui.Center).Children(func() {
		if ui.Select(c, &selected, indexes, func(index int) string {
			return a.debugSessionLabel(d.sessions[index])
		}).Label(label).Grow(1); selected != d.current {
			index := selected
			c.After(func() { p.debug.selectSession(index) })
		}
	})
}

// debugSessionLabel names one session in the picker.
func (a *App) debugSessionLabel(session *debugSession) string {
	name := session.adapter.Declaration.DisplayName
	if session.parent == nil {
		return name
	}
	return name + " - " + a.text.Debug.Child.StartedBy(session.parent.adapter.Declaration.DisplayName)
}
