package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

// terminalMenu declares the context menu of terminal t's control: copy the selection, paste
// the clipboard, select everything, clear, start a new shell once the old one ended, and close
// the tab, as the old client's terminal offered.
func (a *App) terminalMenu(c ui.C, name string, box ui.Box, t *terminal) {
	p := a.project
	if p == nil {
		return
	}
	lang := a.language()
	ui.ContextMenu(c.Key("menu"+name), box, func(menu *ui.MenuItems) {
		menu.WidthRange(180, 260)
		if menu.Item(i18n.Shared(lang, "menu.copy")).Disabled(!t.view.HasSelection()).Clicked() {
			text := t.view.SelectionText()
			c.After(func() {
				a.performed("terminal.copy", surfaceMenu)
				_ = app.SetClipboardText(text)
			})
		}
		if menu.Item(i18n.Shared(lang, "menu.paste")).Clicked() {
			c.After(func() {
				a.performed("terminal.paste", surfaceMenu)
				t.view.PasteClipboard()
				a.focusTerminal(t.id)
			})
		}
		if menu.Item(i18n.Shared(lang, "menu.selectAll")).Clicked() {
			c.After(func() {
				a.performed("terminal.selectAll", surfaceMenu)
				t.view.SelectAll()
			})
		}
		menu.Separator()
		if menu.Item(i18n.Shared(lang, "ui.clear")).Clicked() {
			c.After(func() {
				a.performed("terminal.clear", surfaceMenu)
				t.view.Clear()
			})
		}
		if t.view.Ended() && menu.Item(i18n.Shared(lang, "native.restart")).Clicked() {
			c.After(func() {
				a.performed("terminal.restart", surfaceMenu)
				t.view.Restart()
			})
		}
		menu.Separator()
		if menu.Item(i18n.Shared(lang, "terminal.contextClose")).Clicked() {
			id := t.id
			c.After(func() {
				a.performed("terminal.close", surfaceMenu)
				a.requestCloseTerminal(p, id)
			})
		}
	})
}
