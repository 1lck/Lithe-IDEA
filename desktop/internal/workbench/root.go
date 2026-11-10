package workbench

import (
	"runtime"

	"github.com/1lck/Lithe-IDEA/desktop/internal/appicon"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/windowcontrols"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The window is one Page. Its function declares the welcome screen while no project is open,
// and with a project the title bar over the stripes and the main column over the status bar
// (chrome_view.go, shell_view.go, editor_view.go), with every dialog, popup and toast the
// window can show declared after them, so they lie over the workbench. A tool window's
// contents are components (the log, the commit area, the tree, the Run, Tests and Debug views
// and the rest), and the editor and the terminals are Controls that paint themselves and take
// their input through Handlers. There is no window-level routing of pointer, wheel or typing:
// the page routes them. What remains of the Config's callbacks are the two that Viva leaves to
// the window (see Config).

// Config is the window's configuration.
func (a *App) Config() app.Config {
	a.subscribeSettings()
	base := app.Config{
		Title:          a.text.App.Name,
		Icon:           appicon.Window(),
		Width:          1280,
		Height:         800,
		MinWidth:       900,
		MinHeight:      600,
		WindowMode:     app.WindowCustomTitlebar,
		TitlebarHeight: titleBarHeight,
		WindowControls: func() app.WindowControlsStyle { return windowcontrols.Style(a.colors.Text, a.text) },
		Tree:           &tree,
		Invalidator:    &a.invalidator,
		OnWake:         a.drain,
		OnCloseRequest: func(allow func()) { a.requestCloseProject(allow) },
		OnClosed:       a.closed,
		// A Page routes the keys and the chords of the controls it declares, but not the arrow
		// keys of a splitter, nor the chords a terminal or an editor takes (Control-C, copy,
		// paste): those two are the window's to give them.
		OnKey:      a.onKey,
		OnShortcut: a.onShortcut,
		OnScroll:   a.onScroll,
		OnPointer:  a.onPointer,
		// Files dropped on the Agent composer become references in its draft.
		OnFileDrop: a.agentFileDrop,
	}
	background := a.colors.Chrome
	a.root = ui.NewPage(ui.PageConfig{
		View: a.page, Tree: &tree, Root: "workbench",
		Theme: &a.theme, Background: &background, Invalidator: &a.invalidator,
	})
	config := a.root.Config(base)
	wheel := config.OnScroll
	config.OnScroll = func(event gfx.ScrollEvent) gfx.EventResult {
		if a.focusedDocument(event.Target) == nil && a.focusedTerminal(event.Target) == nil {
			verticalWheel(&event)
		}
		return wheel(event)
	}
	paint := config.Paint
	config.Paint = func(canvas *gfx.Canvas, size gfx.Size) {
		a.beginPaint(canvas)
		// The page fills the window with the look of this paint's chrome.
		background = a.colors.Chrome
		paint(canvas, size)
		a.endPaint()
	}
	return config
}

// beginPaint settles the look of the paint about to be declared and forgets what the last
// paint declared that this one declares afresh.
func (a *App) beginPaint(canvas *gfx.Canvas) {
	a.theme, a.colors = look(a.settings.Theme)
	a.shared.text.Store(a.text)
	a.shared.dark.Store(a.colors.Dark)
	a.status.frame(canvas, a.now())
	a.chrome.beginFrame()
	a.beginTerminalFrame()
	if a.clone.open || a.newProject.open {
		// The original centered clone panel opens without a fade. The rest of the window is
		// blocked by its modal while this theme is used.
		a.theme.Transition.Duration = 0
	}
	a.endDrags()
}

// endPaint settles what the paint declared.
func (a *App) endPaint() { a.endTerminalFrame() }

// page declares the window: one stack, so what is declared after the workbench lies over it
// and an overlay that hangs off a point of the window is placed against the whole window.
func (a *App) page(c ui.C) {
	ui.Stack(c).Fill().Children(func() {
		if a.project == nil {
			a.welcomePanel(c)
		} else {
			a.workbench(c)
		}
		a.windowShortcuts(c)
		a.overlays(c)
		ui.Toasts(c, &a.overlay.toaster)
	})
}

// workbench declares the window of an open project: the title bar over the stripes and the
// main column, over the status bar.
func (a *App) workbench(c ui.C) {
	// A copy: a click on a stripe button changes a.chrome while this paint is still being
	// declared, and the panels must be declared for the same tool windows the sizes were
	// worked out for.
	open := a.chrome.open
	a.layout.capture()
	plan := a.layout.arrange(c.Bounds(), open)
	// The hide button is only noted while the paint is declared and acted on at its end, so
	// the stripes and the status bar are declared with the same state as the panels.
	hidden := slotCount
	root := c.Part("workbench")
	ui.Column(root).Fill().
		HitWith(ui.ID(root), a.text.App.Name, gfx.HitOptions{SkipFocus: true}).
		DropTarget(&a.dnd.tool, a.toolAccept, a.toolDrop).
		DropTarget(&a.dnd.tab, a.tabAccept, a.tabDrop).
		Children(func() {
			a.titleBar(c)
			ui.Row(c).Fill().Children(func() {
				a.stripe(c, true)
				a.shellMain(c, plan, open, &hidden)
				a.stripe(c, false)
			})
			a.statusBar(c)
			a.dragLayer(c)
		})
	if hidden != slotCount {
		c.After(func() { a.hidePanel(hidden) })
	}
}

// windowShortcuts declares the window's own chords: Command-comma opens the settings,
// Command-O asks for a project folder, Shift-Command-L shows the log window, and with a
// project open Shift-Command-O searches everywhere, Shift-Command-F finds in files and the
// navigation chord goes to a line.
func (a *App) windowShortcuts(c ui.C) {
	if ui.Shortcut(c, ui.Primary, ",") {
		c.After(func() { a.openSettings(surfaceShortcut) })
	}
	if ui.Shortcut(c, ui.Primary, "o") {
		c.After(func() { a.chooseProject(surfaceShortcut) })
	}
	if ui.Shortcut(c, ui.Primary|ui.Shift, "l") {
		c.After(a.openLogs)
	}
	p := a.project
	if p == nil {
		return
	}
	if ui.Shortcut(c, ui.Primary|ui.Shift, "o") {
		c.After(func() {
			a.performed("workspace.searchEverywhere.open", surfaceShortcut)
			a.openEverywhere(p)
		})
	}
	if ui.Shortcut(c, ui.Primary|ui.Shift, "f") {
		c.After(func() {
			a.reduceChrome(core.SetChromeOpen(itemFind, true))
			a.searchView.focus = true
		})
	}
	if ui.Shortcut(c, ui.Primary, "k") {
		if view := a.focusedDocument(c.Canvas().Focused()); view != nil {
			c.After(func() { a.requestInlineEdit(p, view) })
		}
	}
	key, modifiers := "g", ui.Ctrl
	if runtime.GOOS == "darwin" {
		key, modifiers = "l", ui.Primary
	}
	if ui.Shortcut(c, modifiers, key) && a.focusedTerminal(c.Canvas().Focused()) == nil &&
		(runtime.GOOS == "darwin" || a.focusedDocument(c.Canvas().Focused()) != nil) {
		c.After(func() { a.openNavigation(p) })
	}
}

// overlays declares everything the window shows over the workbench: the dialogs, the search
// and navigation popups, the language popups, the plugin review and prompts, the Git dialogs
// and the New Project dialog. Each dialog's state stays with its own file; the toasts are
// declared last, over all of them.
func (a *App) overlays(c ui.C) {
	a.cloneView(c)
	if a.project != nil {
		a.everywherePopup(c)
		a.navigationPopup(c)
		a.semanticPopups(c)
		a.lspLogPopup(c)
	}
	a.pluginReviewView(c)
	a.pluginPromptView(c)
	if p := a.project; p != nil {
		a.drawBranchDialog(c, p)
		a.drawSyncDialog(c, p)
		a.inlineEditView(c, p)
		a.reviewOverlays(c, p)
	}
	a.newProjectModal(c)
}

// dragLayer declares what a drag in progress paints over the workbench: the zones and
// previews a dragged button or tab would land in, and its ghost. It paints without a hit, so
// it takes no input from what it lies over.
func (a *App) dragLayer(c ui.C) {
	if !a.dnd.tool.Dragging() && !a.dnd.tab.Dragging() {
		return
	}
	ui.Row(c).Absolute().Left(0).Top(0).Fill().Draw(func(d *ui.DrawContext) {
		a.paintDrag(d.Canvas)
		a.paintTabDrag(d.Canvas)
	})
}
