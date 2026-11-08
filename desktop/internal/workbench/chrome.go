package workbench

import (
	"context"
	"fmt"

	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/flex"
	"github.com/vivaui/viva/ui"
)

// The identities of the title bar's and the status bar's own controls. The
// rearrangeable buttons are chromeButtons (ids.go), not listed here.
var (
	// chromeProjectButton opens the project menu.
	chromeProjectButton = tree.ID(shellPage, "project-menu")
	// chromeBranchButton is the branch beside the project, which opens the branch popup.
	chromeBranchButton = tree.ID(shellPage, "branch-menu")
	// chromeMenuDismiss is the window-wide backdrop behind the open project menu: a press
	// on it closes the menu.
	chromeMenuDismiss = tree.ID(shellPage, "project-menu-dismiss")
	// chromeMenuPanel is the menu's panel. It takes the presses on its padding, which would
	// otherwise fall through to the backdrop and close the menu.
	chromeMenuPanel  = tree.ID(shellPage, "project-menu-panel")
	chromeMenuScroll = tree.ID(shellPage, "project-menu-scroll")
	// The three actions at the top of the menu.
	chromeMenuNew   = tree.ID(shellPage, "project-menu-new")
	chromeMenuOpen  = tree.ID(shellPage, "project-menu-open")
	chromeMenuClone = tree.ID(shellPage, "project-menu-clone")
	// chromeMenuCurrent is the row of the open project, and chromeMenuClose the button on it
	// that closes the project.
	chromeMenuCurrent = tree.ID(shellPage, "project-menu-current")
	chromeMenuClose   = tree.ID(shellPage, "project-menu-close")
	// chromeMenuRecent identifies the recent project entries of the menu:
	// chromeMenuRecent.At(i) is a.recent[i], however many entries are listed before it.
	chromeMenuRecent = tree.Sub(shellPage, tree.Name("project-menu-recent"))
	// chromeStatusPath is the project name on the left of the status bar.
	chromeStatusPath = tree.ID(shellPage, "status-path")
	// gearMenuDismiss is the action the settings button's open menu reports when the user
	// presses outside it or hits Escape; it is also the menu's focus scope.
	gearMenuDismiss  = tree.ID(shellPage, "gear-menu-dismiss")
	gearMenuSettings = tree.ID(shellPage, "gear-menu-settings")
	gearMenuPlugins  = tree.ID(shellPage, "gear-menu-plugins")
	gearMenuLogs     = tree.ID(shellPage, "gear-menu-logs")
	gearMenuTheme    = tree.ID(shellPage, "gear-menu-theme")
	gearMenuKeymap   = tree.ID(shellPage, "gear-menu-keymap")
)

// gearMenuWidth is the width of the settings button's menu, which holds five short items
// and their shortcuts.
const gearMenuWidth = 224

const (
	// chromeIconButton is the side of a title bar icon button and the height of the
	// other title bar controls; chromeToolButton is the side of a stripe button. Both
	// are even and fit their bar with a whole pixel above and below, so nothing is
	// laid out on a half pixel.
	chromeIconButton = 28
	chromeToolButton = 32
	chromeIconSize   = 16
	// chromeMarkSize is the size of a chevron or a status glyph.
	chromeMarkSize = 12
	chromeGap      = 4
	chromeEdge     = 8
	// chromeLineHeight is the height of a line of text in the chrome. The default is
	// the font size plus seven, which is odd for the 13 point body text, and an odd
	// line in an even button would sit on a half pixel.
	chromeLineHeight = 16
	chromeStatusItem = 20
	// chromeProjectMax and chromeBranchMax cap the width of the names in the title bar,
	// which are cut with an ellipsis beyond it.
	chromeProjectMax = 240
	chromeBranchMax  = 160
	// chromeDot is the status mark of the language server.
	chromeDot = 8
	// chromeAvatarTitle is the side of the project's badge in the title bar, and
	// chromeTitleGap the space between that badge, the name and the chevron, a little wider
	// than the space between the bar's controls.
	chromeAvatarTitle = 20
	chromeTitleGap    = 6

	// The project menu is chromeMenuWidth wide, hangs chromeMenuOffset under its button and is
	// at most chromeMenuMaxHeight tall: a longer list scrolls inside it. It lists at most
	// chromeMenuRecents recent projects besides the open one.
	chromeMenuWidth     = 320
	chromeMenuMaxHeight = 520
	chromeMenuRadius    = 8
	chromeMenuOffset    = 4
	chromeMenuRecents   = 10
	// chromeMenuAvatar is the side of a project's badge in the menu, chromeMenuProject the
	// least height of a project's row and chromeMenuRowPad the room above and below its
	// text. A row with a branch line is taller than the least.
	chromeMenuAvatar  = 28
	chromeMenuProject = 46
	chromeMenuRowPad  = 6
	// chromeMenuTitle is the height of the line that names a section of the menu, and
	// chromeMenuClosing the side of the button that closes the open project.
	chromeMenuTitle   = 24
	chromeMenuClosing = 20
	// chromeMenuGap is the space between the parts of a row, and chromeMenuItems the space
	// between the rows.
	chromeMenuGap   = 8
	chromeMenuItems = 2
	// The settings button's dropdown menu lays its rows out with fixed heights that Viva does
	// not export. The surface has to be as tall as its rows, because a surface that is too
	// short hides the last of them, so they are repeated here. The project menu uses the
	// padding and the row height too, for its panel and for its actions.
	chromeMenuPadding   = 4
	chromeMenuRow       = 32
	chromeMenuSeparator = 9

	// chromeDragDim is the opacity the source of a drag keeps while its ghost follows
	// the pointer.
	chromeDragDim = 0.4
)

// titleState is what the title bar remembers between frames. The zero value is a title
// bar with its menus closed.
type titleState struct {
	// projectOpen says the project menu is open.
	projectOpen bool
	// gearOpen says the settings button's menu is open.
	gearOpen bool
	// branches is the branch of each recent project the project menu has read, by path. The
	// empty string stands for a folder that is not a repository or whose status could not be
	// read. The map is allocated when the first answer arrives, and is dropped with the rest
	// of the state when the project closes.
	branches map[string]string
	// reading holds the paths whose status is being read, so a menu opened again while an
	// answer is on its way does not ask a second time.
	reading map[string]bool
}

// chromeBox gives the container of the rearrangeable button of catalog item i its
// identity, its looks and its place in the frame, and returns it for its content to be
// declared in. A container is used and not a flex Button because a Button shows text
// only: these buttons carry icons, take their colors from the palette and report their
// state to assistive technology. value is the reading of a status item, empty for the
// other buttons.
func (a *App) chromeBox(row flex.Box, i int, open bool, value string) flex.Box {
	it := catalog[i]
	label := it.label(a.text)
	if it.id == itemChanges {
		// The label of the changes item is a fixed "No changes"; the reading says how many.
		label = value
	}
	options := ui.HitOptions{Role: ui.RoleButton, Hint: a.text.Tools.DragHint, Selected: open, Value: value}
	if it.zone.surface() != surfaceStatus {
		// The status items only show a reading, so they do not offer a click.
		options.Cursor = ui.PointerCursorHand
	}
	row = row.Radius(a.theme.Metrics.RadiusItem()).
		HitWith(chromeButtons.At(i), label, options).
		Pressed(flex.Look{}.Background(a.colors.Active))
	if open {
		row = row.Background(a.colors.Active)
	} else {
		row = row.Hover(flex.Look{}.Background(a.colors.Hover))
	}
	if a.drag.active && a.drag.item == i {
		row = row.Opacity(chromeDragDim)
	}
	a.chrome.place(i, row)
	return row
}

// drawChromeGlyph declares a square button that shows the icon of catalog item i and
// reports a click on it. The icon is rest while the pointer is away and hover while it
// is over the button.
func (a *App) drawChromeGlyph(f *flex.Frame, i int, side float32, rest, hover ui.Color, open bool) bool {
	box := a.chromeBox(f.Row().Size(side, side).Shrink(0).Center(), i, open, "")
	box.Children(func() {
		f.Icon(*catalog[i].icon).Size(chromeIconSize, chromeIconSize).Color(rest).
			StateFrom(box).Hover(flex.Look{}.Color(hover))
	})
	return box.Clicked()
}

// drawTitleBar is the strip across the top of the workbench: the project, the branch
// and, at the trailing end, the buttons the user can arrange. The whole bar moves the
// window; the controls in it take their own presses.
func (a *App) drawTitleBar(f *flex.Frame) {
	// The system's window buttons sit at one end of the strip, so the content keeps clear
	// of them.
	leading, trailing := app.TitlebarInsets()
	// What a click asks for is done after the bar is declared. A button changes the
	// arrangement, which this loop is still reading.
	clicked, opening, branching, branched := -1, false, false, false
	var project, branch flex.Box
	f.Row().FillWidth().Height(titleBarHeight).Shrink(0).Background(a.colors.Chrome).
		Items(flex.Center).Gap(chromeGap).PadSides(0, trailing+chromeEdge, 0, leading+chromeEdge).
		MovesWindow().Children(func() {
		project, opening = a.drawChromeProject(f)
		branch, branched, branching = a.drawChromeBranch(f)
		f.Spacer()
		zoneBox := f.Row().Items(flex.Center).Gap(chromeGap).Children(func() {
			for _, i := range a.chrome.items[zoneTitle] {
				if a.drawChromeTitleButton(f, i) {
					clicked = i
				}
			}
		})
		a.chrome.placeZone(zoneTitle, zoneBox)
		// The line is out of the flow so that the buttons are centered in the whole bar.
		f.Row().Absolute().Left(0).Right(0).Bottom(0).Height(1).Background(a.colors.Line)
	})
	if opening {
		// The pointer cannot reach the button while the menu is open, because the menu's
		// backdrop lies over it, so a click on an open menu's button is the keyboard's, and it
		// closes the menu.
		if a.title.projectOpen {
			a.title.projectOpen = false
		} else {
			a.openProjectMenu()
		}
	}
	if branching {
		// As with the project menu, a click on the open popup's button is the keyboard's.
		if a.branch.open {
			a.closeBranches()
		} else {
			a.openBranches()
		}
	}
	if a.title.projectOpen {
		// The menu is declared in the frame that declared its button, because the button's
		// box is only valid until the frame ends. It comes after the bar so that its
		// backdrop and panel are hit before anything in the bar is.
		a.drawProjectMenu(f, project)
	}
	switch {
	case a.branch.open && !branched:
		// The project stopped being a repository, so the popup has no branch to hang off.
		a.closeBranches()
	case a.branch.open:
		a.drawBranchPopup(f, branch)
	}
	if clicked >= 0 {
		a.activate(clicked)
	}
}

// chromeHover gives a control the backgrounds the chrome's buttons take while the pointer
// is over them and while they are pressed.
func (a *App) chromeHover(box flex.Box) flex.Box {
	return box.Hover(flex.Look{}.Background(a.colors.Hover)).Pressed(flex.Look{}.Background(a.colors.Active))
}

// drawChromeProject declares the project's badge and name with the chevron that opens its
// menu. It returns the button, which the menu is placed under, and whether it was clicked.
func (a *App) drawChromeProject(f *flex.Frame) (flex.Box, bool) {
	open := a.title.projectOpen
	row := a.welcome.row(a.project.root, len(a.recent))
	button := f.Row().Height(chromeIconButton).Shrink(0).Items(flex.Center).Gap(chromeTitleGap).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(chromeProjectButton, a.text.Title.ProjectMenu, ui.HitOptions{
			Role:        ui.RoleButton,
			Cursor:      ui.PointerCursorHand,
			Value:       a.project.name,
			Description: row.path,
			Expandable:  true,
			Expanded:    open,
		}).
		Pressed(flex.Look{}.Background(a.colors.Active))
	if open {
		button = button.Background(a.colors.Active)
	} else {
		button = button.Hover(flex.Look{}.Background(a.colors.Hover))
	}
	button.Children(func() {
		drawProjectAvatar(f, row.identity, chromeAvatarTitle)
		f.Text(a.project.name).Bold().Color(a.colors.Text).LineHeight(chromeLineHeight).Ellipsis().MaxWidth(chromeProjectMax)
		f.Icon(icons.ChevronDown).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Subtle)
	})
	return button, button.Clicked()
}

// drawChromeTitleButton declares the title bar button of catalog item i and reports a
// click on it.
func (a *App) drawChromeTitleButton(f *flex.Frame, i int) bool {
	switch catalog[i].id {
	case itemRunConfig:
		box := a.chromeBox(f.Row().Height(chromeIconButton).Shrink(0).Items(flex.Center).Gap(chromeGap).PadX(chromeEdge), i, false, "")
		box.Children(func() {
			f.Icon(*catalog[i].icon).Size(chromeIconSize, chromeIconSize).Color(a.colors.Subtle)
			f.Text(a.text.Title.CurrentFile).Color(a.colors.Text).LineHeight(chromeLineHeight)
			f.Icon(icons.ChevronDown).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Subtle)
		})
		return box.Clicked()
	case itemTitleRun:
		// Run is the one button that keeps its color at rest: green says what it does.
		return a.drawChromeGlyph(f, i, chromeIconButton, a.colors.Success, a.colors.Success, false)
	}
	return a.drawChromeGlyph(f, i, chromeIconButton, a.colors.Text, a.colors.Text, false)
}

// drawStripe is the column of tool buttons at one side of the workbench. Each stripe
// stacks its top group first, leaves flexible space, then packs the split group directly
// above the bottom group at the stripe's end. The split group opens in the lower half of
// the side column; the bottom group opens in a half of the bottom area. All three zones
// are declared even when empty, because an empty zone is still a place a button can be
// dropped.
//
// While a tool button is dragged, every zone gets at least the height of a button, so an
// empty zone remains visible and can be hit. No separator is needed between the top and
// split groups: the flexible space makes their placement clear.
func (a *App) drawStripe(f *flex.Frame, left bool) {
	top, split, end := zoneLeftTop, zoneLeftBottom, zoneBottomLeft
	if !left {
		top, split, end = zoneRightTop, zoneRightBottom, zoneBottomRight
	}
	dragging := a.draggingToolButton()
	// As in the title bar, a click is acted on once the stripe is declared.
	clicked := -1
	f.Column().Width(stripeWidth).FillHeight().Shrink(0).Background(a.colors.Chrome).Pad(chromeGap).Children(func() {
		if i := a.drawChromeStripeZone(f, top, dragging); i >= 0 {
			clicked = i
		}
		f.Spacer()
		if i := a.drawChromeStripeZone(f, split, dragging); i >= 0 {
			clicked = i
		}
		if i := a.drawChromeStripeZone(f, end, dragging); i >= 0 {
			clicked = i
		}
		// The line on the editor's side is out of the flow, so the buttons sit in the
		// middle of the stripe.
		line := f.Row().Absolute().Top(0).Bottom(0).Width(1).Background(a.colors.Line)
		if left {
			line.Right(0)
		} else {
			line.Left(0)
		}
	})
	if clicked >= 0 {
		a.activate(clicked)
	}
}

// drawChromeStripeZone declares one zone of a stripe and returns the catalog index of
// the button clicked in it, or -1. Each zone is as high as its buttons; the spacer in
// drawStripe pushes the split and bottom groups to the stripe's end. While a tool button
// is dragged, every zone is at least one button high, which makes an empty zone a place
// the button can be dropped.
func (a *App) drawChromeStripeZone(f *flex.Frame, z zone, dragging bool) int {
	clicked := -1
	column := f.Column().Gap(chromeGap)
	if dragging {
		column = column.MinHeight(chromeToolButton)
	}
	column = column.Children(func() {
		for _, i := range a.chrome.items[z] {
			open := a.chrome.isOpen(i)
			rest := a.colors.Subtle
			if open {
				rest = a.colors.Text
			}
			if a.drawChromeGlyph(f, i, chromeToolButton, rest, a.colors.Text, open) {
				clicked = i
			}
		}
	})
	a.chrome.placeZone(z, column)
	return clicked
}

// drawStatusBar is the strip across the bottom of the workbench: the project on the
// left, and at the trailing end the readouts the user can arrange.
func (a *App) drawStatusBar(f *flex.Frame) {
	clicked := -1
	f.Row().FillWidth().Height(statusBarHeight).Shrink(0).Background(a.colors.Chrome).
		Items(flex.Center).PadX(chromeEdge).Children(func() {
		f.Text(a.project.name).Grow(1).Ellipsis().FontSize(a.theme.Metrics.FontSizeS).LineHeight(chromeLineHeight).
			Color(a.colors.Subtle).
			HitWith(chromeStatusPath, a.text.Status.Path, ui.HitOptions{Role: ui.RoleStatus, Value: a.project.name, SkipFocus: true})
		zoneBox := f.Row().Items(flex.Center).Gap(chromeGap).Children(func() {
			for _, i := range a.chrome.items[zoneStatus] {
				if a.drawChromeStatusItem(f, i) {
					clicked = i
				}
			}
		})
		a.chrome.placeZone(zoneStatus, zoneBox)
		f.Row().Absolute().Left(0).Right(0).Top(0).Height(1).Background(a.colors.Line)
	})
	if clicked >= 0 {
		a.activate(clicked)
	}
}

// drawChromeStatusItem declares the status bar item of catalog item i and reports a
// click on it.
func (a *App) drawChromeStatusItem(f *flex.Frame, i int) bool {
	text := a.chromeStatusText(i)
	box := a.chromeBox(f.Row().Height(chromeStatusItem).Shrink(0).Items(flex.Center).Gap(chromeGap).PadX(chromeEdge), i, false, text)
	box.Children(func() {
		switch catalog[i].id {
		case itemLock:
			f.Icon(*catalog[i].icon).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Subtle)
		case itemHealth:
			f.Icon(*catalog[i].icon).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Success)
		case itemLSP:
			f.Row().Size(chromeDot, chromeDot).Shrink(0).Radius(chromeDot / 2).Background(a.colors.Subtle)
			a.drawChromeStatusText(f, text)
		default:
			a.drawChromeStatusText(f, text)
		}
	})
	return box.Clicked()
}

func (a *App) drawChromeStatusText(f *flex.Frame, text string) {
	f.Text(text).FontSize(a.theme.Metrics.FontSizeS).LineHeight(chromeLineHeight).Color(a.colors.Subtle)
}

// chromeStatusText is the reading a status item shows, empty for the items that are only
// a glyph. The drag shows the same words on the ghost of the item.
func (a *App) chromeStatusText(i int) string {
	switch catalog[i].id {
	case itemCaret:
		if a.project != nil {
			if doc := a.project.selectedDocument(a.project.docs.group); doc != nil {
				line, column := doc.view.CaretUTF16()
				return fmt.Sprintf("%d:%d", line+1, column+1)
			}
		}
		return "1:1"
	case itemLSP:
		return a.text.Status.LSPNotStarted
	case itemMemory:
		return a.text.Status.MemoryValue(int(a.status.memory >> 20))
	case itemFPS:
		return a.text.Status.FPSValue(a.status.fps)
	case itemChanges:
		if a.project != nil {
			if count, ok := a.project.git.changeCount(); ok && count > 0 {
				return a.text.Status.Changes(count)
			}
		}
		return a.text.Status.NoChanges
	}
	return ""
}

// openProjectMenu opens the project menu and asks for the branch of each recent project it
// lists. The branches are read again on every opening, because a project's branch changes
// while the menu is shut; the ones read before are shown until the new answer arrives.
func (a *App) openProjectMenu() {
	a.title.projectOpen = true
	a.closeBranches()
	var buf [chromeMenuRecents]int
	for _, i := range a.menuRecents(&buf) {
		// A folder that is gone has no branch to read, and the menu shows it faded.
		if path := a.recent[i].Path; !a.missing[path] {
			a.loadMenuBranch(path)
		}
	}
}

// loadMenuBranch reads the branch of the project at path in the background and keeps it
// in the title state for the menu to show. A path whose answer is still on its way is not
// asked for again.
func (a *App) loadMenuBranch(path string) {
	if a.title.reading[path] {
		return
	}
	if a.title.reading == nil {
		a.title.reading = make(map[string]bool, chromeMenuRecents)
	}
	a.title.reading[path] = true
	kernel := a.kernel
	// The read belongs to the open project, so an answer that arrives after the project was
	// closed or replaced is dropped with the state it would have been written to.
	a.background(a.project, kernelCallTimeout, func(ctx context.Context) func(*App) {
		branch := ""
		// Outside a repository there is no branch, as on the project the title bar shows.
		if status, err := kernel.GitStatus(ctx, path); err == nil && status.RepositoryRoot != "" {
			branch = status.Branch
		}
		return func(a *App) {
			delete(a.title.reading, path)
			if a.title.branches == nil {
				a.title.branches = make(map[string]string, chromeMenuRecents)
			}
			a.title.branches[path] = branch
		}
	})
}

// menuRecents returns the indexes into a.recent of the projects the menu lists under the
// recent ones: every recent project but the open one, at most chromeMenuRecents of them.
// The result lives in buf, so a frame allocates nothing for it.
func (a *App) menuRecents(buf *[chromeMenuRecents]int) []int {
	n := 0
	for i := range a.recent {
		if n == len(buf) {
			break
		}
		if a.recent[i].Path != a.project.root {
			buf[n] = i
			n++
		}
	}
	return buf[:n]
}

// projectMenuKey closes the open project menu on Escape and reports the key handled, so the
// same press does not also reach the terminal. It leaves every other key, and Escape with
// the menu shut, to the caller.
func (a *App) projectMenuKey(event ui.KeyEvent) ui.EventResult {
	if !a.title.projectOpen || event.Release || event.Key != ui.KeyEscape {
		return ui.EventResult{}
	}
	a.title.projectOpen = false
	return ui.EventResult{Handled: true, Repaint: true}
}

// drawProjectMenu declares the open project menu under anchor, the project button: a
// backdrop over the whole window that closes the menu when pressed, and the panel above
// it. The panel starts with the actions that begin a project, then lists the open project
// and the recent ones, and scrolls when the list is taller than the panel may be.
//
// What a click asks for is done once the panel is declared. Opening or closing a project
// replaces the state the panel is built from, so those two are queued with post and run
// before the next frame.
func (a *App) drawProjectMenu(f *flex.Frame, anchor flex.Box) {
	dismissed := f.Popup().At(0, 0).Fill().
		HitWith(chromeMenuDismiss, a.text.Errors.Dismiss, ui.HitOptions{
			Role:          ui.RoleButton,
			SkipFocus:     true,
			Backdrop:      true,
			PassSecondary: true,
		}).Clicked()

	var buf [chromeMenuRecents]int
	recents := a.menuRecents(&buf)
	var created, chosen, cloned, current, closing bool
	picked := -1
	// The panel has a hit of its own to take the presses on its padding and between its rows.
	// Without one they would fall through to the backdrop and close the menu.
	panel := ui.HitOptions{Role: ui.RoleMenu, SkipFocus: true}
	f.Popup().BelowBox(anchor, chromeMenuOffset, flex.Start).
		Width(chromeMenuWidth).MaxHeight(chromeMenuMaxHeight).
		Background(a.theme.Popover).Border(1, a.theme.Border).Radius(chromeMenuRadius).Shadow(ui.ShadowMD).
		HitWith(chromeMenuPanel, a.text.Title.ProjectMenu, panel).
		Children(func() {
			f.ScrollArea(chromeMenuScroll).MaxHeight(chromeMenuMaxHeight).Pad(chromeMenuPadding).Gap(chromeMenuItems).Children(func() {
				created = a.drawMenuAction(f, chromeMenuNew, icons.Plus, a.text.Title.NewProjectItem)
				chosen = a.drawMenuAction(f, chromeMenuOpen, icons.FolderOpen, a.text.Title.OpenItem)
				cloned = a.drawMenuAction(f, chromeMenuClone, icons.Download, a.text.Title.CloneItem)

				a.drawMenuDivider(f)
				a.drawMenuTitle(f, a.text.Title.OpenProjects)
				openRow := a.welcome.row(a.project.root, len(a.recent))
				current, closing = a.drawProjectMenuRow(f, chromeMenuCurrent, openRow, a.project.git.branch(), true, false)

				a.drawMenuDivider(f)
				a.drawMenuTitle(f, a.text.Title.RecentProjects)
				if len(recents) == 0 {
					f.Row().Height(chromeMenuRow).Shrink(0).Items(flex.Center).PadX(chromeEdge).Children(func() {
						f.Text(a.text.Title.NoRecentProjects).Color(a.colors.Subtle).LineHeight(chromeLineHeight)
					})
				}
				for _, i := range recents {
					path := a.recent[i].Path
					row := a.welcome.row(path, len(a.recent))
					missing := a.missing[path]
					// A folder that is gone cannot be opened, so its row is shown and not offered.
					if clicked, _ := a.drawProjectMenuRow(f, chromeMenuRecent.At(i), row, a.title.branches[path], false, missing); clicked && !missing {
						picked = i
					}
				}
			})
		})

	switch {
	case created:
		a.title.projectOpen = false
		a.notify(a.text.Title.NewProjectLater)
	case chosen:
		a.title.projectOpen = false
		a.chooseProject(surfaceMenu)
	case cloned:
		a.title.projectOpen = false
		a.notify(a.text.Title.CloneLater)
	case closing:
		a.title.projectOpen = false
		a.performed("workspace.close", surfaceMenu)
		a.post(func(a *App) { a.closeProject() })
	case picked >= 0:
		// The path is taken now: opening a project replaces the recent list the index is into.
		path := a.recent[picked].Path
		a.title.projectOpen = false
		a.performed("workspace.project.switch", surfaceMenu)
		a.post(func(a *App) { a.openProject(path) })
	case current, dismissed:
		// The open project is already open, so choosing it only closes the menu.
		a.title.projectOpen = false
	}
}

// drawMenuAction declares one of the actions at the top of the project menu, an icon and
// its name, and reports a click on it.
func (a *App) drawMenuAction(f *flex.Frame, id ui.ID, icon ui.Icon, label string) bool {
	row := a.chromeHover(f.Row().Height(chromeMenuRow).Shrink(0).Items(flex.Center).Gap(chromeMenuGap).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(id, label, ui.HitOptions{Role: ui.RoleMenuItem, Cursor: ui.PointerCursorHand}))
	row.Children(func() {
		f.Icon(icon).Size(chromeIconSize, chromeIconSize).Color(a.colors.Subtle)
		f.Text(label).Color(a.colors.Text).LineHeight(chromeLineHeight)
	})
	return row.Clicked()
}

// drawMenuDivider declares the line between two parts of the project menu. The room
// around it keeps the sections apart without a heavier rule.
func (a *App) drawMenuDivider(f *flex.Frame) {
	f.Row().FillWidth().Height(1).Shrink(0).Background(a.colors.Line).
		MarginSides(chromeMenuGap, chromeMenuPadding, chromeMenuGap, chromeMenuPadding)
}

// drawMenuTitle declares the name of a section of the project menu.
func (a *App) drawMenuTitle(f *flex.Frame, label string) {
	f.Row().Height(chromeMenuTitle).Shrink(0).Items(flex.Center).PadX(chromeEdge).Children(func() {
		f.Text(label).FontSize(a.theme.Metrics.FontSizeS).Bold().Color(a.colors.Subtle).LineHeight(chromeLineHeight)
	})
}

// drawProjectMenuRow declares one project of the menu: its badge, its name, its folder and,
// when it is a repository, its branch. It reports a click on the row and, for the open
// project, a click on the button at its end that closes the project. The open project is
// marked as selected. A project whose folder is gone is faded and inert.
func (a *App) drawProjectMenuRow(f *flex.Frame, id ui.ID, row welcomeRow, branch string, current, missing bool) (clicked, closed bool) {
	options := ui.HitOptions{Role: ui.RoleMenuItem, Cursor: ui.PointerCursorHand, Description: row.path, Selected: current}
	if missing {
		options.Cursor, options.Disabled, options.Hint = ui.PointerCursorDefault, true, a.text.Welcome.Missing
	}
	item := f.Row().MinHeight(chromeMenuProject).Shrink(0).Items(flex.Center).Gap(chromeMenuGap).PadX(chromeEdge).PadY(chromeMenuRowPad).
		Radius(a.theme.Metrics.RadiusItem()).HitWith(id, row.name, options)
	switch {
	case current:
		item = item.Background(a.colors.Selection)
	case missing:
		item = item.Opacity(identityMissingOpacity)
	default:
		item = a.chromeHover(item)
	}
	item.Children(func() {
		drawProjectAvatar(f, row.identity, chromeMenuAvatar)
		f.Column().Grow(1).Children(func() {
			f.Text(row.name).Color(a.colors.Text).LineHeight(chromeLineHeight).Ellipsis()
			f.Text(row.path).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).LineHeight(chromeLineHeight).Ellipsis()
			if branch != "" {
				f.Row().Items(flex.Center).Gap(chromeGap).Children(func() {
					f.Icon(icons.GitBranch).Size(chromeMarkSize, chromeMarkSize).Shrink(0).Color(a.colors.Subtle)
					f.Text(branch).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).LineHeight(chromeLineHeight).Ellipsis()
				})
			}
		})
		if current {
			closed = a.drawMenuClose(f)
		}
	})
	return item.Clicked(), closed
}

// drawMenuClose declares the button at the end of the open project's row that closes the
// project, and reports a click on it.
func (a *App) drawMenuClose(f *flex.Frame) bool {
	button := a.chromeHover(f.Row().Size(chromeMenuClosing, chromeMenuClosing).Shrink(0).Center().
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(chromeMenuClose, a.text.Title.CloseProject, ui.HitOptions{Role: ui.RoleButton, Cursor: ui.PointerCursorHand}))
	button.Children(func() {
		f.Icon(icons.X).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Subtle).
			StateFrom(button).Hover(flex.Look{}.Color(a.colors.Text))
	})
	return button.Clicked()
}

// paintChromeMenus paints the menus of the title bar that are not declared in Draw, above
// the frame Draw just finished, and acts on a choice in them. The settings button's menu is
// placed against the rectangle of a button the user can move, which is known only once the
// frame is laid out. The project menu does not wait for that: it is declared in the frame
// that declares its button (drawProjectMenu).
func (a *App) paintChromeMenus(canvas *ui.Canvas, viewport ui.Rect) {
	a.paintGearMenu(canvas, viewport)
}

// paintGearMenu paints the settings button's menu, as the macOS title bar's gear shows it,
// and acts on a choice in it. The button is rearrangeable, so the menu is placed against
// where it was laid out in the frame just finished, opening toward the inside of the window.
func (a *App) paintGearMenu(canvas *ui.Canvas, viewport ui.Rect) {
	if !a.title.gearOpen {
		return
	}
	if a.project == nil {
		// The start screen has no title bar, and the menu closes instead of staying open
		// behind it.
		a.title.gearOpen = false
		return
	}
	anchor := a.chrome.rects[catalogIndex[itemTitleSettings]]
	if anchor.Width == 0 || anchor.Height == 0 {
		// The button is hidden or not laid out yet, and a menu with nothing to point at
		// would float in the corner.
		a.title.gearOpen = false
		return
	}
	height := float32(2*chromeMenuPadding + 5*chromeMenuRow + chromeMenuSeparator)
	x := anchor.X
	if anchor.X+anchor.Width/2 > viewport.X+viewport.Width/2 {
		x = anchor.X + anchor.Width - gearMenuWidth
	}
	bounds := ui.Rect{X: x, Y: anchor.Y + anchor.Height + chromeMenuOffset, Width: gearMenuWidth, Height: height}

	menu := components.BeginDropdownMenu(canvas, a.theme, bounds, components.DropdownMenuOptions{
		Layer:     1,
		Scope:     gearMenuDismiss,
		DismissID: gearMenuDismiss,
		Viewport:  viewport,
	})
	menu.AddItem(components.DropdownMenuItem{ID: gearMenuSettings, Label: a.text.Title.Preferences, Shortcut: "⌘,"})
	menu.AddItem(components.DropdownMenuItem{ID: gearMenuPlugins, Label: a.text.Title.Plugins})
	menu.AddItem(components.DropdownMenuItem{ID: gearMenuLogs, Label: a.text.Title.LogsAndDiagnostics, Shortcut: logsShortcut})
	menu.AddSeparator()
	menu.AddItem(components.DropdownMenuItem{ID: gearMenuTheme, Label: a.text.Title.ThemeMenu})
	menu.AddItem(components.DropdownMenuItem{ID: gearMenuKeymap, Label: a.text.Title.Keymap})
	menu.End()

	// Clicks are read only after the whole menu is declared.
	settings := canvas.Clicked(gearMenuSettings)
	plugins := canvas.Clicked(gearMenuPlugins)
	logs := canvas.Clicked(gearMenuLogs)
	theme := canvas.Clicked(gearMenuTheme)
	keymap := canvas.Clicked(gearMenuKeymap)
	if !settings && !plugins && !logs && !theme && !keymap && !canvas.Clicked(gearMenuDismiss) {
		return
	}
	a.title.gearOpen = false
	switch {
	case settings, theme:
		// The theme is chosen in the settings window.
		a.openSettings(surfaceMenu)
	case plugins:
		a.openPluginSettings(surfaceMenu)
	case logs:
		a.openLogs()
	case keymap:
		a.notify(a.text.Title.KeymapLater)
	}
}
