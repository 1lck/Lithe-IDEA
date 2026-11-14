package workbench

import (
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// A window has one workbench for each project open in it. The IDE's project tabs work the same
// way. This Window opens a project beside the open one instead of replacing it. The strip of
// project tabs over the main column switches between them, and the window shows the active
// workbench and gives it its input.
//
// Each workbench is a whole App, with its own page, plugin backends and language servers. A
// project in a hidden tab keeps its terminals, runs and Git watch going, and their results land
// in its own state. A hidden tab is not painted. What belongs to the window rather than to a
// project exists once: the window, its invalidator, the log window and the update check come
// from the first workbench (the one Run made), and the others borrow them. The process ledger
// belongs to the first workbench's plugin stack. The others open theirs without sweeping
// interrupted installs or offering leftover processes (pluginservice.OpenAnother).
//
// Plugin web pages need the window's web host, which only the first workbench has.

// windowWake asks the window for a repaint through the invalidator the window was opened with.
// Every workbench of the window holds the same one. The zero value, which a workbench made
// without New has, does nothing.
type windowWake struct{ invalidator *app.Invalidator }

// Invalidate requests one repaint of the window.
func (w windowWake) Invalidate() {
	if w.invalidator != nil {
		w.invalidator.Invalidate()
	}
}

// windowSessions are the workbenches of one window.
type windowSessions struct {
	// list holds the workbenches of the open tabs, in the order of the strip. It always holds
	// at least one, which shows the welcome screen when it has no project.
	list []*App
	// active is the workbench the window shows.
	active *App
	// retired are the workbenches whose tab closed. Run still waits for their work when the
	// window closes.
	retired []*App
	// configs are the page configurations of the workbenches, made once for each.
	configs map[*App]app.Config
	// options make the workbench of a new tab.
	options Options
}

// Project tab metrics, as the earlier client drew them.
const (
	projectTabStripHeight = 36
	projectTabHeight      = 28
	projectTabMinWidth    = 120
	projectTabMaxWidth    = 360
	projectTabGap         = 6
	projectTabIcon        = 16
)

// newWindowSessions makes the sessions of the window whose first workbench is first.
func newWindowSessions(first *App, options Options) *windowSessions {
	options.OpenPath = ""
	options.first = first
	return &windowSessions{list: []*App{first}, active: first, configs: map[*App]app.Config{}, options: options}
}

// config is the window's configuration. It takes the window's settings from the first
// workbench. Painting, typing, the pointer and the wheel go to the active workbench. Waking,
// focus loss, fullscreen and closing go to every workbench.
func (s *windowSessions) config() app.Config {
	window := s.of(s.list[0])
	shown := func() app.Config { return s.of(s.active) }
	window.WindowControls = func() app.WindowControlsStyle { return shown().WindowControls() }
	window.Paint = func(canvas *gfx.Canvas, size gfx.Size) { shown().Paint(canvas, size) }
	window.TextInput = func(context app.TextInputContext) *app.TextInput {
		if input := shown().TextInput; input != nil {
			return input(context)
		}
		return nil
	}
	window.OnPointer = func(event gfx.PointerEvent) gfx.EventResult {
		return forward(shown().OnPointer, event)
	}
	window.OnKey = func(event gfx.KeyEvent) gfx.EventResult { return forward(shown().OnKey, event) }
	window.OnShortcut = func(event gfx.KeyEvent) gfx.EventResult { return forward(shown().OnShortcut, event) }
	window.OnModifierTap = func(event gfx.ModifierTapEvent) gfx.EventResult {
		return forward(shown().OnModifierTap, event)
	}
	window.OnScroll = func(event gfx.ScrollEvent) gfx.EventResult { return forward(shown().OnScroll, event) }
	window.OnFileDrop = func(event gfx.FileDropEvent) gfx.EventResult { return forward(shown().OnFileDrop, event) }
	window.OnWake = func() {
		// A retired workbench still finishes work it began, such as stopping a debug session.
		for _, a := range s.everyOne() {
			a.drain()
		}
	}
	window.OnFocusLost = func() gfx.EventResult {
		var result gfx.EventResult
		for _, a := range s.list {
			// Another window holds the keyboard: every list greys the row it keeps selected
			// until this window is activated again.
			a.windowInactive = true
			a.applySelectionFocus()
			if lost := s.of(a).OnFocusLost; lost != nil {
				if answer := lost(); a == s.active {
					result = answer
				}
			}
			if a == s.active {
				result.Repaint = true
			}
		}
		return result
	}
	// OnActivate brings the selection color back when this window gets the keyboard again.
	window.OnActivate = func() {
		for _, a := range s.list {
			if !a.windowInactive {
				continue
			}
			a.windowInactive = false
			a.applySelectionFocus()
			a.invalidator.Invalidate()
		}
		// An automatic update check that came due while the window was in the background
		// runs now.
		if s.active != nil {
			s.active.resumeUpdateCheck()
		}
	}
	window.OnFullscreen = func(fullscreen bool) {
		for _, a := range s.list {
			a.fullscreen = fullscreen
		}
	}
	window.OnCloseRequest = s.closeAll
	window.OnClosed = func() {
		for _, a := range s.list {
			if closed := s.of(a).OnClosed; closed != nil {
				closed()
			}
		}
		if logs := s.list[0].logs; logs != nil {
			logs.Close()
		}
	}
	return window
}

// forward gives event to handle, which may be nil.
func forward[E any](handle func(E) gfx.EventResult, event E) gfx.EventResult {
	if handle == nil {
		return gfx.EventResult{}
	}
	return handle(event)
}

// of is the page configuration of workbench a.
func (s *windowSessions) of(a *App) app.Config {
	config, ok := s.configs[a]
	if !ok {
		config = a.sessionConfig()
		s.configs[a] = config
	}
	return config
}

// everyOne is every workbench the window made, open or retired.
func (s *windowSessions) everyOne() []*App {
	if s == nil {
		return nil
	}
	return append(append([]*App(nil), s.list...), s.retired...)
}

// showing is the workbench whose project is the folder at path, or nil.
func (s *windowSessions) showing(path string) *App {
	if s == nil {
		return nil
	}
	for _, a := range s.list {
		if a.project != nil && sameProjectRoot(path, a.project.root) {
			return a
		}
	}
	return nil
}

// activate shows workbench a. The workbench left behind saves its changed files, as it would
// when the window lost focus.
func (s *windowSessions) activate(a *App) {
	left := s.active
	if left == a {
		return
	}
	s.active = a
	if lost := s.of(left).OnFocusLost; lost != nil {
		lost()
	}
	// The window takes the title of the project it shows at the next paint.
	a.shownTitle = ""
	a.invalidator.Invalidate()
}

// openTab opens path in a new workbench of the window, in a tab after the others, and shows it.
func (s *windowSessions) openTab(path string) {
	a := New(s.options)
	s.list = append(s.list, a)
	s.activate(a)
	a.reloadPluginLanguages()
	a.loadGitHubAccount()
	a.openProjectHere(path)
}

// leave takes workbench a out of the strip once its project has closed, when the window has
// other tabs. The tab beside it is then shown. The last workbench stays and shows the welcome
// screen.
func (s *windowSessions) leave(a *App) {
	if s == nil || len(s.list) < 2 {
		return
	}
	at := -1
	for i, open := range s.list {
		if open == a {
			at = i
		}
	}
	if at < 0 {
		return
	}
	s.list = append(s.list[:at:at], s.list[at+1:]...)
	s.retired = append(s.retired, a)
	if s.active == a {
		s.activate(s.list[min(at, len(s.list)-1)])
	}
	a.unsubscribeSettings()
	a.closeClone()
	a.closeNewProject()
	a.settingsWindow.Close()
	if a.root != nil {
		a.root.Close()
	}
	delete(s.configs, a)
}

// closeAll closes the project of every tab before the window closes or the application quits.
// It closes them one at a time, starting with the one shown. Each tab is shown while it closes,
// so its save failures and its question about running processes are on screen. A tab whose
// closing is refused keeps the window open.
func (s *windowSessions) closeAll(allow func()) {
	a := s.active
	a.requestCloseProject(func() {
		if len(s.list) < 2 {
			allow()
			return
		}
		s.leave(a)
		s.closeAll(allow)
	})
}

// stripHeight is the height the strip of project tabs takes over the main column, with the gap
// under it. It is zero while the window has one project.
func (s *windowSessions) stripHeight() float32 {
	if s == nil || len(s.list) < 2 {
		return 0
	}
	return projectTabStripHeight + shellSplitter
}

// projectTabs declares the strip of project tabs while the window has more than one project.
func (a *App) projectTabs(c ui.C) {
	s := a.sessions
	if s.stripHeight() == 0 {
		return
	}
	c = c.Part("projecttabs")
	ui.Column(c).FillWidth().Height(s.stripHeight()).Shrink(0).Children(func() {
		ui.Row(c).FillWidth().Height(projectTabStripHeight).Shrink(0).Items(ui.Center).Gap(projectTabGap).PadX(projectTabGap).
			Background(a.colors.Panel).Clip().Children(func() {
			for i, tab := range s.list {
				a.projectTab(c, tab, i, len(s.list))
			}
		})
	})
}

// projectTab declares the tab of workbench tab: the folder, the project's name and the file its
// focused group shows, and the button that closes the project. The tab of a hidden workbench
// shows it, and closing it shows it first so its questions are on screen.
func (a *App) projectTab(c ui.C, tab *App, i, size int) {
	p := tab.project
	if p == nil {
		return
	}
	shown := tab == a.sessions.active
	k := c.Key(p.root)
	chip := ui.Row(k).Height(projectTabHeight).MinWidth(projectTabMinWidth).MaxWidth(projectTabMaxWidth).Shrink(0).
		Items(ui.Center).Gap(7).PadSides(0, 3, 0, 12).Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(k), p.name, gfx.HitOptions{
			Role: gfx.RoleTab, Cursor: gfx.PointerCursorHand, Selected: shown,
			PosInSet: int32(i + 1), SetSize: int32(size),
		}).
		Pressed(ui.Look{}.Background(a.colors.Active))
	if shown {
		chip = chip.Background(a.colors.Active)
	} else {
		chip = chip.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	var closeButton ui.Box
	chip.Children(func() {
		ui.Icon(k, icons.Folder).Size(projectTabIcon, projectTabIcon).Shrink(0).Color(a.colors.Subtle)
		name := ui.Text(k, p.name).Ellipsis().Shrink(0)
		if shown {
			name.Color(a.colors.Text)
		} else {
			name.Color(a.colors.Subtle).StateFrom(chip).Hover(ui.Look{}.Color(a.colors.Text))
		}
		if d := p.selectedDocument(p.terms.bench.FocusedGroup); d != nil && d.path != "" {
			ui.Text(k.Part("file"), "· "+filepath.Base(d.path)).Color(a.colors.Subtle).Ellipsis()
		}
		ui.Spacer(k)
		cc := k.Part("close")
		closeButton = ui.Row(cc).Size(terminalCloseSize, terminalCloseSize).Shrink(0).Center().
			Radius(a.theme.Metrics.RadiusItem()).
			HitWith(ui.ID(cc), a.text.Title.CloseProject, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).
			Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
		closeButton.Children(func() {
			ui.Icon(cc, icons.X).Size(terminalCloseIcon, terminalCloseIcon).Color(a.colors.Subtle).
				StateFrom(closeButton).Hover(ui.Look{}.Color(a.colors.Text))
		})
	})
	switch {
	case closeButton.Clicked():
		c.After(func() {
			a.performed("workspace.tab.close", surfaceButton)
			a.sessions.activate(tab)
			tab.closeProject()
		})
	case chip.Clicked():
		c.After(func() {
			a.performed("workspace.tab.show", surfaceButton)
			a.sessions.activate(tab)
		})
	}
}
