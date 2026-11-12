package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
)

// navigationPopup declares the Go to Line:Column dialog while it is open. It
// belongs to the document that was selected when it opened: another project or
// document closes it.
func (a *App) navigationPopup(c ui.C) {
	v, p := &a.navigation, a.project
	if p == nil || !v.open {
		return
	}
	if v.project != p || p.selectedDocument(p.docs.group) == nil || p.selectedDocument(p.docs.group).id != v.document {
		a.closeNavigation()
		return
	}
	a.syncNavigation(p)
	language := a.language()
	label := i18n.Shared(language, "desktop.navigation.label")
	cancelled, confirmed, submitted := false, false, false
	closed := ui.ModalWith(c, &v.open, i18n.Shared(language, "desktop.navigation.title"),
		ui.ModalSpec{Width: 360, InitialFocus: navigationField, NoClose: true}, func() {
			ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
				ui.Text(c, label)
				submitted = ui.TextFieldID(c, navigationField, &v.input, label, "").Grow(1).MinWidth(0).Submitted()
			})
		}, func() {
			cancelled = ui.Button(c, a.text.Settings.Cancel).Outline().Clicked()
			confirmed = ui.Button(c, a.text.Settings.OK).Disabled(v.target == nil || v.validated != v.input.Text()).Clicked()
		})
	if v.selectAll {
		if input := a.root.TextInput(app.TextInputContext{ID: navigationField}); input != nil && input.Editor != nil {
			input.Editor.SetSelection(text.Range{Start: 0, End: input.Editor.RuneCount()})
			v.selectAll = false
		}
	}
	switch {
	case closed || cancelled:
		v.open = true
		c.After(a.closeNavigation)
	case confirmed || submitted:
		c.After(func() {
			if v.open && v.project == p {
				a.syncNavigation(p)
				a.confirmNavigation(p)
			}
		})
	}
}
