package workbench

import (
	"path/filepath"

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
	// chromeMenuDismiss is the action the open project menu reports when the user
	// presses outside it or hits Escape; it is also the menu's focus scope.
	chromeMenuDismiss = tree.ID(shellPage, "project-menu-dismiss")
	// chromeMenuRecent identifies the recent project entries of the menu:
	// chromeMenuRecent.At(i) is a.recent[i], however many entries are listed before it.
	chromeMenuRecent = tree.Sub(shellPage, tree.Name("project-menu-recent"))
	chromeMenuOpen   = tree.ID(shellPage, "project-menu-open")
	chromeMenuClose  = tree.ID(shellPage, "project-menu-close")
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

	chromeMenuWidth   = 256
	chromeMenuOffset  = 4
	chromeMenuRecents = 10
	// The dropdown menu lays its rows out with fixed heights that Viva does not export.
	// The surface has to be as tall as its rows, because a surface that is too short
	// hides the last of them, so they are repeated here.
	chromeMenuPadding   = 4
	chromeMenuRow       = 32
	chromeMenuLabel     = 28
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
	// projectAnchor is the project button of the frame being drawn, which the menu is
	// placed under. A Box is only valid until the next frame is begun, so anchored says
	// the title bar declared it since paintChromeMenus last ran.
	projectAnchor flex.Box
	anchored      bool
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
	clicked, opening := -1, false
	f.Row().FillWidth().Height(titleBarHeight).Shrink(0).Background(a.colors.Chrome).
		Items(flex.Center).Gap(chromeGap).PadSides(0, trailing+chromeEdge, 0, leading+chromeEdge).
		MovesWindow().Children(func() {
		opening = a.drawChromeProject(f)
		a.drawChromeBranch(f)
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
		a.title.projectOpen = true
	}
	if clicked >= 0 {
		a.activate(clicked)
	}
}

// drawChromeProject declares the project's name with the chevron that opens its menu
// and reports a click on it.
func (a *App) drawChromeProject(f *flex.Frame) bool {
	open := a.title.projectOpen
	button := f.Row().Height(chromeIconButton).Shrink(0).Items(flex.Center).Gap(chromeGap).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(chromeProjectButton, a.text.Title.ProjectMenu, ui.HitOptions{
			Role:       ui.RoleButton,
			Cursor:     ui.PointerCursorHand,
			Value:      a.project.name,
			Expandable: true,
			Expanded:   open,
		}).
		Pressed(flex.Look{}.Background(a.colors.Active))
	if open {
		button = button.Background(a.colors.Active)
	} else {
		button = button.Hover(flex.Look{}.Background(a.colors.Hover))
	}
	button.Children(func() {
		f.Text(a.project.name).Bold().Color(a.colors.Text).LineHeight(chromeLineHeight).Ellipsis().MaxWidth(chromeProjectMax)
		f.Icon(icons.ChevronDown).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Subtle)
	})
	a.title.projectAnchor, a.title.anchored = button, true
	return button.Clicked()
}

// drawChromeBranch declares the checked-out branch, or says there is no repository. It
// only shows; switching branches is not offered yet.
func (a *App) drawChromeBranch(f *flex.Frame) {
	name := a.project.git.branch()
	if name == "" {
		name = a.text.Title.NoRepository
	}
	f.Row().Height(chromeIconButton).Shrink(0).Items(flex.Center).Gap(chromeGap).PadX(chromeEdge).Children(func() {
		f.Icon(icons.GitBranch).Size(chromeIconSize, chromeIconSize).Color(a.colors.Subtle)
		f.Text(name).Color(a.colors.Subtle).LineHeight(chromeLineHeight).Ellipsis().MaxWidth(chromeBranchMax)
	})
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
// has three zones, one per tool window anchor: the top zone, whose buttons open from the
// top down; under it, after a separator line, the split zone, which is the lower half of
// the stripe's column of tool windows; and the bottom zone, whose buttons are packed at
// the bottom of the stripe. The top and the split zone are as high as their buttons and
// the bottom zone takes the rest, so the bottom zone stays where it is however many
// buttons the other two have. All three are declared even when empty, because an empty
// zone is still a place a button can be dropped.
//
// The separator tells the top zone from the split zone, and so is only drawn when it
// separates something: when the split zone has buttons, or while a tool button is
// dragged and the empty split zone is shown as a place to drop it. For the same reason
// a dragged tool button gives every zone of the stripe at least the height of a button,
// so that an empty zone is a target that can be seen and hit.
func (a *App) drawStripe(f *flex.Frame, left bool) {
	top, split, end := zoneLeftTop, zoneLeftBottom, zoneBottomLeft
	if !left {
		top, split, end = zoneRightTop, zoneRightBottom, zoneBottomRight
	}
	dragging := a.draggingToolButton()
	// As in the title bar, a click is acted on once the stripe is declared.
	clicked := -1
	f.Column().Width(stripeWidth).FillHeight().Shrink(0).Background(a.colors.Chrome).Pad(chromeGap).Children(func() {
		if i := a.drawChromeStripeZone(f, top, false, dragging); i >= 0 {
			clicked = i
		}
		if dragging || len(a.chrome.items[split]) > 0 {
			// Inset like the line that marks where a dragged button would land, so the two
			// read as lines of the same width.
			f.Row().FillWidth().Height(1).Shrink(0).Background(a.colors.Line).
				MarginSides(chromeGap, dragMarkInset, chromeGap, dragMarkInset)
		}
		if i := a.drawChromeStripeZone(f, split, false, dragging); i >= 0 {
			clicked = i
		}
		if i := a.drawChromeStripeZone(f, end, true, dragging); i >= 0 {
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
// the button clicked in it, or -1. A zone is as high as its buttons, except the one
// that packs them at its end: that one takes the room the others leave and keeps its
// buttons at the bottom of it. While a tool button is dragged, dragging is set and
// every zone is at least one button high, which makes an empty zone a place the button
// can be dropped.
func (a *App) drawChromeStripeZone(f *flex.Frame, z zone, packEnd, dragging bool) int {
	clicked := -1
	column := f.Column().Gap(chromeGap)
	if packEnd {
		column = column.Grow(1).Justify(flex.End)
	}
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
		// The caret has no editor to follow yet, so it stands at the start of the file.
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

// paintChromeMenus paints the menus of the title bar above the frame Draw just
// finished, and acts on a choice in them. It runs after Draw because a menu is placed
// against the rectangle of the button that opened it, which is known only once the
// frame is laid out.
func (a *App) paintChromeMenus(canvas *ui.Canvas, viewport ui.Rect) {
	a.paintGearMenu(canvas, viewport)
	anchored := a.title.anchored
	a.title.anchored = false
	if !a.title.projectOpen {
		return
	}
	if a.project == nil || a.settingsOpen {
		// Another layer took the window, and the menu closes instead of staying open
		// behind it.
		a.title.projectOpen = false
		return
	}
	if !anchored {
		return
	}

	// The open project is not offered again. The menu is as tall as its rows, which is
	// the label and the separator only when there are projects to list.
	shown := 0
	for _, entry := range a.recent {
		if entry.Path != a.project.root && shown < chromeMenuRecents {
			shown++
		}
	}
	height := float32(2*chromeMenuPadding + (shown+2)*chromeMenuRow)
	if shown > 0 {
		height += chromeMenuLabel + chromeMenuSeparator
	}
	anchor := a.title.projectAnchor.Rect()
	bounds := ui.Rect{X: anchor.X, Y: anchor.Y + anchor.Height + chromeMenuOffset, Width: chromeMenuWidth, Height: height}

	menu := components.BeginDropdownMenu(canvas, a.theme, bounds, components.DropdownMenuOptions{
		Layer:     1,
		Scope:     chromeMenuDismiss,
		DismissID: chromeMenuDismiss,
		Viewport:  viewport,
	})
	if shown > 0 {
		menu.AddLabel(a.text.Title.RecentProjects, false)
		listed := 0
		for i, entry := range a.recent {
			if entry.Path == a.project.root {
				continue
			}
			if listed == chromeMenuRecents {
				break
			}
			listed++
			menu.AddItem(components.DropdownMenuItem{
				ID:    chromeMenuRecent.At(i),
				Label: filepath.Base(entry.Path),
				Value: entry.Path,
				Icon:  icons.Folder,
			})
		}
		menu.AddSeparator()
	}
	menu.AddItem(components.DropdownMenuItem{ID: chromeMenuOpen, Label: a.text.Title.OpenProject, Icon: icons.FolderOpen})
	menu.AddItem(components.DropdownMenuItem{ID: chromeMenuClose, Label: a.text.Title.CloseProject, Icon: icons.X})
	menu.End()

	// Clicks are read only after the whole menu is declared. The path is taken before the
	// menu closes, because opening a project replaces the recent list it indexes.
	pick, picked := canvas.ClickedIn(chromeMenuRecent)
	dismissed := canvas.Clicked(chromeMenuDismiss)
	choose := canvas.Clicked(chromeMenuOpen)
	closing := canvas.Clicked(chromeMenuClose)
	if !picked && !dismissed && !choose && !closing {
		return
	}
	path := ""
	if picked && pick < len(a.recent) {
		path = a.recent[pick].Path
	}
	a.title.projectOpen = false
	switch {
	case path != "":
		a.performed("workspace.project.switch", surfaceMenu)
		a.openProject(path)
	case choose:
		a.chooseProject(surfaceMenu)
	case closing:
		a.performed("workspace.close", surfaceMenu)
		a.closeProject()
	}
}

// paintGearMenu paints the settings button's menu, as the macOS title bar's gear shows it,
// and acts on a choice in it. The button is rearrangeable, so the menu is placed against
// where it was laid out in the frame just finished, opening toward the inside of the window.
func (a *App) paintGearMenu(canvas *ui.Canvas, viewport ui.Rect) {
	if !a.title.gearOpen {
		return
	}
	if a.project == nil || a.settingsOpen {
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
		// The theme is chosen in the settings dialog.
		a.settingsOpen = true
	case plugins:
		a.notify(a.text.Title.PluginsLater)
	case logs:
		a.openLogs()
	case keymap:
		a.notify(a.text.Title.KeymapLater)
	}
}
