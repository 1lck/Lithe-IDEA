package workbench

import (
	"context"
	"os"
	"path/filepath"
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

// The identities of the start screen's controls.
var (
	welcomeSearch      = tree.ID(welcomePage, "search")
	welcomeNew         = tree.ID(welcomePage, "new")
	welcomeOpen        = tree.ID(welcomePage, "open")
	welcomeMore        = tree.ID(welcomePage, "more")
	welcomeMoreDismiss = tree.ID(welcomePage, "more-dismiss")
	welcomeMorePanel   = tree.ID(welcomePage, "more-panel")
	welcomeClone       = tree.ID(welcomePage, "clone")
	welcomeNavProjects = tree.ID(welcomePage, "nav-projects")
	welcomeNavSettings = tree.ID(welcomePage, "nav-settings")
	welcomeList        = tree.ID(welcomePage, "list")
	welcomeMenuDismiss = tree.ID(welcomePage, "menu-dismiss")
	welcomeMenuPanel   = tree.ID(welcomePage, "menu-panel")
	welcomeMenuOpen    = tree.ID(welcomePage, "menu-open")
	welcomeMenuReveal  = tree.ID(welcomePage, "menu-reveal")
	welcomeMenuRemove  = tree.ID(welcomePage, "menu-remove")
	// welcomeRows identifies the recent project rows: welcomeRows.At(i) is a.recent[i],
	// whether or not the filter currently shows it.
	welcomeRows  = tree.Sub(welcomePage, tree.Name("rows"))
	welcomeMenus = tree.Sub(welcomePage, tree.Name("row-menus"))
)

const (
	welcomeSidebarWidth = 224
	welcomeRowHeight    = 48
	// The original welcome list uses the same 20-point badge as the project switcher.
	welcomeAvatarSize = 20
)

// welcomeState is what the start screen remembers between frames.
type welcomeState struct {
	// search filters the project list. App.Config hands it to the platform text
	// service, so it lives as long as the window.
	search                           ui.Field
	moreOpen, moreFocus, moreRestore bool

	// query is the search text folded for matching and queryText the text it was folded
	// from, so the fold runs when the text changes and not on every frame.
	queryText string
	query     string

	// rows holds what a recent project shows, by path. The list repaints on every hover,
	// and splitting names, shortening paths and folding case for each row each time would
	// allocate for nothing, so it is derived once per path.
	rows map[string]welcomeRow
	// branches are read on one cancellable worker. Newer recent lists supersede
	// older reads without allowing stale results to reintroduce removed entries.
	branches         map[string]string
	branchGeneration uint64
	branchCancel     context.CancelFunc
	branchRunning    bool
	branchPending    bool
	branchClosed     bool
	// home is the user's home folder, read once; paths under it show as "~/...".
	home     string
	homeRead bool
	// menuPath is stable across sorting and filtering, unlike a row index.
	menuPath string
	// A context click opens at the pointer; the ellipsis opens beside its row.
	menuAtPointer bool
	menuPosition  gfx.Point
	menuFocus     gfx.ID
	// restoreMenuFocus identifies the row whose menu button regains focus after Escape.
	restoreMenuFocus string
}

// welcomeRow is the derived text of one recent project.
type welcomeRow struct {
	// name is the folder's name and path its location, shortened with "~" when it is
	// under the home folder.
	name, path string
	// needle is the full path folded for matching the search text.
	needle string
	// identity is the project's badge, derived with the text because it hashes the path.
	identity projectIdentity
}

// row returns what the project at path shows. listed is the length of the recent list;
// the cache is dropped when it outgrows the list by a margin, so projects that left
// the list do not stay in memory.
func (w *welcomeState) row(path string, listed int) welcomeRow {
	if r, ok := w.rows[path]; ok {
		return r
	}
	if !w.homeRead {
		w.home, _ = os.UserHomeDir()
		w.homeRead = true
	}
	name := filepath.Base(path)
	r := welcomeRow{
		name:     name,
		path:     welcomeShorten(path, w.home),
		needle:   strings.ToLower(path),
		identity: identityOf(path, name),
	}
	if w.rows == nil {
		w.rows = make(map[string]welcomeRow, 32)
	} else if len(w.rows) >= 2*listed+16 {
		clear(w.rows)
	}
	w.rows[path] = r
	return r
}

// needle is the search text folded for matching; empty shows every project.
func (w *welcomeState) needle() string {
	text := w.search.Text()
	if text != w.queryText {
		w.queryText = text
		w.query = strings.ToLower(strings.TrimSpace(text))
	}
	return w.query
}

// welcomeShorten writes a path under home as "~" plus the rest. The separator is
// checked so /Users/ann does not shorten /Users/anna.
func welcomeShorten(path, home string) string {
	if home == "" || !strings.HasPrefix(path, home) {
		return path
	}
	rest := path[len(home):]
	if rest != "" && rest[0] != os.PathSeparator {
		return path
	}
	return "~" + rest
}

// drawWelcome is the screen shown while no project is open: a sidebar with the
// application's name and the places it leads to, and the list of recent projects.
func (a *App) drawWelcome(f *ui.Frame) {
	a.startWelcomeBranchReads()
	surface := gfx.RGB24(0xFFFFFF)
	if a.colors.Dark {
		surface = gfx.RGB24(0x191A1C)
	}
	f.Row().Fill().PadSides(0, 8, 8, 8).Background(surface).Children(func() {
		a.drawWelcomeSidebar(f)
		f.Column().Width(1).FillHeight().Shrink(0).Children(func() {
			f.Row().FillWidth().Height(titleBarHeight).Shrink(0)
			f.Row().FillWidth().Grow(1).Background(a.welcomeSeparator())
		})
		a.drawWelcomeContent(f)
		// The macOS welcome title sits after the traffic lights; the workbench hides it.
		title := f.Row().Absolute().Top(0).Right(0)
		if runtime.GOOS == "darwin" {
			leading, _ := app.TitlebarInsets()
			title.Left(max(84, leading+10)).Height(32).Items(ui.Center)
		} else {
			title.Left(0).Height(titleBarHeight).Center()
		}
		title.Children(func() {
			f.Text(i18n.Shared(a.language(), "welcome.title")).FontSize(13).Bold()
		})
	})
}

func (a *App) welcomeSeparator() gfx.Color {
	if a.colors.Dark {
		return gfx.RGB24(0x26282C)
	}
	return gfx.RGB24(0xDFE1E5)
}

func (a *App) drawWelcomeSidebar(f *ui.Frame) {
	sidebar := gfx.RGB24(0xF7F8FA)
	if a.colors.Dark {
		sidebar = gfx.RGB24(0x191A1C)
	}
	selection := gfx.RGB24(0xD4E2FF)
	if a.colors.Dark {
		selection = gfx.RGB24(0x2A4371)
	}
	f.Column().Width(welcomeSidebarWidth).Shrink(0).Background(sidebar).Children(func() {
		// The system's window buttons sit in this strip, so it stays empty; it only has
		// to move the window like a title bar does.
		f.Row().FillWidth().Height(titleBarHeight).MovesWindow()
		f.Row().Items(ui.Center).Gap(11).PadSides(22, 20, 34, 20).Children(func() {
			f.Image(appicon.Welcome()).Size(28, 28).Shrink(0)
			f.Column().Children(func() {
				f.Text(a.text.App.Name).FontSize(13)
				f.Text(a.version).Muted().FontSize(11)
			})
		})
		f.Column().PadX(14).Children(func() {
			// Projects marks the selected location; it is not an action on this screen.
			f.Row().FillWidth().Height(32).Items(ui.Center).Gap(9).PadX(14).
				Radius(4).Background(selection).
				HitWith(welcomeNavProjects, a.text.Welcome.Projects, gfx.HitOptions{Role: gfx.RoleButton, Selected: true}).Children(func() {
				f.Icon(icons.Folder).Size(15, 15).Color(a.colors.Subtle)
				f.Text(a.text.Welcome.Projects).FontSize(13)
			})
		})
		f.Spacer()
		f.Row().PadSides(0, 14, 14, 14).Children(func() {
			if a.logIconButton(f, welcomeNavSettings, a.text.Welcome.Settings, icons.Settings, false, false) {
				a.openSettings(surfaceButton)
			}
		})
	})
}

func (a *App) drawWelcomeContent(f *ui.Frame) {
	var moreAnchor ui.Box
	f.Column().Grow(1).Children(func() {
		f.Row().FillWidth().Height(titleBarHeight).MovesWindow()
		f.Row().FillWidth().Height(68).Items(ui.Center).Gap(10).PadX(17).Children(func() {
			var input ui.Box
			frame := f.Row().Width(214).MinWidth(0).Shrink(1).Height(30).Items(ui.Center).PadX(8).Gap(6).
				Border(1, a.theme.Input).Radius(a.theme.Metrics.RadiusControl).
				Draw(func(d *ui.DrawContext) {
					d.Canvas.HitLabel(welcomeSearch, d.Rect, a.text.Welcome.SearchLabel, false)
				}).
				Focused(ui.Look{}.Border(a.theme.Primary).Ring(1, a.theme.Primary))
			frame.Children(func() {
				f.Icon(icons.Search).Size(15, 15).Shrink(0).Color(a.colors.Subtle)
				input = f.FieldBase(&a.welcome.search, welcomeSearch, a.text.Welcome.SearchLabel, a.text.Welcome.SearchPlaceholder).
					Grow(1).MinWidth(0).Height(28).FontSize(13).Color(a.colors.Text)
			})
			frame.StateFrom(input)
			f.Spacer()
			if f.Button(welcomeNew, a.text.Welcome.NewProject).MinWidth(72).Height(28).Clicked() {
				a.openNewProject(surfaceButton)
			}
			if f.Button(welcomeOpen, a.text.Welcome.Open).Outline().MinWidth(72).Height(28).Clicked() {
				a.chooseProject(surfaceButton)
			}
			moreAnchor = f.Button(welcomeMore, i18n.Shared(a.language(), "desktop.clone.more")).Outline().MinWidth(72).Height(28)
			if moreAnchor.Clicked() {
				a.welcome.moreOpen = !a.welcome.moreOpen
				a.welcome.moreFocus = a.welcome.moreOpen
			}
		})
		f.Row().FillWidth().Height(1).Shrink(0).PadX(12).Children(func() {
			f.Row().Fill().Background(a.welcomeSeparator())
		})
		a.drawWelcomeProjects(f)
	})
	if a.welcome.moreOpen {
		dismissed := f.Popup().At(0, 0).Fill().HitWith(welcomeMoreDismiss, a.text.Errors.Dismiss,
			gfx.HitOptions{Role: gfx.RoleButton, SkipFocus: true, Backdrop: true}).Clicked()
		cloned := false
		f.Popup().BelowBox(moreAnchor, 4, ui.End).Width(220).
			Background(a.theme.Popover).Border(1, a.theme.Border).Radius(chromeMenuRadius).Shadow(gfx.ShadowMD).
			HitWith(welcomeMorePanel, a.text.Welcome.MoreActions, gfx.HitOptions{Role: gfx.RoleMenu, SkipFocus: true}).
			Pad(chromeMenuPadding).Children(func() {
			cloned = a.drawBranchMenuItem(f, welcomeClone, i18n.Shared(a.language(), "desktop.clone.title"))
		})
		if dismissed || cloned {
			a.welcome.moreOpen = false
			a.welcome.moreFocus = false
		}
		if cloned {
			a.openClone(surfaceMenu)
		}
		if a.welcome.moreFocus {
			if f.Canvas().Focused() == welcomeClone {
				a.welcome.moreFocus = false
			} else {
				f.Canvas().RequestFocus(welcomeClone)
			}
		}
	} else if a.welcome.moreRestore {
		f.Canvas().RequestFocus(welcomeMore)
		a.welcome.moreRestore = false
	}
}

// drawWelcomeProjects is the recent project list, or what stands in for it.
func (a *App) drawWelcomeProjects(f *ui.Frame) {
	if len(a.recent) == 0 {
		a.welcome.menuPath = ""
		a.welcome.restoreMenuFocus = ""
		f.Column().Grow(1).Center().Gap(4).Children(func() {
			f.Text(a.text.Welcome.EmptyTitle).Bold()
			f.Text(a.text.Welcome.EmptyHint).Muted()
		})
		return
	}
	query := a.welcome.needle()
	shown := 0
	// open is acted on after the list is declared: opening a project replaces the recent
	// list, which this loop is still reading.
	open := ""
	var menuAnchor ui.Box
	hasMenu := false
	hasRestore := false
	f.ScrollArea(welcomeList).Grow(1).PadX(22).PadY(4).Gap(4).Children(func() {
		for i := range a.recent {
			entry := &a.recent[i]
			row := a.welcome.row(entry.Path, len(a.recent))
			if query != "" && !strings.Contains(row.needle, query) {
				continue
			}
			shown++
			// A project whose folder is gone stays clickable, so opening it can say why
			// it did not open; the mark only warns beforehand.
			missing := ""
			if a.missing[entry.Path] {
				missing = a.text.Welcome.Missing
			}
			rowID := welcomeRows.At(i)
			menuID := welcomeMenus.At(i)
			branch := a.welcome.branches[entry.Path]
			rowHeight := float32(welcomeRowHeight)
			if branch != "" {
				rowHeight += 20
			}
			item := f.Row().Height(rowHeight).Items(ui.Center).Gap(12).PadX(12).
				Radius(a.theme.Metrics.RadiusItem()).
				HitWith(rowID, row.name, gfx.HitOptions{
					Role:        gfx.RoleButton,
					Cursor:      gfx.PointerCursorHand,
					Description: row.path,
					Hint:        missing,
				}).
				Hover(ui.Look{}.Background(a.colors.Hover)).
				Pressed(ui.Look{}.Background(a.colors.Active))
			item.Children(func() {
				f.Column().FillHeight().Shrink(0).PadSides(14, 0, 0, 0).Children(func() {
					avatar := drawProjectAvatar(f, row.identity, welcomeAvatarSize)
					if missing != "" {
						// The warning beside the name says why; the faded badge says it at a glance.
						avatar.Opacity(identityMissingOpacity)
					}
				})
				f.Column().Grow(1).PadSides(8, 0, 0, 0).Children(func() {
					f.Text(row.name).Ellipsis()
					f.Text(row.path).Ellipsis().Muted().FontSize(a.theme.Metrics.FontSizeS)
					if branch != "" {
						f.Row().Height(16).Items(ui.Center).Gap(4).Children(func() {
							f.Icon(icons.RecentProjectVCS(a.colors.Dark)).Size(16, 16).Shrink(0).Color(a.colors.Subtle)
							f.Text(branch).Ellipsis().Muted().FontSize(a.theme.Metrics.FontSizeS)
						})
					}
				})
				if missing != "" {
					f.Text(missing).Shrink(0).Color(a.colors.Warning).FontSize(a.theme.Metrics.FontSizeS)
				}
				if item.State().Hovered || item.State().Focused || f.Canvas().Hovered() == menuID || f.Canvas().Focused() == menuID || a.welcome.menuPath == entry.Path || a.welcome.restoreMenuFocus == entry.Path {
					if a.logIconButton(f, menuID, a.text.Welcome.MoreActions, icons.Ellipsis, a.welcome.menuPath == entry.Path, false) {
						a.welcome.menuPath = entry.Path
						a.welcome.restoreMenuFocus = ""
						a.welcome.menuAtPointer = false
						a.welcome.menuFocus = a.welcomeInitialMenuFocus(entry.Path)
					}
				}
			})
			if a.welcome.restoreMenuFocus == entry.Path {
				hasRestore = true
				if f.Canvas().Focused() == menuID {
					a.welcome.restoreMenuFocus = ""
				} else {
					f.Canvas().RequestFocus(menuID)
				}
			}
			if event, ok := f.Canvas().PointerOn(rowID); ok && event.Kind == gfx.PointerDown && event.Button == gfx.PointerButtonSecondary {
				a.welcome.menuPath = entry.Path
				a.welcome.restoreMenuFocus = ""
				a.welcome.menuAtPointer = true
				a.welcome.menuFocus = a.welcomeInitialMenuFocus(entry.Path)
				// Leave room for all three rows, even when the click is near a window edge.
				a.welcome.menuPosition = gfx.Point{
					X: max(8, min(event.X, event.Viewport.Width-228)),
					Y: max(8, min(event.Y, event.Viewport.Height-120)),
				}
				f.Canvas().Consume()
			}
			if a.welcome.menuPath == entry.Path {
				menuAnchor, hasMenu = item, true
			}
			if item.Clicked() {
				open = entry.Path
			}
		}
		if shown == 0 {
			f.Text(a.text.Welcome.NoMatches).Muted().TextCenter().PadY(24)
		}
	})
	if !hasRestore {
		a.welcome.restoreMenuFocus = ""
	}
	if hasMenu {
		a.drawWelcomeProjectMenu(f, menuAnchor)
	} else {
		a.welcome.menuPath = ""
	}
	if open != "" {
		a.welcome.menuPath = ""
		a.performed("workspace.recent.open", surfaceButton)
		a.openProject(open)
	}
}

// drawWelcomeProjectMenu applies actions to the path captured when the menu opened,
// never to the row index, which can change when the recent list is reduced.
func (a *App) drawWelcomeProjectMenu(f *ui.Frame, anchor ui.Box) {
	path := a.welcome.menuPath
	dismissed := f.Popup().At(0, 0).Fill().
		HitWith(welcomeMenuDismiss, a.text.Errors.Dismiss, gfx.HitOptions{Role: gfx.RoleButton, SkipFocus: true, Backdrop: true, PassSecondary: true}).Clicked()
	var open, reveal, remove bool
	panel := f.Popup()
	if a.welcome.menuAtPointer {
		panel = panel.At(a.welcome.menuPosition.X, a.welcome.menuPosition.Y)
	} else {
		panel = panel.BelowBox(anchor, 4, ui.End)
	}
	panel.Width(220).
		Background(a.theme.Popover).Border(1, a.theme.Border).Radius(chromeMenuRadius).Shadow(gfx.ShadowMD).
		HitWith(welcomeMenuPanel, a.text.Welcome.MoreActions, gfx.HitOptions{Role: gfx.RoleMenu, SkipFocus: true}).
		Pad(chromeMenuPadding).Gap(chromeMenuItems).Children(func() {
		if !a.missing[path] {
			open = a.drawBranchMenuItem(f, welcomeMenuOpen, a.text.Welcome.MenuOpen)
			label := a.text.Welcome.MenuReveal
			switch runtime.GOOS {
			case "windows":
				label = i18n.Shared(a.language(), "desktop.welcome.menuRevealWindows")
			case "linux":
				label = i18n.Shared(a.language(), "desktop.welcome.menuRevealOther")
			}
			reveal = a.drawBranchMenuItem(f, welcomeMenuReveal, label)
		}
		remove = a.drawBranchMenuItem(f, welcomeMenuRemove, a.text.Welcome.MenuRemove)
	})
	if !a.welcome.menuFocus.IsZero() {
		if f.Canvas().Focused() == a.welcome.menuFocus {
			a.welcome.menuFocus = gfx.ID{}
		} else {
			f.Canvas().RequestFocus(a.welcome.menuFocus)
		}
	}
	if dismissed || open || reveal || remove {
		a.welcome.menuPath = ""
	}
	switch {
	case open:
		a.performed("workspace.recent.open", surfaceMenu)
		a.openProject(path)
	case reveal:
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
	case remove:
		a.performed("workspace.recent.remove", surfaceMenu)
		a.reduceRecent(a.recent, core.RemoveRecent(path), true)
	}
}

func (a *App) welcomeInitialMenuFocus(path string) gfx.ID {
	if a.missing[path] {
		return welcomeMenuRemove
	}
	return welcomeMenuOpen
}

// welcomeMenuKey keeps Tab within an open menu; Escape is handled by onKey.
func (a *App) welcomeMenuKey(event gfx.KeyEvent) gfx.EventResult {
	if a.project != nil || a.welcome.menuPath == "" || event.Release || event.Key != gfx.KeyTab {
		return gfx.EventResult{}
	}
	items := []gfx.ID{welcomeMenuOpen, welcomeMenuReveal, welcomeMenuRemove}
	if a.missing[a.welcome.menuPath] {
		items = items[2:]
	}
	index := -1
	for i, id := range items {
		if event.Target == id {
			index = i
			break
		}
	}
	if event.Modifiers&gfx.ModifierShift != 0 {
		if index < 0 {
			index = 0
		}
		index = (index + len(items) - 1) % len(items)
	} else {
		index = (index + 1) % len(items)
	}
	a.welcome.menuFocus = items[index]
	return gfx.EventResult{Handled: true, Repaint: true}
}
