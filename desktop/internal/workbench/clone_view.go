package workbench

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// cloneView declares the Clone Repository dialog while it is open.
func (a *App) cloneView(c ui.C) {
	cl := &a.clone
	if !cl.open {
		return
	}
	language := a.language()
	sourceLabel := i18n.Shared(language, "desktop.clone.source")
	parentLabel := i18n.Shared(language, "desktop.clone.parent")
	nameLabel := i18n.Shared(language, "desktop.clone.name")
	submitted, cancelled, confirmed := false, false, false
	closed := ui.ModalWith(c, &cl.open, i18n.Shared(language, "desktop.clone.title"), ui.ModalSpec{Width: 570}, func() {
		ui.Column(c).FillWidth().Gap(10).Children(func() {
			ui.Text(c, sourceLabel)
			if ui.TextField(c, &cl.source, sourceLabel, i18n.Shared(language, "desktop.clone.sourcePlaceholder")).FillWidth().Disabled(cl.busy).Submitted() {
				submitted = true
			}
			ui.Text(c, parentLabel)
			ui.Row(c).FillWidth().Gap(8).Children(func() {
				ui.TextField(c, &cl.parent, parentLabel, "").Grow(1).Disabled(cl.busy)
				if ui.Button(c, i18n.Shared(language, "desktop.clone.choose")).Outline().Disabled(cl.busy).Clicked() {
					c.After(a.chooseCloneParent)
				}
			})
			ui.Text(c, nameLabel)
			if ui.TextField(c, &cl.name, nameLabel, i18n.Shared(language, "desktop.clone.namePlaceholder")).FillWidth().Disabled(cl.busy).Submitted() {
				submitted = true
			}
			if cl.err != "" {
				ui.Paragraph(c, cl.err, 3).Color(a.theme.Danger)
			}
		})
	}, func() {
		cancelled = ui.Button(c, i18n.Shared(language, "desktop.clone.cancel")).Outline().Disabled(cl.cancelling).Clicked()
		label := i18n.Shared(language, "desktop.clone.submit")
		if cl.busy {
			label = i18n.Shared(language, "desktop.clone.busy")
		}
		confirmed = ui.Button(c, label).Disabled(cl.busy || strings.TrimSpace(cl.source.Text()) == "" || cl.parent.Text() == "" || cl.name.Text() == "").Clicked()
	})
	switch {
	case closed:
		// Escape, the scrim and the close button end the dialog like Cancel: a
		// running clone is asked to stop first.
		cl.open = true
		c.After(a.cancelClone)
	case cancelled:
		c.After(a.cancelClone)
	case confirmed || submitted:
		c.After(a.submitClone)
	}
}
