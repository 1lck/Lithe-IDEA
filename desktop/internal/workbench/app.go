// Package workbench is the window of the Lithe desktop client: the start screen and the
// workbench of an open project, painted with Viva. The settings and the logs open in windows
// of their own (packages settingswindow and logwindow).
//
// The package keeps the state of the window and turns user gestures into kernel calls.
// It decides nothing the kernel decides: the order of recent projects, the arrangement
// of the rearrangeable buttons and what Git reports all come from the kernel (package
// core), and the window only remembers the answers and paints them. The tool windows are
// still empty shells; their contents come with the features that fill them.
//
// Everything runs on the window thread except kernel calls that run Git and the system's
// folder dialog, which run through App.background and hand their results back in OnWake.
package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"runtime/metrics"
	"strings"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logwindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/monogrid"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/flex"
	"github.com/vivaui/viva/ui"
)

// Kernel is what the window asks the kernel. *core.Client implements it; tests replace
// the calls that read the disk or run Git, so a screen can be checked against answers the
// test chooses.
type Kernel interface {
	Version() string
	ReduceRecentProjects(ctx context.Context, entries []core.RecentProject, action core.RecentAction, capacity int) (core.RecentProjectsResult, error)
	ReduceChromeLayout(ctx context.Context, catalog []core.ChromeItem, state core.ChromeLayout, action core.ChromeAction) (core.ChromeLayout, bool, error)
	GitStatus(ctx context.Context, root string) (core.GitStatus, error)
	GitReferences(ctx context.Context, root string) (core.GitReferences, error)
	GitHistoryPage(ctx context.Context, root, reference, cursor string, limit int) (core.GitHistoryPage, error)
	CloseGitHistoryCursor(ctx context.Context, root, cursor string) (bool, error)
	GitCommitFiles(ctx context.Context, root, commit string) ([]core.GitCommitFile, error)
	GitCommit(ctx context.Context, root, commit string) (core.GitCommitDetail, error)
	GitGraph(ctx context.Context, request core.GraphRequest) (core.Graph, error)
	GitReferenceTree(ctx context.Context, names []string, prioritized map[string]bool) ([]core.ReferenceTreeNode, error)
	GitHistoryDates(ctx context.Context, entries []core.HistoryDateEntry, after, before *int64) ([]string, error)
	ReduceEditorWorkbench(ctx context.Context, state core.EditorWorkbench, action core.EditorAction) (core.EditorWorkbench, []string, error)
}

// Options configure a window.
type Options struct {
	Kernel Kernel
	// Store is where settings, recent projects and the layout are kept.
	Store *store.Store
	// Languages are the system's preferred languages, most preferred first; nil asks
	// the system.
	Languages []string
	// Now is the clock; nil is time.Now.
	Now func() time.Time
	// Logs is the client's log, which the log window reads and the window writes its own
	// events to; nil leaves the log window out.
	Logs LogSink
	// LogKernel parses filters and formats copied records for the log window; it is
	// required with Logs.
	LogKernel logwindow.Kernel
	// Version is the client's version, written into the environment of copied records.
	Version string
}

// LogSink is the client's log as the window uses it: the log window reads it and the
// window records what the user does to a project. *logstore.Store implements it.
type LogSink interface {
	logwindow.Source
	Emit(level core.LogLevel, event, op string, fields map[string]any)
}

// logsShortcut opens the log window, as on macOS.
const logsShortcut = "⇧⌘L"

// settings are the user's choices, kept in settingsFile.
type settings struct {
	// Language is a stored i18n code; empty follows the system.
	Language string      `json:"language,omitempty"`
	Theme    themeChoice `json:"theme,omitempty"`
}

const (
	settingsFile = "settings.json"
	recentFile   = "recent-projects.json"
)

// project is an open project. A project is replaced, never reused: background work
// keeps the pointer it started for and its result is dropped once a.project is a
// different one (see App.background).
type project struct {
	// root is the absolute, cleaned path of the project folder.
	root string
	// name is the folder's name, shown in the title bar.
	name string
	// ctx ends when the project closes, which stops its kernel calls.
	ctx    context.Context
	cancel context.CancelFunc
	git    gitState
	log    gitLogState
	// terms are the project's terminals and where each one is placed: in the Terminal tool
	// window or in a group of the editor area. A terminal's shell starts when it is first
	// painted, and every shell ends when the project closes.
	terms terminalSet
}

// App is the state of the window.
type App struct {
	kernel      Kernel
	store       *store.Store
	now         func() time.Time
	invalidator app.Invalidator
	view        flex.View
	tasks       taskQueue

	settings       settings
	systemLanguage i18n.Language
	// text is the catalog of the current language; theme and colors are the look
	// of the frame being painted.
	text   *i18n.Messages
	theme  ui.Theme
	colors palette

	// notice is the message of the banner, empty when there is none.
	notice string
	// settingsWindow opens the settings window and keeps at most one open.
	settingsWindow *settingswindow.Controller

	welcome welcomeState
	recent  []core.RecentProject
	// missing marks recent projects whose folder was gone when the list last changed.
	missing map[string]bool

	project *project
	chrome  chromeState
	drag    dragState
	title   titleState
	layout  layoutState
	status  statusState
	logView logView
	// delays are how long the log waits before it acts on a selection or a filter.
	delays logDelays
	// term is what the frame being painted declared for the terminals, and the gesture that
	// drags a terminal's tab (see terminal.go and tabdrag.go).
	term terminalUI
	// fields answers Config.TextInput for the window's text fields; the terminal's grid is
	// told apart from them in textInput.
	fields func(app.TextInputContext) *app.TextInput

	// application is the running application the log window opens in; it is nil until
	// Run has started it.
	application *app.Application
	// logSink is the client's log and logs the controller of its window; both are nil
	// when the window was made without a log.
	logSink LogSink
	logs    *logwindow.Controller
	// shared is what the log window reads from its own thread: the language and the look
	// of the frame last painted.
	shared struct {
		text atomic.Pointer[i18n.Messages]
		dark atomic.Bool
	}
}

// New makes the window's state and reads what the store kept.
func New(options Options) *App {
	languages := options.Languages
	if languages == nil {
		languages = app.PreferredLanguages()
	}
	now := options.Now
	if now == nil {
		now = time.Now
	}
	a := &App{
		kernel:         options.Kernel,
		store:          options.Store,
		now:            now,
		systemLanguage: i18n.Detect(languages),
		chrome:         newChromeState(),
		layout:         newLayoutState(),
		missing:        map[string]bool{},
		logView:        newLogView(),
		delays:         defaultLogDelays,
	}
	if _, err := a.store.Load(settingsFile, &a.settings); err != nil {
		a.settings = settings{}
	}
	a.text = i18n.For(a.language())
	a.theme, a.colors = look(a.settings.Theme)
	a.shared.text.Store(a.text)
	a.shared.dark.Store(a.colors.Dark)
	if options.Logs != nil {
		a.logSink = options.Logs
		version := options.Version
		a.logs = logwindow.NewController(logwindow.WindowOptions{
			Options: logwindow.Options{
				Source: options.Logs,
				Kernel: options.LogKernel,
				Store:  options.Store,
				Now:    now,
				Environment: func() core.LogEnvironment {
					return core.LogEnvironment{AppVersion: version, OsVersion: runtime.GOOS, Architecture: runtime.GOARCH}
				},
			},
			Text:     a.shared.text.Load,
			Dark:     a.shared.dark.Load,
			Shortcut: logsShortcut,
		})
	}
	a.settingsWindow = a.newSettingsWindow()
	a.loadRecent()
	a.loadChrome()
	return a
}

// Run shows the window and returns when it is closed.
func (a *App) Run() error {
	app.SetNativeAppearance(nativeAppearance(a.settings.Theme))
	stop := app.WatchSystemAppearance(a.invalidator.Invalidate)
	defer stop()
	// app.Run opens a bare window that never paints; the window with the frame callbacks
	// is opened by the application.
	err := app.RunApplication(func(application *app.Application) error {
		a.application = application
		_, err := application.OpenWindow(a.Config(), nil)
		return err
	})
	a.closeProject()
	a.wait()
	if a.logs != nil {
		a.logs.Wait()
	}
	return err
}

// Config is the window's configuration.
func (a *App) Config() app.Config {
	a.fields = flex.Fields(&a.welcome.search, &a.logView.search, &a.logView.refSearch, &a.logView.userSearch, &a.logView.pathField)
	return app.Config{
		Title:          a.text.App.Name,
		Width:          1280,
		Height:         800,
		MinWidth:       900,
		MinHeight:      600,
		WindowMode:     app.WindowCustomTitlebar,
		TitlebarHeight: titleBarHeight,
		Tree:           &tree,
		Paint:          a.paint,
		OnPointer:      a.onPointer,
		OnKey:          a.onKey,
		OnShortcut:     a.onShortcut,
		OnScroll:       a.onScroll,
		TextInput:      a.textInput,
		Invalidator:    &a.invalidator,
		OnWake:         a.drain,
		OnClosed:       a.closed,
	}
}

// closed runs when the window has closed: the project closes, and so does the log window,
// which would otherwise keep the application running without the window it belongs to.
func (a *App) closed() {
	a.closeProject()
	a.settingsWindow.Close()
	if a.logs != nil {
		a.logs.Close()
	}
}

// openLogs shows the log window. The window is opened from the queue drained in OnWake,
// not from the paint or the event that asked for it, because opening a window while this
// one is painting is not allowed.
func (a *App) openLogs() {
	if a.logs == nil {
		a.notify(a.text.Title.LogsUnavailable)
		return
	}
	a.post(func(a *App) {
		if a.application == nil {
			return
		}
		if err := a.logs.Open(a.application); err != nil {
			a.notify(a.text.Errors.LogsFailed(err.Error()))
		}
	})
}

// emit writes one of the window's own events to the client's log, when there is one.
func (a *App) emit(level core.LogLevel, event string, fields map[string]any) {
	if a.logSink != nil {
		a.logSink.Emit(level, event, "", fields)
	}
}

// Surfaces a user action can be started from, written as the catalog's tokens.
const (
	surfaceButton   = "button"
	surfaceMenu     = "menu"
	surfaceShortcut = "shortcut"
)

// performed logs that the user started the action with the stable id from surface, as the
// macOS client does; the id is never a localized title.
func (a *App) performed(action, surface string) {
	a.emit(core.LevelInfo, "app.action.performed", map[string]any{"action": action, "surface": surface})
}

// titleBarHeight is the height of the title bar on both screens; the system's window
// buttons sit in it.
const titleBarHeight = 40

// language is the language the window is shown in.
func (a *App) language() i18n.Language {
	if language, ok := i18n.Parse(a.settings.Language); ok {
		return language
	}
	return a.systemLanguage
}

func (a *App) paint(canvas *ui.Canvas, size ui.Size) {
	// Everything this pass paints in a fixed-pitch font goes on the cell grid it was laid out on.
	defer monogrid.Snap(canvas, len(canvas.Texts()))
	a.theme, a.colors = look(a.settings.Theme)
	a.shared.text.Store(a.text)
	a.shared.dark.Store(a.colors.Dark)
	bounds := ui.Rect{Width: size.Width, Height: size.Height}
	canvas.Fill(bounds, a.colors.Chrome)
	a.status.frame(canvas, a.now())
	a.chrome.beginFrame()
	a.logView.beginFrame()
	a.beginTerminalFrame()
	a.view.Draw(canvas, a.theme, bounds, func(f *flex.Frame) {
		// Popups go on a layer of their own so the commit rows painted after Draw stay
		// under them.
		f.PopupLayer(1)
		if a.project != nil {
			a.drawWorkbench(f)
		} else {
			a.drawWelcome(f)
		}
		a.drawNotice(f)
	})
	a.chrome.capture()
	a.layout.capture()
	a.logView.capture()
	a.paintGitLog(canvas)
	// Like the commit rows, the terminal is painted into a box of the frame that was just
	// laid out, under the menus and the dragged button.
	a.paintTerminal(canvas)
	// The menus and the dragged buttons and tabs float above everything Draw painted.
	a.paintChromeMenus(canvas, bounds)
	a.paintDrag(canvas)
	a.paintTabDrag(canvas)
}

// notify shows message in the banner until it is dismissed or replaced.
func (a *App) notify(message string) { a.notice = message }

// drawNotice is the banner above the bottom right corner of the window.
func (a *App) drawNotice(f *flex.Frame) {
	if a.notice == "" {
		return
	}
	bounds := f.Bounds()
	anchor := ui.Rect{X: bounds.X, Y: bounds.Y + bounds.Height - 32, Width: bounds.Width - 16, Height: 32}
	f.Popup().Above(anchor, 8, flex.End).Width(400).Pad(12).Gap(8).Items(flex.Start).
		Background(a.theme.Popover).Border(1, a.theme.Border).Radius(a.theme.Metrics.RadiusPopup()).Shadow(ui.ShadowMD).
		Children(func() {
			f.Row().Children(func() {
				f.Icon(icons.CircleAlert).Size(16, 16).Color(a.colors.Warning)
			})
			f.Paragraph(a.notice, 4).Grow(1)
			dismiss := f.Row().Size(20, 20).Center().Radius(a.theme.Metrics.RadiusItem()).
				Hit(noticeDismiss, a.text.Errors.Dismiss).
				Hover(flex.Look{}.Background(a.colors.Hover)).Pressed(flex.Look{}.Background(a.colors.Active))
			dismiss.Children(func() {
				f.Icon(icons.X).Size(12, 12).Color(a.colors.Subtle).StateFrom(dismiss).Hover(flex.Look{}.Color(a.colors.Text))
			})
			if dismiss.Clicked() {
				a.notice = ""
			}
		})
}

func (a *App) onPointer(event ui.PointerEvent) ui.EventResult {
	// A drag of a tool button or of a terminal's tab comes first, so it keeps its gestures
	// over a terminal.
	if result, handled := a.dragPointer(event); handled {
		return result
	}
	if result, handled := a.tabDragPointer(event); handled {
		return result
	}
	if result, handled := a.terminalPointer(event); handled {
		return result
	}
	return ui.EventResult{}
}

func (a *App) onKey(event ui.KeyEvent) ui.EventResult {
	if !event.Release && event.Key == ui.KeyEscape {
		// Both are called: at most one gesture is under way, and neither may be left behind.
		button, tab := a.cancelDrag(), a.cancelTabDrag()
		if button || tab {
			return ui.EventResult{Handled: true, Repaint: true}
		}
		if r := a.projectMenuKey(event); r.Handled {
			return r
		}
	}
	// The terminal sees the release of a key as well: a program can ask for them.
	if t := a.focusedTerminal(event.Target); t != nil {
		if result, handled := t.Key(event); handled {
			return result
		}
	}
	if event.Release {
		return ui.EventResult{}
	}
	if r := a.logKey(event); r.Handled {
		return r
	}
	if r := a.editorSplitKey(event); r.Handled {
		return r
	}
	return a.layout.key(event)
}

// onShortcut handles the window's command shortcuts, and gives the ones that are not its own
// to the terminal that has the keyboard: Control-C and the other chords of the shell arrive
// here, not in onKey.
func (a *App) onShortcut(event ui.KeyEvent) ui.EventResult {
	if !event.Release {
		if result := a.windowShortcut(event); result.Handled {
			return result
		}
	}
	if t := a.focusedTerminal(event.Target); t != nil {
		if result, handled := t.Shortcut(event); handled {
			return result
		}
	}
	return ui.EventResult{}
}

// windowShortcut handles the window's own command shortcuts: ⌘, opens the settings, ⌘O asks
// for a project folder and ⇧⌘L shows the log window.
func (a *App) windowShortcut(event ui.KeyEvent) ui.EventResult {
	if event.Modifiers == ui.ModifierMeta|ui.ModifierShift && strings.EqualFold(event.Text, "l") {
		a.openLogs()
		return ui.EventResult{Handled: true, Repaint: true}
	}
	if event.Modifiers != ui.ModifierMeta {
		return ui.EventResult{}
	}
	switch event.Text {
	case ",":
		a.openSettings(surfaceShortcut)
	case "o":
		a.chooseProject(surfaceShortcut)
	default:
		return ui.EventResult{}
	}
	return ui.EventResult{Handled: true, Repaint: true}
}

// setLanguage switches the window to a stored i18n code; empty follows the system.
func (a *App) setLanguage(code string) {
	if a.settings.Language == code {
		return
	}
	a.settings.Language = code
	a.text = i18n.For(a.language())
	a.saveSettings()
}

// setTheme switches the look of the window.
func (a *App) setTheme(choice themeChoice) {
	if a.settings.Theme == choice {
		return
	}
	a.settings.Theme = choice
	app.SetNativeAppearance(nativeAppearance(choice))
	a.saveSettings()
}

func (a *App) saveSettings() {
	if err := a.store.Save(settingsFile, a.settings); err != nil {
		a.notify(a.text.Errors.SaveFailed(err.Error()))
	}
}

// resetLayout puts every rearrangeable button back where the catalog puts it.
func (a *App) resetLayout() { a.reduceChrome(core.ResetChrome()) }

// activate is a click on the rearrangeable button of catalog item index: a tool
// button opens or closes its tool window, the settings button opens or closes its menu
// and the commands that need a provider that is not connected yet say so.
func (a *App) activate(index int) {
	it := catalog[index]
	switch {
	case it.panel:
		a.reduceChrome(core.ToggleChrome(it.id))
	case it.id == itemTitleSettings:
		a.title.gearOpen = !a.title.gearOpen
		a.title.projectOpen = false
	case it.id == itemRunConfig || it.id == itemTitleRun || it.id == itemTitleDebug:
		a.notify(a.text.Title.RunLater)
	case it.id == itemTitleSearch:
		a.notify(a.text.Welcome.Unavailable)
	}
}

// hidePanel closes the tool window open in a slot.
func (a *App) hidePanel(s slot) {
	if index := a.chrome.open[s]; index >= 0 {
		a.reduceChrome(core.SetChromeOpen(catalog[index].id, false))
	}
}

// loadRecent reads the recent project list and lets the kernel order and bound it.
func (a *App) loadRecent() {
	var entries []core.RecentProject
	if _, err := a.store.Load(recentFile, &entries); err != nil {
		a.notify(a.text.Errors.Core(err.Error()))
		entries = nil
	}
	a.reduceRecent(entries, core.NormalizeRecent(), false)
}

// reduceRecent sends one change of the recent project list to the kernel and keeps
// the result, saving it when save is set.
func (a *App) reduceRecent(entries []core.RecentProject, action core.RecentAction, save bool) {
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	result, err := a.kernel.ReduceRecentProjects(ctx, entries, action, 0)
	if err != nil {
		a.notify(a.text.Errors.Core(err.Error()))
		return
	}
	a.recent = result.Entries
	clear(a.missing)
	for _, entry := range a.recent {
		if info, err := os.Stat(entry.Path); err != nil || !info.IsDir() {
			a.missing[entry.Path] = true
		}
	}
	if !save {
		return
	}
	if err := a.store.Save(recentFile, a.recent); err != nil {
		a.notify(a.text.Errors.SaveFailed(err.Error()))
	}
}

// chooseProject asks for a project folder and opens it; surface is where the user asked.
// The system dialog runs off the window thread so the window keeps painting behind it.
func (a *App) chooseProject(surface string) {
	title := a.text.Welcome.OpenDialogTitle
	a.background(nil, 0, func(context.Context) func(*App) {
		path, err := app.OpenDirectory(app.OpenDirectoryOptions{Title: title})
		return func(a *App) {
			switch {
			case errors.Is(err, app.ErrCanceled):
			case err != nil:
				a.notify(a.text.Errors.OpenFailed(err.Error()))
			default:
				a.performed("workspace.open", surface)
				a.openProject(path)
			}
		}
	})
}

// openProject opens the folder at path as the project of the window, replacing the one
// that was open.
func (a *App) openProject(path string) {
	root, err := filepath.Abs(path)
	if err != nil {
		a.notify(a.text.Errors.OpenFailed(err.Error()))
		return
	}
	if info, err := os.Stat(root); err != nil || !info.IsDir() {
		a.notify(a.text.Errors.FolderMissing(root))
		return
	}
	a.reduceRecent(a.recent, core.RecordRecent(root, a.now()), true)
	a.closeProject()
	ctx, cancel := context.WithCancel(context.Background())
	p := &project{root: root, name: filepath.Base(root), ctx: ctx, cancel: cancel}
	a.openTerminals(p)
	a.project = p
	a.notice = ""
	a.logView.reset()
	a.loadGit(p)
	a.loadLog(p)
}

// closeProject closes the open project and goes back to the start screen.
func (a *App) closeProject() {
	if a.project == nil {
		return
	}
	a.project.cancel()
	a.closeTerminals(a.project)
	a.project = nil
	a.cancelDrag()
	a.cancelTabDrag()
	a.title = titleState{}
}

// statusState is what the status bar measures about the window itself.
type statusState struct {
	// frames are the times of the paints of the last second, oldest first.
	frames []time.Time
	// fps is the number of paints in the second before the last paint.
	fps int
	// memory is the memory the process's Go runtime holds, in bytes, sampled at most
	// once a second.
	memory    uint64
	sampledAt time.Time
	sample    []metrics.Sample
}

// memoryMetric is the memory the Go runtime has mapped and not returned to the system.
const (
	memoryMetric   = "/memory/classes/total:bytes"
	releasedMetric = "/memory/classes/heap/released:bytes"
)

// frame counts a paint at now. While the window paints, the count of the last second is
// shown; after the last paint of a burst one more paint is asked for a second later, so
// the readout settles instead of keeping the count of the burst. That paint asks for no
// other.
func (s *statusState) frame(canvas *ui.Canvas, now time.Time) {
	cutoff := now.Add(-time.Second)
	drop := 0
	for drop < len(s.frames) && !s.frames[drop].After(cutoff) {
		drop++
	}
	s.frames = append(s.frames[:0], s.frames[drop:]...)
	s.frames = append(s.frames, now)
	s.fps = len(s.frames)
	if s.fps > 1 {
		canvas.RequestFrameIn(time.Second)
	}
	if !s.sampledAt.IsZero() && now.Sub(s.sampledAt) < time.Second {
		return
	}
	s.sampledAt = now
	if s.sample == nil {
		s.sample = []metrics.Sample{{Name: memoryMetric}, {Name: releasedMetric}}
	}
	metrics.Read(s.sample)
	if s.sample[0].Value.Kind() == metrics.KindUint64 && s.sample[1].Value.Kind() == metrics.KindUint64 {
		s.memory = s.sample[0].Value.Uint64() - s.sample[1].Value.Uint64()
	}
}
