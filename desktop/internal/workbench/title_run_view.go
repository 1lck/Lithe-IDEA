package workbench

import (
	"path"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
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
			item := menu.Item(configuration.Name).Icon(icons.Play).Chosen(chosen != nil && chosen.ID == id)
			// A configuration that cannot run here stays choosable, so it can be edited from the
			// title bar, and says why Run will not start it.
			if configuration.Unavailable() {
				item.Icon(icons.CircleAlert).Description(a.runConfigMenuNote(*configuration))
			}
			if item.Clicked() {
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
			if s.hidden > 0 {
				menu.Item(hiddenRunConfigurations(lang, s.hidden)).Disabled(true)
			}
		}
		// A saved file Core did not read is named by its file name, which fits the menu, and
		// opens in the editor so it can be fixed; a directory has nothing to open.
		for _, ignored := range s.ignored {
			label := i18n.SharedFormat(lang, "desktop.runConfig.documentIgnored", map[string]string{"file": path.Base(ignored)})
			item := menu.Item(label).Icon(icons.CircleAlert)
			if path.Ext(ignored) == "" {
				item.Disabled(true)
			} else if item.Clicked() {
				file := filepath.Join(p.root, filepath.FromSlash(ignored))
				c.After(func() { a.openFile(p, file) })
			}
		}
		menu.Separator()
		if menu.Item(i18n.Shared(lang, "desktop.runConfig.newConfigurationEllipsis")).Icon(icons.Plus).Clicked() {
			c.After(func() {
				a.performed("run.configuration.dialog", surfaceToolbar)
				a.openRunConfigDialog(p, "")
			})
		}
		if menu.Item(i18n.Shared(lang, "native.editConfiguration")).Icon(icons.Pencil).Clicked() {
			c.After(func() { a.editRunConfigurations(p) })
		}
	})
	if !open {
		a.title.runConfigOpen = false
	}
}

// runConfigMenuNote is the line under a configuration the menu cannot run: the short platform
// note of the dialog's + menu when this system cannot run its kind, which fits the menu's
// width, or the reason Run would give.
func (a *App) runConfigMenuNote(configuration core.RunConfiguration) string {
	if availability := configuration.Availability; availability != nil && availability.Code == "unsupportedPlatform" {
		return runConfigTypeNote(a.language(), core.RunConfigurationType{Provider: configuration.Provider, Availability: availability})
	}
	return a.runConfigUnavailableText(configuration)
}
