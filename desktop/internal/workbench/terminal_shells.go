package workbench

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/vivaui/viva/ui"
)

// shellMenu is what the new-terminal menu remembers between frames. The installed shells are
// looked for each time the menu opens, off the window thread, because finding them reads the
// disk; the list found last is shown meanwhile, so a menu opened again does not flash empty.
type shellMenu struct {
	open, loading bool
	// drawn says this paint declared the menu's button. A menu whose button left the paint,
	// because the tool window was hidden or the project closed, is closed.
	drawn bool
	list  []localshell.Choice
}

// shellMenuButton declares the button that opens the new-terminal menu and, while it is open,
// the menu: a row for each installed shell, which opens a terminal running it, then the
// Terminal settings. A name only one installation has is shown alone, and a name two
// installations share carries the path, as the system's bash and Homebrew's do.
func (a *App) shellMenuButton(c ui.C) {
	u := &a.term
	m := &u.shells
	m.drawn = true
	button, clicked := a.toolIconButton(c.Part("shells"), a.text.Terminal.ShellMenu, icons.ChevronDown, m.open, false)
	wasOpen := m.open
	if m.open {
		ui.Menu(c, button, &m.open, func(menu *ui.MenuItems) {
			menu.WidthRange(tabMenuWidth, tabMenuWidth)
			switch {
			case len(m.list) == 0 && m.loading:
				menu.Item(a.text.Terminal.DetectingShells).Disabled(true)
			case len(m.list) == 0:
				menu.Item(a.text.Terminal.NoShells).Disabled(true)
			default:
				for i, label := range localshell.Labels(m.list, a.text.Terminal.ShellWithPath) {
					if menu.Item(label).Icon(icons.SquareTerminal).Clicked() {
						shell := m.list[i].Path
						c.After(func() { a.openToolTerminal(shell) })
					}
				}
			}
			menu.Separator()
			if menu.Item(a.text.Terminal.Settings).Icon(icons.Settings).Clicked() {
				c.After(func() { a.openTerminalSettings(surfaceMenu) })
			}
		})
	}
	if clicked && !wasOpen {
		u.closeStripMenus()
		m.open = true
		c.After(a.findShells)
	}
}

// openToolTerminal opens another terminal in the Terminal tool window, running shell, or the
// Terminal setting's when shell is empty, and gives it the keyboard.
func (a *App) openToolTerminal(shell string) {
	if t := a.newTerminal(a.project, shell); t != nil {
		a.focusTerminal(t.id)
	}
}

// findShells looks for the installed shells off the window thread, unless a search is
// already running, and hands the list to the menu when it is done.
func (a *App) findShells() {
	m := &a.term.shells
	if m.loading {
		return
	}
	m.loading = true
	list := a.listShells
	a.background(nil, 0, func(context.Context) func(*App) {
		found := list()
		return func(a *App) {
			a.term.shells.loading = false
			a.term.shells.list = found
		}
	})
}

// endFrame closes the new-terminal menu when the paint just declared did not draw its
// button, and readies the mark for the next paint.
func (m *shellMenu) endFrame() {
	if !m.drawn {
		m.open = false
	}
	m.drawn = false
}

// setTerminalShell keeps the shell new terminals run, a path or empty for the user's login
// shell. Terminals already open keep the shell they started with.
func (a *App) setTerminalShell(value string) {
	if a.settings.TerminalShell == value {
		return
	}
	a.settings.TerminalShell = value
	if a.settingsWindow != nil {
		a.settingsWindow.Invalidate()
	}
	a.saveSettings()
}
