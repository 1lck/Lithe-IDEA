package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
	"runtime"
)

// This file declares the window's chrome as components of the workbench page: the title bar
// with the project and branch buttons, the two stripes of tool buttons and the status bar,
// with the menus that hang off them. The buttons the user can arrange are Hit rows that are
// drag sources (dnd.go); the rectangle each was laid out at is kept by a draw hook for the
// drag to aim at.

// chromeBox gives the container of the rearrangeable button of catalog item i its look and
// its drag source, and returns it for its content to be declared in. A container is used
// instead of a Button because these buttons carry icons, take their colors from the palette
// and report their state to assistive technology. value is the reading of a status item,
// empty for the other buttons.
func (a *App) chromeBox(row ui.Box, id gfx.ID, i int, open bool, value string) ui.Box {
	it := a.chrome.catalog[i]
	label := it.label(a.text)
	if it.id == itemChanges {
		// The label of the changes item is a fixed "No changes"; the reading says how many.
		label = value
	}
	options := gfx.HitOptions{Role: gfx.RoleButton, Hint: a.text.Tools.DragHint, Selected: open, Value: value}
	if it.zone.surface() != surfaceStatus {
		// The status items only show a reading, so they do not offer a click.
		options.Cursor = gfx.PointerCursorHand
	}
	row = row.Radius(a.theme.Metrics.RadiusItem()).
		HitWith(id, label, options).
		Pressed(ui.Look{}.Background(a.colors.Active))
	if open {
		row = row.Background(a.colors.Active)
	} else {
		row = row.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	a.chrome.ids[i] = id
	if a.dnd.tool.Dragging() && a.dnd.tool.Source() == id {
		row = row.Opacity(chromeDragDim)
	}
	return a.chrome.place(i, row.DragSource(&a.dnd.tool))
}

// chromeGlyph declares a square button that shows the icon of catalog item i and reports a
// click on it. The icon is rest while the pointer is away and hover while it is over the
// button.
func (a *App) chromeGlyph(c ui.C, i int, side float32, rest, hover gfx.Color, open bool) (ui.Box, bool) {
	k := c.KeyInt(i)
	box := a.chromeBox(ui.Row(k).Size(side, side).Shrink(0).Center(), ui.ID(k), i, open, "")
	box.Children(func() {
		ui.Icon(k, *a.chrome.catalog[i].icon).Size(chromeIconSize, chromeIconSize).Color(rest).
			StateFrom(box).Hover(ui.Look{}.Color(hover))
	})
	return box, box.Clicked()
}

// titleBar is the strip across the top of the workbench: the project, the branch and, at the
// trailing end, the buttons the user can arrange. The whole bar moves the window; the
// controls in it take their own presses.
func (a *App) titleBar(c ui.C) {
	// The system's window buttons sit at one end of the strip, so the content keeps clear of
	// them.
	leading, trailing := app.TitlebarInsets()
	if a.fullscreen && runtime.GOOS == "darwin" {
		// macOS hides the traffic lights in fullscreen; the strip starts at the edge.
		leading = 0
	}
	clicked := -1
	ui.Row(c).FillWidth().Height(titleBarHeight).Shrink(0).Background(a.chromeFill()).
		Items(ui.Center).Gap(chromeGap).PadSides(0, trailing+chromeEdge, 0, leading+chromeEdge).
		MovesWindow().Children(func() {
		a.compactMenuButton(c)
		a.chromeProject(c)
		a.chromeBranch(c)
		ui.Spacer(c)
		zone := ui.Row(c).Items(ui.Center).Gap(chromeGap).Children(func() {
			for _, i := range a.chrome.items[zoneTitle] {
				if a.chromeTitleButton(c, i) {
					clicked = i
				}
			}
		})
		a.chrome.placeZone(zoneTitle, zone)
		// The line is out of the flow so that the buttons are centered in the whole bar.
		ui.Row(c).Absolute().Left(0).Right(0).Bottom(0).Height(1).Background(a.colors.Line)
	})
	if clicked >= 0 {
		c.After(func() { a.activate(clicked) })
	}
}

// chromeHover gives a control the backgrounds the chrome's buttons take while the pointer
// is over them and while they are pressed.
func (a *App) chromeHover(box ui.Box) ui.Box {
	return box.Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
}

// chromeProject declares the project's badge and name with the chevron that opens its menu,
// and the menu while it is open.
func (a *App) chromeProject(c ui.C) {
	open := a.title.projectOpen
	row := a.welcome.row(a.project.root, len(a.recent))
	k := c.Part("project")
	button := ui.Row(k).Height(chromeIconButton).Shrink(0).Items(ui.Center).Gap(chromeTitleGap).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(k), a.text.Title.ProjectMenu, gfx.HitOptions{
			Role:        gfx.RoleButton,
			Cursor:      gfx.PointerCursorHand,
			Value:       a.project.name,
			Description: row.path,
			Expandable:  true,
			Expanded:    open,
		}).
		Pressed(ui.Look{}.Background(a.colors.Active))
	if open {
		button = button.Background(a.colors.Active)
	} else {
		button = button.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	button.Children(func() {
		projectAvatar(k, row.identity, chromeAvatarTitle)
		ui.Text(k, a.project.name).Bold().Color(a.colors.Text).LineHeight(chromeLineHeight).Ellipsis().MaxWidth(chromeProjectMax)
		ui.Icon(k, icons.ChevronDown).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Subtle)
	})
	clicked := button.Clicked()
	if a.title.projectOpen {
		a.projectMenu(c, button)
	}
	if clicked && !open {
		c.After(a.openProjectMenu)
	}
}

// chromeTitleButton declares the title bar button of catalog item i and reports a click on
// it. The settings button's menu hangs off it.
func (a *App) chromeTitleButton(c ui.C, i int) bool {
	switch a.chrome.catalog[i].id {
	case itemRunConfig:
		k := c.KeyInt(i)
		box := a.chromeBox(ui.Row(k).Height(chromeIconButton).Shrink(0).Items(ui.Center).Gap(chromeGap).PadX(chromeEdge), ui.ID(k), i, false, "")
		box.Children(func() {
			ui.Icon(k, *a.chrome.catalog[i].icon).Size(chromeIconSize, chromeIconSize).Color(a.colors.Subtle)
			ui.Text(k, a.text.Title.CurrentFile).Color(a.colors.Text).LineHeight(chromeLineHeight)
			ui.Icon(k, icons.ChevronDown).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Subtle)
		})
		return box.Clicked()
	case itemTitleRun:
		// Run is the one button that keeps its color at rest: green says what it does.
		_, clicked := a.chromeGlyph(c, i, chromeIconButton, a.colors.Success, a.colors.Success, false)
		return clicked
	case itemTitleSettings:
		box, clicked := a.chromeGlyph(c, i, chromeIconButton, a.colors.Text, a.colors.Text, a.title.gearOpen)
		wasOpen := a.title.gearOpen
		if wasOpen {
			a.gearMenu(c, box)
		}
		if clicked && !wasOpen {
			a.title.gearOpen = true
			a.title.projectOpen = false
			c.After(a.closeBranches)
		}
		return false
	}
	_, clicked := a.chromeGlyph(c, i, chromeIconButton, a.colors.Text, a.colors.Text, false)
	return clicked
}

// stripe is the column of tool buttons at one side of the workbench. Each stripe stacks its
// top group first, leaves flexible space, then packs the split group directly above the
// bottom group at the stripe's end. The split group opens in the lower half of the side
// column; the bottom group opens in a half of the bottom area. All three zones are declared
// even when empty, because an empty zone is still a place a button can be dropped.
//
// While a tool button is dragged, every zone gets at least the height of a button, so an
// empty zone remains visible and can be hit. No separator is needed between the top and
// split groups: the flexible space makes their placement clear.
func (a *App) stripe(c ui.C, left bool) {
	top, split, end := zoneLeftTop, zoneLeftBottom, zoneBottomLeft
	if !left {
		top, split, end = zoneRightTop, zoneRightBottom, zoneBottomRight
	}
	dragging := a.draggingToolButton()
	// As in the title bar, a click is acted on once the stripe is declared.
	clicked := -1
	ui.Column(c).Width(stripeWidth).FillHeight().Shrink(0).Background(a.chromeFill()).Pad(chromeGap).Children(func() {
		if i := a.stripeZone(c, top, dragging); i >= 0 {
			clicked = i
		}
		ui.Spacer(c)
		if i := a.stripeZone(c, split, dragging); i >= 0 {
			clicked = i
		}
		if i := a.stripeZone(c, end, dragging); i >= 0 {
			clicked = i
		}
		// The line on the editor's side is out of the flow, so the buttons sit in the middle
		// of the stripe.
		line := ui.Row(c).Absolute().Top(0).Bottom(0).Width(1).Background(a.colors.Line)
		if left {
			line.Right(0)
		} else {
			line.Left(0)
		}
	})
	if clicked >= 0 {
		c.After(func() { a.activate(clicked) })
	}
}

// stripeZone declares one zone of a stripe and returns the catalog index of the button
// clicked in it, or -1. Each zone is as high as its buttons; the spacer in stripe pushes the
// split and bottom groups to the stripe's end. While a tool button is dragged, every zone is
// at least one button high, which makes an empty zone a place the button can be dropped.
func (a *App) stripeZone(c ui.C, z zone, dragging bool) int {
	clicked := -1
	column := ui.Column(c).Gap(chromeGap)
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
			box, hit := a.chromeGlyph(c, i, chromeToolButton, rest, a.colors.Text, open)
			if hit {
				clicked = i
			}
			ui.ContextMenu(c.Part("menu").KeyInt(i), box, a.stripeButtonMenu(c, i, z))
		}
	})
	a.chrome.placeZone(z, column)
	return clicked
}

// statusBar is the strip across the bottom of the workbench: the project on the left, and at
// the trailing end the readouts the user can arrange.
func (a *App) statusBar(c ui.C) {
	clicked := -1
	ui.Row(c).FillWidth().Height(statusBarHeight).Shrink(0).Background(a.chromeFill()).
		Items(ui.Center).PadX(chromeEdge).Children(func() {
		k := c.Part("path")
		ui.Text(k, a.project.name).Grow(1).Ellipsis().FontSize(a.theme.Metrics.FontSizeS).LineHeight(chromeLineHeight).
			Color(a.colors.Subtle).
			HitWith(ui.ID(k), a.text.Status.Path, gfx.HitOptions{Role: gfx.RoleStatus, Value: a.project.name, SkipFocus: true})
		zone := ui.Row(c).Items(ui.Center).Gap(chromeGap).Children(func() {
			for _, i := range a.chrome.items[zoneStatus] {
				if !a.vimStatusShown(i) {
					continue
				}
				if a.chromeStatusItem(c, i) {
					clicked = i
				}
			}
		})
		a.chrome.placeZone(zoneStatus, zone)
		a.notificationBell(c)
		ui.Row(c).Absolute().Left(0).Right(0).Top(0).Height(1).Background(a.colors.Line)
	})
	if clicked >= 0 {
		c.After(func() { a.activate(clicked) })
	}
}

// chromeStatusItem declares the status bar item of catalog item i and reports a click on it.
func (a *App) chromeStatusItem(c ui.C, i int) bool {
	text := a.chromeStatusText(i)
	k := c.KeyInt(i)
	box := a.chromeBox(ui.Row(k).Height(chromeStatusItem).Shrink(0).Items(ui.Center).Gap(chromeGap).PadX(chromeEdge), ui.ID(k), i, false, text)
	box.Children(func() {
		switch a.chrome.catalog[i].id {
		case itemLock:
			icon := *a.chrome.catalog[i].icon
			if doc := a.selectedEditorDocument(); doc != nil && doc.view.ReadOnly() {
				icon = icons.Lock
			}
			ui.Icon(k, icon).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Subtle)
		case itemHealth:
			ui.Icon(k, *a.chrome.catalog[i].icon).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Success)
		case itemMemory:
			a.memoryStatusItem(k)
		case itemLSP:
			ui.Row(k).Size(chromeDot, chromeDot).Shrink(0).Radius(chromeDot / 2).Background(a.colors.Subtle)
			a.chromeStatusLabel(k, text)
		default:
			a.chromeStatusLabel(k, text)
		}
	})
	switch a.chrome.catalog[i].id {
	case itemEncoding:
		a.encodingMenu(c, box)
	case itemMemory:
		a.memoryDetails(c, box)
	}
	return box.Clicked()
}

func (a *App) chromeStatusLabel(c ui.C, text string) {
	ui.Text(c, text).FontSize(a.theme.Metrics.FontSizeS).LineHeight(chromeLineHeight).Color(a.colors.Subtle)
}

// chromeBranch declares the checked-out branch as the button that opens the branch popup, and
// shows nothing when the project is not a repository. The popup hangs off the button.
func (a *App) chromeBranch(c ui.C) {
	name := a.project.git.branch()
	if name == "" {
		if a.branch.open {
			// The project stopped being a repository, so the popup has no branch to hang off.
			c.After(a.closeBranches)
		}
		return
	}
	open := a.branch.open
	k := c.Part("branch")
	button := ui.Row(k).Height(chromeIconButton).Shrink(0).Items(ui.Center).Gap(chromeGap).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(k), a.text.Title.BranchMenu, gfx.HitOptions{
			Role:       gfx.RoleButton,
			Cursor:     gfx.PointerCursorHand,
			Value:      name,
			Expandable: true,
			Expanded:   open,
		}).
		Pressed(ui.Look{}.Background(a.colors.Active))
	if open {
		button = button.Background(a.colors.Active)
	} else {
		button = button.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	button.Children(func() {
		ui.Icon(k, icons.GitBranch).Size(chromeIconSize, chromeIconSize).Color(a.colors.Subtle)
		ui.Text(k, name).Color(a.colors.Subtle).LineHeight(chromeLineHeight).Ellipsis().MaxWidth(chromeBranchMax)
		ui.Icon(k, icons.ChevronDown).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Subtle)
	})
	clicked := button.Clicked()
	if open {
		a.drawBranchPopup(c, a.project, button)
	}
	if clicked && !open {
		c.After(a.openBranches)
	}
}

// projectMenu declares the open project menu under anchor, the project button: the actions
// that begin a project, then the open project and the recent ones, scrolling when the list
// is taller than the panel may be. A press outside it, or Escape, closes it.
//
// What a click asks for is done once the menu is declared. Opening or closing a project
// replaces the state the menu is built from, so those two are queued with post.
func (a *App) projectMenu(c ui.C, anchor ui.Box) {
	var buf [chromeMenuRecents]int
	recents := a.menuRecents(&buf)
	var created, chosen, cloned, current, closing bool
	picked := -1
	spec := ui.PopoverSpec{Align: ui.Start, Offset: chromeMenuOffset, Width: chromeMenuWidth, ConsumeOutsidePress: true}
	open := true
	ui.PopoverWith(c, anchor, spec, &open, func() {
		ui.Scroll(c).FillWidth().MaxHeight(chromeMenuMaxHeight).Gap(chromeMenuItems).Children(func() {
			created = a.menuAction(c.Part("new"), icons.Plus, a.text.Title.NewProjectItem)
			chosen = a.menuAction(c.Part("open"), icons.FolderOpen, a.text.Title.OpenItem)
			cloned = a.menuAction(c.Part("clone"), icons.Download, a.text.Title.CloneItem)

			a.menuDivider(c)
			a.menuTitle(c, a.text.Title.OpenProjects)
			openRow := a.welcome.row(a.project.root, len(a.recent))
			current, closing = a.projectMenuRow(c.Part("current"), openRow, a.project.git.branch(), true, false)

			a.menuDivider(c)
			a.menuTitle(c, a.text.Title.RecentProjects)
			if len(recents) == 0 {
				ui.Row(c).Height(chromeMenuRow).Shrink(0).Items(ui.Center).PadX(chromeEdge).Children(func() {
					ui.Text(c, a.text.Title.NoRecentProjects).Color(a.colors.Subtle).LineHeight(chromeLineHeight)
				})
			}
			for _, i := range recents {
				path := a.recent[i].Path
				row := a.welcome.row(path, len(a.recent))
				missing := a.missing[path]
				// A folder that is gone cannot be opened, so its row is shown and not offered.
				if hit, _ := a.projectMenuRow(c.Key(path), row, a.title.branches[path], false, missing); hit && !missing {
					picked = i
				}
			}
		})
	})
	switch {
	case created:
		a.title.projectOpen = false
		c.After(func() { a.openNewProject(surfaceMenu) })
	case chosen:
		a.title.projectOpen = false
		c.After(func() { a.chooseProject(surfaceMenu) })
	case cloned:
		a.title.projectOpen = false
		c.After(func() { a.openClone(surfaceMenu) })
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
	case current, !open:
		// The open project is already open, so choosing it only closes the menu.
		a.title.projectOpen = false
	}
}

// menuAction declares one of the actions at the top of the project menu, an icon and its
// name, and reports a click on it.
func (a *App) menuAction(c ui.C, icon gfx.Icon, label string) bool {
	row := a.chromeHover(ui.Row(c).FillWidth().Height(chromeMenuRow).Shrink(0).Items(ui.Center).Gap(chromeMenuGap).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(c), label, gfx.HitOptions{Role: gfx.RoleMenuItem, Cursor: gfx.PointerCursorHand}))
	row.Children(func() {
		ui.Icon(c, icon).Size(chromeIconSize, chromeIconSize).Color(a.colors.Subtle)
		ui.Text(c, label).Color(a.colors.Text).LineHeight(chromeLineHeight)
	})
	return row.Clicked()
}

// menuDivider declares the line between two parts of the project menu. The room around it
// keeps the sections apart without a heavier rule.
func (a *App) menuDivider(c ui.C) {
	ui.Row(c).FillWidth().Height(1).Shrink(0).Background(a.colors.Line).
		MarginSides(chromeMenuGap, chromeMenuPadding, chromeMenuGap, chromeMenuPadding)
}

// menuTitle declares the name of a section of the project menu.
func (a *App) menuTitle(c ui.C, label string) {
	ui.Row(c).Height(chromeMenuTitle).Shrink(0).Items(ui.Center).PadX(chromeEdge).Children(func() {
		ui.Text(c, label).FontSize(a.theme.Metrics.FontSizeS).Bold().Color(a.colors.Subtle).LineHeight(chromeLineHeight)
	})
}

// projectMenuRow declares one project of the menu: its badge, its name, its folder and, when
// it is a repository, its branch. It reports a click on the row and, for the open project, a
// click on the button at its end that closes the project. The open project is marked as
// selected. A project whose folder is gone is faded and inert.
func (a *App) projectMenuRow(c ui.C, row welcomeRow, branch string, current, missing bool) (clicked, closed bool) {
	options := gfx.HitOptions{Role: gfx.RoleMenuItem, Cursor: gfx.PointerCursorHand, Description: row.path, Selected: current}
	if missing {
		options.Cursor, options.Disabled, options.Hint = gfx.PointerCursorDefault, true, a.text.Welcome.Missing
	}
	item := ui.Row(c).FillWidth().MinHeight(chromeMenuProject).Shrink(0).Items(ui.Center).Gap(chromeMenuGap).PadX(chromeEdge).PadY(chromeMenuRowPad).
		Radius(a.theme.Metrics.RadiusItem()).HitWith(ui.ID(c), row.name, options)
	switch {
	case current:
		item = item.Background(a.colors.Selection)
	case missing:
		item = item.Opacity(identityMissingOpacity)
	default:
		item = a.chromeHover(item)
	}
	item.Children(func() {
		projectAvatar(c, row.identity, chromeMenuAvatar)
		ui.Column(c).Grow(1).Children(func() {
			ui.Text(c, row.name).Color(a.colors.Text).LineHeight(chromeLineHeight).Ellipsis()
			ui.Text(c, row.path).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).LineHeight(chromeLineHeight).Ellipsis()
			if branch != "" {
				ui.Row(c).Items(ui.Center).Gap(chromeGap).Children(func() {
					ui.Icon(c, icons.GitBranch).Size(chromeMarkSize, chromeMarkSize).Shrink(0).Color(a.colors.Subtle)
					ui.Text(c, branch).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).LineHeight(chromeLineHeight).Ellipsis()
				})
			}
		})
		if current {
			closed = a.menuClose(c)
		}
	})
	return item.Clicked(), closed
}

// menuClose declares the button at the end of the open project's row that closes the
// project, and reports a click on it.
func (a *App) menuClose(c ui.C) bool {
	k := c.Part("close")
	button := a.chromeHover(ui.Row(k).Size(chromeMenuClosing, chromeMenuClosing).Shrink(0).Center().
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(k), a.text.Title.CloseProject, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}))
	button.Children(func() {
		ui.Icon(k, icons.X).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Subtle).
			StateFrom(button).Hover(ui.Look{}.Color(a.colors.Text))
	})
	return button.Clicked()
}

// gearMenu declares the settings button's menu, as the macOS title bar's gear shows it, under
// anchor, the button the user can move.
func (a *App) gearMenu(c ui.C, anchor ui.Box) {
	open := true
	ui.Menu(c, anchor, &open, func(menu *ui.MenuItems) {
		menu.WidthRange(gearMenuWidth, gearMenuWidth)
		if menu.Item(a.text.Title.Preferences).Keys(ui.Primary, ",").Clicked() {
			c.After(func() { a.openSettings(surfaceMenu) })
		}
		if menu.Item(a.text.Title.Plugins).Clicked() {
			c.After(func() { a.openPluginSettings(surfaceMenu) })
		}
		if menu.Item(a.text.Title.LogsAndDiagnostics).Keys(ui.Primary|ui.Shift, "l").Clicked() {
			c.After(a.openLogs)
		}
		a.legacyImportMenuItem(c, menu)
		a.credentialImportItem(c, menu)
		menu.Separator()
		if menu.Item(a.text.Title.ThemeMenu).Clicked() {
			// The theme is chosen in the settings window.
			c.After(func() { a.openSettings(surfaceMenu) })
		}
		if menu.Item(a.text.Title.Keymap).Clicked() {
			c.After(func() { a.openKeymapSettings(surfaceMenu) })
		}
	})
	if !open {
		a.title.gearOpen = false
	}
}

// stripeZoneMoveKeys are the "Move to" entries of a stripe button's menu, by zone.
var stripeZoneMoveKeys = [...]string{
	zoneLeftTop:     "native.moveToLeftTop",
	zoneLeftBottom:  "native.moveToLeftBottom",
	zoneBottomLeft:  "native.moveToBottomLeft",
	zoneRightTop:    "native.moveToRightTop",
	zoneRightBottom: "native.moveToRightBottom",
	zoneBottomRight: "native.moveToBottomRight",
}

// stripeButtonMenu is the context menu of the stripe button of catalog item i, which sits
// in zone at: hiding its open tool window, and moving it to the end of another stripe zone,
// the keyboard and pointer alternative to dragging it.
func (a *App) stripeButtonMenu(c ui.C, i int, at zone) func(*ui.MenuItems) {
	return func(menu *ui.MenuItems) {
		language := a.language()
		id := a.chrome.catalog[i].id
		if a.chrome.isOpen(i) {
			label := a.chrome.catalog[i].label(a.text)
			if menu.Item(i18n.SharedFormat(language, "native.hideToolWindow", map[string]string{"arg1": label})).Clicked() {
				c.After(func() {
					a.performed("workbench.toolWindow.hide", surfaceMenu)
					a.reduceChrome(core.SetChromeOpen(id, false))
				})
			}
			menu.Separator()
		}
		for z, key := range stripeZoneMoveKeys {
			if zone(z) == at {
				continue
			}
			target := zoneNames[z]
			if menu.Item(i18n.Shared(language, key)).Clicked() {
				c.After(func() {
					a.performed("workbench.toolWindow.move", surfaceMenu)
					a.reduceChrome(core.MoveChrome(id, target, ""))
				})
			}
		}
	}
}
