package workbench

import (
	"context"
	"runtime"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/appicon"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// welcomePage makes the start screen's page on first use.
func (a *App) welcomePage() *ui.Page {
	w := &a.welcome
	if w.page == nil {
		w.page = ui.NewPage(ui.PageConfig{
			View: a.welcomeView, Tree: &tree, Root: "welcome",
			Theme: &a.theme, Invalidator: &a.invalidator,
		})
	}
	return w.page
}

// drawWelcome puts the start screen in the region of the window Frame that is
// left for it.
func (a *App) drawWelcome(f *ui.Frame) {
	page := a.welcomePage()
	f.Slot().Fill().Draw(func(d *ui.DrawContext) { page.Draw(d.Canvas, d.Rect, a.welcomeView) })
}

func (a *App) welcomeSeparator() gfx.Color {
	if a.colors.Dark {
		return gfx.RGB24(0x26282C)
	}
	return gfx.RGB24(0xDFE1E5)
}

// welcomeView is the screen shown while no project is open: a sidebar with the
// application's name and the places it leads to, and the list of recent projects.
func (a *App) welcomeView(c ui.C) {
	a.collectWelcomeBranches(c)
	surface := gfx.RGB24(0xFFFFFF)
	if a.colors.Dark {
		surface = gfx.RGB24(0x191A1C)
	}
	ui.Row(c).Fill().PadSides(0, 8, 8, 8).Background(surface).Children(func() {
		a.welcomeSidebar(c)
		ui.Column(c).Width(1).FillHeight().Shrink(0).Children(func() {
			ui.Row(c).FillWidth().Height(titleBarHeight).Shrink(0)
			ui.Row(c).FillWidth().Grow(1).Background(a.welcomeSeparator())
		})
		a.welcomeContent(c)
		// The macOS welcome title sits after the traffic lights; the workbench hides it.
		title := ui.Row(c).Absolute().Top(0).Right(0)
		if runtime.GOOS == "darwin" {
			leading, _ := app.TitlebarInsets()
			title.Left(max(84, leading+10)).Height(32).Items(ui.Center)
		} else {
			title.Left(0).Height(titleBarHeight).Center()
		}
		title.Children(func() {
			ui.Text(c, i18n.Shared(a.language(), "welcome.title")).FontSize(13).Bold()
		})
	})
}

func (a *App) welcomeSidebar(c ui.C) {
	sidebar := gfx.RGB24(0xF7F8FA)
	if a.colors.Dark {
		sidebar = gfx.RGB24(0x191A1C)
	}
	selection := gfx.RGB24(0xD4E2FF)
	if a.colors.Dark {
		selection = gfx.RGB24(0x2A4371)
	}
	ui.Column(c).Width(welcomeSidebarWidth).Shrink(0).Background(sidebar).Children(func() {
		// The system's window buttons sit in this strip, so it stays empty; it only has
		// to move the window like a title bar does.
		ui.Row(c).FillWidth().Height(titleBarHeight).MovesWindow()
		ui.Row(c).Items(ui.Center).Gap(11).PadSides(22, 20, 34, 20).Children(func() {
			ui.Image(c, appicon.Welcome()).Size(28, 28).Shrink(0)
			ui.Column(c).Children(func() {
				ui.Text(c, a.text.App.Name).FontSize(13)
				ui.Text(c, a.version).Muted().FontSize(11)
			})
		})
		ui.Column(c).PadX(14).Children(func() {
			// Projects marks the selected location; it is not an action on this screen.
			ui.Row(c).FillWidth().Height(32).Items(ui.Center).Gap(9).PadX(14).Radius(4).Background(selection).Children(func() {
				ui.Icon(c, icons.Folder).Size(15, 15).Color(a.colors.Subtle)
				ui.Text(c, a.text.Welcome.Projects).FontSize(13)
			})
		})
		ui.Spacer(c)
		ui.Row(c).PadSides(0, 14, 14, 14).Children(func() {
			if ui.Button(c, a.text.Welcome.Settings).Icon(icons.Settings).IconOnly().Ghost().Clicked() {
				c.After(func() { a.openSettings(surfaceButton) })
			}
		})
	})
}

func (a *App) welcomeContent(c ui.C) {
	w := &a.welcome
	ui.Column(c).Grow(1).Children(func() {
		ui.Row(c).FillWidth().Height(titleBarHeight).MovesWindow()
		ui.Row(c).FillWidth().Height(68).Items(ui.Center).Gap(10).PadX(17).Children(func() {
			ui.TextField(c, &w.search, a.text.Welcome.SearchLabel, a.text.Welcome.SearchPlaceholder).
				Icon(icons.Search).Width(214).MinWidth(0).Shrink(1)
			ui.Spacer(c)
			if ui.Button(c, a.text.Welcome.NewProject).MinWidth(72).Clicked() {
				c.After(func() { a.openNewProject(surfaceButton) })
			}
			if ui.Button(c, a.text.Welcome.Open).Outline().MinWidth(72).Clicked() {
				c.After(func() { a.chooseProject(surfaceButton) })
			}
			more := ui.Button(c, i18n.Shared(a.language(), "desktop.clone.more")).Outline().MinWidth(72)
			if more.Clicked() {
				w.moreOpen = !w.moreOpen
			}
			ui.Menu(c, more, &w.moreOpen, func(menu *ui.MenuItems) {
				menu.WidthRange(220, 220)
				if menu.Item(i18n.Shared(a.language(), "desktop.clone.title")).Clicked() {
					c.After(func() { a.openClone(surfaceMenu) })
				}
			})
		})
		ui.Row(c).FillWidth().Height(1).Shrink(0).PadX(12).Children(func() {
			ui.Row(c).Fill().Background(a.welcomeSeparator())
		})
		a.welcomeProjects(c)
	})
}

// welcomeProjects is the recent project list, or what stands in for it.
func (a *App) welcomeProjects(c ui.C) {
	w := &a.welcome
	if len(a.recent) == 0 {
		w.menuPath, w.menuOpen = "", false
		ui.Column(c).Grow(1).Center().Gap(4).Children(func() {
			ui.Text(c, a.text.Welcome.EmptyTitle).Bold()
			ui.Text(c, a.text.Welcome.EmptyHint).Muted()
		})
		return
	}
	query := w.needle()
	// shown lists the recent entries the filter keeps, by their place in a.recent.
	shown := make([]int, 0, len(a.recent))
	for i := range a.recent {
		row := w.row(a.recent[i].Path, len(a.recent))
		if query == "" || strings.Contains(row.needle, query) {
			shown = append(shown, i)
		}
	}
	if len(shown) == 0 {
		ui.Text(c, a.text.Welcome.NoMatches).Muted().TextCenter().PadY(24)
		return
	}
	w.list.Key = func(i int) int { return w.rowID(a.recent[shown[i]].Path) }
	w.list.Label = func(i int) string { return w.row(a.recent[shown[i]].Path, len(a.recent)).name }
	// open is acted on after the list is declared: opening a project replaces the recent
	// list, which this loop is still reading.
	open := ""
	ui.List(c, &w.list, len(shown), func(row ui.ListRow) {
		entry := &a.recent[shown[row.Index]]
		info := w.row(entry.Path, len(a.recent))
		// A project whose folder is gone stays clickable, so opening it can say why
		// it did not open; the mark only warns beforehand.
		missing := ""
		if a.missing[entry.Path] {
			missing = a.text.Welcome.Missing
		}
		branch := w.branches[entry.Path]
		rowHeight := float32(welcomeRowHeight)
		if branch != "" {
			rowHeight += 20
		}
		item := row.Element.FillWidth().Height(rowHeight).Items(ui.Center).Gap(12).PadX(12).
			Radius(a.theme.Metrics.RadiusItem()).
			Hover(ui.Look{}.Background(a.colors.Hover)).
			Pressed(ui.Look{}.Background(a.colors.Active))
		path := entry.Path
		ui.ContextMenu(row.C, row.Element, a.welcomeMenuItems(row.C, path))
		item.Children(func() {
			ui.Column(row.C).FillHeight().Shrink(0).PadSides(14, 0, 0, 0).Children(func() {
				avatar := projectAvatar(row.C, info.identity, welcomeAvatarSize)
				if missing != "" {
					// The warning beside the name says why; the faded badge says it at a glance.
					avatar.Opacity(identityMissingOpacity)
				}
			})
			ui.Column(row.C).Grow(1).PadSides(8, 0, 0, 0).Children(func() {
				ui.Text(row.C, info.name).Ellipsis()
				ui.Text(row.C, info.path).Ellipsis().Muted().FontSize(a.theme.Metrics.FontSizeS)
				if branch != "" {
					ui.Row(row.C).Height(16).Items(ui.Center).Gap(4).Children(func() {
						ui.Icon(row.C, icons.RecentProjectVCS(a.colors.Dark)).Size(16, 16).Shrink(0).Color(a.colors.Subtle)
						ui.Text(row.C, branch).Ellipsis().Muted().FontSize(a.theme.Metrics.FontSizeS)
					})
				}
			})
			if missing != "" {
				ui.Text(row.C, missing).Shrink(0).Color(a.colors.Warning).FontSize(a.theme.Metrics.FontSizeS)
			}
			// The button is named by the row's part, so the row can tell whether the
			// keyboard is on it while it is hidden again.
			moreC := row.C.Part("more")
			moreID := ui.ID(moreC)
			menuShown := w.menuOpen && w.menuPath == path
			if w.menuPath == path && !w.menuOpen {
				// The closing paint still declares the button, which the keyboard
				// returns to; it is forgotten once that paint is over.
				a.post(func(a *App) {
					if !a.welcome.menuOpen && a.welcome.menuPath == path {
						a.welcome.menuPath = ""
					}
				})
			}
			if item.State().Hovered || item.State().Focused || row.Focused() || w.menuPath == path || c.Canvas().Focused() == moreID {
				more := ui.Row(moreC).Size(24, 24).Shrink(0).Center().Radius(a.theme.Metrics.RadiusItem()).
					HitWith(moreID, a.text.Welcome.MoreActions, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).
					Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
				more.Children(func() { ui.Icon(moreC, icons.Ellipsis).Size(16, 16).Color(a.colors.Subtle) })
				if more.Clicked() {
					w.menuPath, w.menuOpen = path, !menuShown
				}
				if menuShown {
					ui.Menu(moreC, more, &w.menuOpen, a.welcomeMenuItems(row.C, path))
				}
			}
		})
		if row.Element.Clicked() {
			open = entry.Path
		}
	}).Label(a.text.Welcome.Projects).Grow(1).PadX(22).PadY(4)
	if path, ok := w.list.Submitted(); ok && path >= 0 && path < len(shown) {
		open = a.recent[shown[path]].Path
	}
	if open != "" {
		w.menuPath, w.menuOpen = "", false
		c.After(func() {
			a.performed("workspace.recent.open", surfaceButton)
			a.openProject(open)
		})
	}
}

// welcomeMenuItems are the actions of one recent project. They apply to the path
// the menu was opened for, never to the row index, which can change when the
// recent list is reduced.
func (a *App) welcomeMenuItems(c ui.C, path string) func(*ui.MenuItems) {
	return func(menu *ui.MenuItems) {
		menu.WidthRange(220, 220)
		if !a.missing[path] {
			if menu.Item(a.text.Welcome.MenuOpen).Clicked() {
				c.After(func() {
					a.performed("workspace.recent.open", surfaceMenu)
					a.openProject(path)
				})
			}
			label := a.text.Welcome.MenuReveal
			switch runtime.GOOS {
			case "windows":
				label = i18n.Shared(a.language(), "desktop.welcome.menuRevealWindows")
			case "linux":
				label = i18n.Shared(a.language(), "desktop.welcome.menuRevealOther")
			}
			if menu.Item(label).Clicked() {
				c.After(func() { a.revealRecent(path) })
			}
		}
		if menu.Item(a.text.Welcome.MenuRemove).Clicked() {
			c.After(func() {
				a.performed("workspace.recent.remove", surfaceMenu)
				a.reduceRecent(a.recent, core.RemoveRecent(path), true)
			})
		}
	}
}

// revealRecent shows a recent project in the system's file browser.
func (a *App) revealRecent(path string) {
	a.performed("workspace.recent.reveal", surfaceMenu)
	a.background(nil, 0, func(context.Context) func(*App) {
		err := app.RevealPath(path)
		return func(a *App) {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_reveal_recent", documentLogError(err)))
				a.notify(a.text.Errors.OpenFailed(err.Error()))
			}
		}
	})
}

// projectAvatar is the project's badge: its initials over its gradient.
func projectAvatar(c ui.C, identity projectIdentity, side float32) ui.Box {
	size, mono := identityFont(identity.initials, side)
	badge := ui.Row(c).Size(side, side).Shrink(0).Center().
		Radius(side*identityRadius).
		Gradient(ui.ToBottomRight, identity.start, identity.end)
	return badge.Children(func() {
		// The line is as tall as the badge, so the letters sit in its middle on whole pixels.
		text := ui.Text(c, identity.initials).FontSize(size).Bold().Color(identityInk).LineHeight(side)
		if mono {
			text.Mono()
		}
	})
}
