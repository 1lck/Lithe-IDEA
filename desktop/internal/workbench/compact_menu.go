package workbench

import (
	"runtime"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file is the compact menu of the title bar on Windows and Linux (matrix ids
// workbench-compact-menu-bar and windows-file-menu-settings). macOS keeps the system menu bar and
// shows nothing here. The menu opens from a button at the start of the bar and lists the commands of
// the command catalog (commands.go) by group, each group as a submenu. Every item runs the same
// command the Find Action list runs. The File menu leads with Settings. The bar's project and branch
// controls stay where they are; the menu opens beside them.

// compactMenuGroup is one submenu of the compact menu: its title and the command groups it lists.
type compactMenuGroup struct {
	title  func(i18n.CommandMessages) string
	groups []string
}

// compactMenuGroups are the submenus in the order the bar lists them.
func compactMenuGroups(t i18n.CommandMessages) []compactMenuGroup {
	return []compactMenuGroup{
		{title: func(t i18n.CommandMessages) string { return t.GroupApp }, groups: []string{t.GroupApp, t.GroupProject}},
		{title: func(t i18n.CommandMessages) string { return t.GroupEditor }, groups: []string{t.GroupEditor, t.GroupSearch}},
		{title: func(t i18n.CommandMessages) string { return t.GroupView }, groups: []string{t.GroupView, t.GroupToolWindows}},
		{title: func(t i18n.CommandMessages) string { return t.GroupGit }, groups: []string{t.GroupGit}},
		{title: func(t i18n.CommandMessages) string { return t.GroupRun }, groups: []string{t.GroupRun}},
		{title: func(t i18n.CommandMessages) string { return t.GroupTerminal }, groups: []string{t.GroupTerminal}},
	}
}

// compactMenuButton declares the compact menu's button at the start of the title bar and the menu
// while it is open. It is declared on Windows and Linux only.
func (a *App) compactMenuButton(c ui.C) {
	if runtime.GOOS == "darwin" {
		return
	}
	k := c.Part("compact-menu")
	open := a.title.menuOpen
	button := ui.Row(k).Height(chromeIconButton).Shrink(0).Items(ui.Center).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(k), i18n.Shared(a.language(), "desktop.menu.open"), gfx.HitOptions{
			Role:       gfx.RoleButton,
			Cursor:     gfx.PointerCursorHand,
			Expandable: true,
			Expanded:   open,
		})
	if open {
		button = button.Background(a.colors.Active)
	} else {
		button = a.chromeHover(button)
	}
	button.Children(func() {
		ui.Icon(k, icons.Ellipsis).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Text)
	})
	if button.Clicked() {
		c.After(func() { a.title.menuOpen = !a.title.menuOpen })
	}
	if open {
		a.compactMenu(c, button)
	}
}

// compactMenu declares the menu of the groups beside the button. Choosing an item runs its command
// and closes the menu; a click outside closes it too.
func (a *App) compactMenu(c ui.C, anchor ui.Box) {
	open := true
	commands := a.commands()
	ui.Menu(c, anchor, &open, func(menu *ui.MenuItems) {
		menu.WidthRange(220, 320)
		for _, group := range compactMenuGroups(a.text.Commands) {
			menu.Sub(group.title(a.text.Commands), func(sub *ui.MenuItems) {
				for _, cmd := range compactMenuItems(commands, group.groups) {
					if sub.Item(cmd.title).Disabled(!cmd.enabled).Clicked() {
						run := cmd
						c.After(func() { a.runCommand(run) })
						a.title.menuOpen = false
					}
				}
			})
		}
	})
	if !open {
		c.After(func() { a.title.menuOpen = false })
	}
}

// compactMenuItems are the commands of groups, in the order the catalog lists them, with Settings
// first when it is among them, so the File menu leads with it.
func compactMenuItems(commands []command, groups []string) []command {
	var out []command
	for _, cmd := range commands {
		if inGroups(cmd.group, groups) {
			out = append(out, cmd)
		}
	}
	for i, cmd := range out {
		if cmd.id == "settings.open" && i > 0 {
			out = append([]command{cmd}, append(out[:i:i], out[i+1:]...)...)
			break
		}
	}
	return out
}

// inGroups reports whether group is one of groups.
func inGroups(group string, groups []string) bool {
	for _, g := range groups {
		if g == group {
			return true
		}
	}
	return false
}
