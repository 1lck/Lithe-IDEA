package workbench

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The new-terminal menu: the button beside the Terminal tool window's new-terminal button,
// the menu it opens and its parts. termShellItems are the rows of the installed shells, by
// their place in the list.
var (
	termShells         = tree.ID(shellPage, "terminal-shells")
	termShellsMenu     = tree.ID(shellPage, "terminal-shells-menu")
	termShellsDismiss  = tree.ID(shellPage, "terminal-shells-dismiss")
	termShellsScroll   = tree.ID(shellPage, "terminal-shells-scroll")
	termShellItems     = tree.Sub(shellPage, tree.Name("terminal-shell-item"))
	termShellsSettings = tree.ID(shellPage, "terminal-shells-settings")
)

// shellMenu is what the new-terminal menu remembers between frames. The installed shells
// are looked for each time the menu opens, off the window thread, because finding them
// reads the disk; the list found last is shown meanwhile, so a menu opened again does not
// flash empty.
type shellMenu struct {
	open, loading bool
	// drawn says this frame declared the menu's button. A menu whose button left the
	// frame, because the tool window was hidden or the project closed, is closed.
	drawn  bool
	list   []localshell.Choice
	button ui.Box
}

// drawShellMenuButton declares the button that opens the new-terminal menu and, while it is
// open, the menu: a row for each installed shell, which opens a terminal running it, then
// the Terminal settings. A name only one installation has is shown alone, and a name two
// installations share carries the path, as the system's bash and Homebrew's do.
func (a *App) drawShellMenuButton(f *ui.Frame) {
	u := &a.term
	m := &u.shells
	m.drawn = true
	if a.toolIconButton(f, termShells, a.text.Terminal.ShellMenu, icons.ChevronDown, m.open, false, &m.button) {
		open := !m.open
		u.closeStripMenus()
		m.open = open
		if open {
			a.findShells()
		}
	}
	if !m.open {
		return
	}
	if f.Popup().At(0, 0).Fill().HitWith(termShellsDismiss, a.text.Errors.Dismiss, gfx.HitOptions{Role: gfx.RoleButton, SkipFocus: true, Backdrop: true}).Clicked() {
		m.open = false
		return
	}
	f.Popup().BelowBox(m.button, chromeMenuOffset, ui.Start).Width(tabMenuWidth).
		Background(a.theme.Popover).Border(1, a.theme.Border).Radius(chromeMenuRadius).Shadow(gfx.ShadowMD).
		HitWith(termShellsMenu, a.text.Terminal.ShellMenu, gfx.HitOptions{Role: gfx.RoleMenu, SkipFocus: true}).
		Children(func() {
			f.ScrollArea(termShellsScroll).FillWidth().MaxHeight(tabMenuMaxHeight).Pad(chromeMenuPadding).Gap(chromeMenuItems).Children(func() {
				switch {
				case len(m.list) == 0 && m.loading:
					a.drawShellMenuNote(f, a.text.Terminal.DetectingShells)
				case len(m.list) == 0:
					a.drawShellMenuNote(f, a.text.Terminal.NoShells)
				default:
					for i, label := range localshell.Labels(m.list, a.text.Terminal.ShellWithPath) {
						if a.drawMenuAction(f, termShellItems.At(i), icons.SquareTerminal, label) {
							u.actions = append(u.actions, tabAction{kind: actionNew, shell: m.list[i].Path})
							m.open = false
						}
					}
				}
				a.drawMenuDivider(f)
				if a.drawMenuAction(f, termShellsSettings, icons.Settings, a.text.Terminal.Settings) {
					m.open = false
					a.openTerminalSettings(surfaceMenu)
				}
			})
		})
}

// drawShellMenuNote declares the line the new-terminal menu shows in place of the shells
// while they are looked for or when none was found.
func (a *App) drawShellMenuNote(f *ui.Frame, text string) {
	f.Row().Height(chromeMenuRow).Shrink(0).Items(ui.Center).PadX(chromeEdge).Children(func() {
		f.Text(text).Color(a.colors.Subtle).LineHeight(chromeLineHeight)
	})
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

// endShellMenuFrame closes the new-terminal menu when the frame just declared did not draw
// its button, and readies the mark for the next frame.
func (u *terminalUI) endShellMenuFrame() {
	if !u.shells.drawn {
		u.shells.open = false
	}
	u.shells.drawn = false
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
