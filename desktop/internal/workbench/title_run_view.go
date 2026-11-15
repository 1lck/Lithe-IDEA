package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
)

// Widths of the run configuration menu: wide enough for Edit Configuration…, and no wider
// than a long configuration name needs.
const (
	runConfigMenuMin = 224
	runConfigMenuMax = 360
)

// titleRunConfigMenu declares the menu under the title bar's run configuration button: Current
// File, the project's configurations while they are read or once they are, and the entry
// that edits them. Choosing one is what Run and Debug start next.
func (a *App) titleRunConfigMenu(c ui.C, anchor ui.Box) {
	p := a.project
	if p == nil {
		a.title.runConfigOpen = false
		return
	}
	lang := a.language()
	open := true
	ui.Menu(c, anchor, &open, func(menu *ui.MenuItems) {
		menu.WidthRange(runConfigMenuMin, runConfigMenuMax)
		chosen := p.titleConfiguration()
		if menu.Item(a.text.Title.CurrentFile).Icon(icons.FileCode).Chosen(chosen == nil).Clicked() {
			c.After(func() { a.chooseTitleConfiguration(p, "") })
		}
		menu.Separator()
		menu.Label(i18n.Shared(lang, "native.runConfigurations"))
		s := &p.runConfigs
		for index := range s.list {
			configuration := &s.list[index]
			id := configuration.ID
			if menu.Item(configuration.Name).Icon(icons.Play).Chosen(chosen != nil && chosen.ID == id).Clicked() {
				c.After(func() { a.chooseTitleConfiguration(p, id) })
			}
		}
		switch {
		case !p.runConfigsSettled():
			menu.Item(i18n.Shared(lang, "native.loading")).Disabled(true)
		case s.failure != "":
			menu.Item(i18n.SharedFormat(lang, "desktop.runConfig.loadFailed", map[string]string{"reason": s.failure})).Disabled(true)
		case p.build.failed != "":
			menu.Item(p.build.failed).Disabled(true)
		case len(s.list) == 0:
			menu.Item(i18n.Shared(lang, "desktop.title.noRunConfigurations")).Disabled(true)
		}
		menu.Separator()
		if menu.Item(i18n.Shared(lang, "native.editConfiguration")).Icon(icons.Pencil).Clicked() {
			c.After(func() { a.editRunConfigurations(p) })
		}
	})
	if !open {
		a.title.runConfigOpen = false
	}
}
