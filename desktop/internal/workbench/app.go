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
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"runtime/metrics"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/appicon"
	"github.com/1lck/Lithe-IDEA/desktop/internal/buildinfo"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logwindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugindiag"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/windowcontrols"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// Kernel is what the window asks the kernel. *core.Client implements it; tests replace
// the calls that read the disk or run Git, so a screen can be checked against answers the
// test chooses.
type Kernel interface {
	Version() string
	ReduceRecentProjects(ctx context.Context, entries []core.RecentProject, action core.RecentAction, capacity int) (core.RecentProjectsResult, error)
	GitCheckoutBranch(ctx context.Context, text string) (string, error)
	GitDirectoryPointer(ctx context.Context, text string) (string, error)
	ReduceChromeLayout(ctx context.Context, catalog []core.ChromeItem, state core.ChromeLayout, action core.ChromeAction) (core.ChromeLayout, bool, error)
	GitStatus(ctx context.Context, root string) (core.GitStatus, error)
	GitReferences(ctx context.Context, root string) (core.GitReferences, error)
	GitHistoryPage(ctx context.Context, root, reference, cursor string, limit int) (core.GitHistoryPage, error)
	DetectBuildSystems(ctx context.Context, workspaceRoot string, manifests []json.RawMessage) (core.BuildDetection, error)
	PlanBuildInvocation(ctx context.Context, manifest json.RawMessage, buildSystemID, root, platform string) (core.BuildInvocation, error)
	CheckBuildToolVersion(ctx context.Context, manifest json.RawMessage, buildSystemID, runtime, output string) (core.BuildToolVersion, error)
	PlanBuildModel(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildPlanRequest) (core.BuildPlan, error)
	PlanBuildTask(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildPlanRequest) (core.BuildPlan, error)
	PlanBuildRun(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildPlanRequest) (core.BuildPlan, error)
	DecodeBuildModel(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildDecodeModelRequest) (core.BuildModel, error)
	DecodeBuildRun(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildDecodeRunRequest) (core.BuildLaunch, error)
	CloseGitHistoryCursor(ctx context.Context, root, cursor string) (bool, error)
	GitCommitFiles(ctx context.Context, root, commit string) ([]core.GitCommitFile, error)
	GitCommit(ctx context.Context, root, commit string) (core.GitCommitDetail, error)
	GitGraph(ctx context.Context, request core.GraphRequest) (core.Graph, error)
	GitReferenceTree(ctx context.Context, names []string, prioritized map[string]bool) ([]core.ReferenceTreeNode, error)
	GitHistoryDates(ctx context.Context, entries []core.HistoryDateEntry, after, before *int64) ([]string, error)
	ReduceEditorWorkbench(ctx context.Context, state core.EditorWorkbench, action core.EditorAction) (core.EditorWorkbench, []string, error)
	GitStage(ctx context.Context, root string, paths []string) error
	GitClone(ctx context.Context, root, source, destination string) error
	CheckProjectName(context.Context, string) (core.ProjectNameProblem, error)
	InitializeGit(context.Context, string) error
	GitUnstage(ctx context.Context, root string, paths []string) error
	GitStageAll(ctx context.Context, root string) error
	WorkspaceCommitPrepare(ctx context.Context, request core.WorkspaceCommitRequest) (core.WorkspaceCommitPreparation, error)
	WorkspaceCommitStep(ctx context.Context, session core.WorkspaceCommitSession) (core.WorkspaceCommitSession, error)
	GitCheckoutPreflight(ctx context.Context, root string, reference core.GitReference) ([]string, error)
	GitCheckout(ctx context.Context, root string, reference core.GitReference, mode core.CheckoutMode) error
	GitCheckoutRevision(ctx context.Context, root, revision string) error
	GitCreateBranch(ctx context.Context, root, name string, from core.GitReference, checkout bool) error
	GitRenameBranch(ctx context.Context, root string, branch core.GitReference, name string) error
	GitDeleteBranch(ctx context.Context, root string, branch core.GitReference) (core.GitBranchDeletion, error)
	GitBranchNamePreview(ctx context.Context, request core.BranchNameRequest) (core.BranchNamePreview, error)
	ListDirectories(ctx context.Context, root string, paths []string) ([]core.DirectoryListing, error)
	PlanDocumentSaveBatch(ctx context.Context, documents []core.SaveBatchDocument) (core.SaveBatchPlan, error)
	ReduceDocumentSaveBatch(ctx context.Context, members []string, results []core.SaveBatchResult, documents []core.SaveBatchDocument) (core.SaveBatchDecision, error)
	ReduceDocument(ctx context.Context, state core.DocumentState, event core.DocumentEvent) (core.DocumentDecision, error)
	SearchWorkspace(ctx context.Context, request core.WorkspaceSearchRequest) ([]core.WorkspaceSearchMatch, error)
	InvalidateWorkspaceSearch(ctx context.Context, root string) error
	FilterWorkspaceChanges(ctx context.Context, paths []string) ([]string, error)
	UpdateWorkspaceSearch(ctx context.Context, root string, paths []string) error
	SearchEverywherePage(ctx context.Context, request core.EverywhereSearchRequest) (core.EverywhereSearchPage, error)
	RankNames(context.Context, string, []core.RankCandidate) ([]int, error)
	ParseNavigationInput(context.Context, string) (*core.NavigationTarget, error)
	PluginDocumentURI(ctx context.Context, path, platform string) (string, error)
	QueryProblems(ctx context.Context, request core.ProblemsQuery) (core.ProblemsResult, error)
	ResolveMarketplaceSource(context.Context, string) (core.MarketplaceSource, error)
	ValidateMarketplaceIndex(context.Context, json.RawMessage, core.MarketplaceSourceKind, string, map[string][]int) (core.MarketplaceIndex, error)
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
	// Version is the client's version: the start screen and the settings window show it, and
	// copied records carry it in their environment.
	Version string
	// PluginKernel runs plugin packages: it validates manifests, reviews installations and
	// starts plugin backends. It is separate from Kernel so that a window can be built
	// without the plugin stack; nil leaves plugins unavailable.
	PluginKernel pluginservice.Kernel
	// PluginRoot is the directory installed plugin packages live in. Empty asks
	// pluginpkg.DefaultRoot, which is the platform's own data directory.
	PluginRoot string
	// AgentKernel runs the Agent panel: adapter detection, credential-free
	// provider discovery and the Core ACP connection. nil leaves the panel
	// unavailable instead of refusing to start.
	AgentKernel AgentKernel
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
	Language         string      `json:"language,omitempty"`
	Theme            themeChoice `json:"theme,omitempty"`
	MarketplaceWidth float32     `json:"marketplaceWidth,omitempty"`
	// HideMinimap hides the minimap of every editor; the editors show it by default.
	HideMinimap bool `json:"hideMinimap,omitempty"`
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
	commit commitState
	// terms are the project's terminals and where each one is placed: in the Terminal tool
	// window or in a group of the editor area. A terminal's shell starts when it is first
	// painted, and every shell ends when the project closes.
	terms terminalSet
	// docs are the project's open files. Each is a tab in a group of the editor area, next
	// to the terminals that were moved there.
	docs       documentSet
	search     projectSearch
	everywhere everywhereSearch
	// tree is the Project tool window's tree of the project folder.
	tree fileTree
	// build is the Run tool window's provider-backed instances and output.
	build buildState
	// agent is the project's Agent panel and connection.
	agent agentState
}

// App is the state of the window.
type App struct {
	kernel      Kernel
	store       *store.Store
	now         func() time.Time
	invalidator app.Invalidator
	view        ui.View
	tasks       taskQueue
	// languages are the languages the editor knows, made when the first file is opened.
	languages *syntax.Registry

	settings       settings
	systemLanguage i18n.Language
	// text is the catalog of the current language; theme and colors are the look
	// of the frame being painted.
	text   *i18n.Messages
	theme  gfx.Theme
	colors palette

	// notice is the message of the banner, empty when there is none.
	notice string
	// settingsWindow opens the settings window and keeps at most one open.
	settingsWindow *settingswindow.Controller
	// plugins is the plugin stack, nil when the window was built without a plugin
	// kernel or without a writable plugin root.
	plugins *pluginservice.Service
	// pluginInstall is the install the user started.
	pluginInstall pluginInstallState
	// pluginState is what the settings window reads from its own thread about
	// installed plugins; it is replaced whole, never mutated in place.
	pluginState atomic.Pointer[map[string]settingswindow.PluginState]
	// pluginServerMu guards the language-server maps because a build provider
	// may attach to a shared session from a background model load.
	pluginServerMu sync.Mutex
	// agentKernel is the Agent panel's kernel, nil when the window was built
	// without one.
	agentKernel AgentKernel
	// agentView is the window's Agent composer state; the project holds the rest.
	agentView agentView
	// agentClosing tracks Core sessions being closed off the window thread, so
	// shutdown waits for their process trees.
	agentClosing sync.WaitGroup
	// pluginServers are the language servers this window started, keyed by plugin.
	pluginServers map[string]*pluginServer
	// pluginServerLanguages maps a language to the plugin serving it, so opening a
	// second file does not resolve the provider again.
	pluginServerLanguages map[string]string
	// pluginServerStarting marks a language whose first start is in flight.
	pluginServerStarting map[string]bool
	// pluginServerSuppressed marks plugins the user disabled or uninstalled while
	// a start was in flight, so the finished start is disposed instead of
	// registering a server the plugin no longer owns.
	pluginServerSuppressed map[string]bool
	// pluginDiagnostics holds what each running language server published for
	// the files of the open project, keyed by plugin so stopping one server
	// withdraws only its own diagnostics.
	pluginDiagnostics map[string]*plugindiag.Set

	welcome    welcomeState
	clone      cloneState
	newProject newProjectState
	recent     []core.RecentProject
	// missing marks recent projects whose folder was gone when the list last changed.
	missing map[string]bool

	project         *project
	closingProject  bool
	documentWriter  func(string, []byte, []byte) error
	documentCreator func(string, []byte) error
	documentReader  func(string) ([]byte, error)
	chrome          chromeState
	drag            dragState
	title           titleState
	layout          layoutState
	status          statusState
	logView         logView
	// branch is the title bar's branch popup and the dialogs it opens.
	branch branchState
	// commitView is the Commit tool window's splitter and message input.
	commitView     commitView
	searchView     searchView
	everywhereView everywhereView
	// problems is the Problems tool window's cached Core answer.
	problems   problemsView
	navigation navigationView
	// delays are how long the log waits before it acts on a selection or a filter.
	delays logDelays
	// term is what the frame being painted declared for the terminals, and the gesture that
	// drags a terminal's tab (see terminal.go and tabdrag.go).
	term terminalUI
	// softWrap says the open files wrap their long lines at the width of their group instead
	// of scrolling sideways. The switch at the end of each group's strip of tabs turns it on
	// and off for every file at once; it lasts until the client quits.
	softWrap bool
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
	// version is Options.Version.
	version string
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
		kernel:          options.Kernel,
		documentWriter:  documentio.WriteGuarded,
		documentCreator: documentio.WriteMissing,
		documentReader:  readDocument,
		store:           options.Store,
		now:             now,
		systemLanguage:  i18n.Detect(languages),
		chrome:          newChromeState(),
		layout:          newLayoutState(),
		missing:         map[string]bool{},
		logView:         newLogView(),
		commitView:      newCommitView(),
		delays:          defaultLogDelays,
		agentKernel:     options.AgentKernel,
	}
	if _, err := a.store.Load(settingsFile, &a.settings); err != nil {
		a.settings = settings{}
	}
	a.searchView.delay = -1
	a.everywhereView.delay = -1
	a.version = options.Version
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
	a.openPlugins(options)
	a.settingsWindow = a.newSettingsWindow()
	a.loadRecent()
	a.loadChrome()
	return a
}

// openPlugins assembles the plugin stack.
//
// A window without a plugin kernel, or one whose platform data directory cannot be
// resolved, runs without plugins instead of refusing to start: nothing else in the
// workbench depends on them, and a start-up failure here would take the whole client
// down over an optional feature.
func (a *App) openPlugins(options Options) {
	if options.PluginKernel == nil {
		return
	}
	root := options.PluginRoot
	if root == "" {
		resolved, err := pluginpkg.DefaultRoot()
		if err != nil {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_root", err))
			return
		}
		root = resolved
	}
	service, err := pluginservice.Open(options.PluginKernel, a.store, root)
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_open", err))
		return
	}
	a.plugins = service
}

// Run shows the window and returns when it is closed.
func (a *App) Run() error {
	app.SetNativeAppearance(nativeAppearance(a.settings.Theme))
	stop := app.WatchSystemAppearance(a.systemAppearanceChanged)
	defer stop()
	// app.Run opens a bare window that never paints; the window with the frame callbacks
	// is opened by the application.
	err := app.RunApplication(func(application *app.Application) error {
		a.application = application
		// System Quit bypasses window close requests unless it is intercepted here.
		application.OnQuitRequest(a.requestCloseProject)
		if _, err := application.OpenWindow(a.Config(), nil); err != nil {
			return err
		}
		// The plugin stack is assembled before the window exists, because opening a
		// window is what installs the invalidator its background work needs.
		a.reloadPluginLanguages()
		// Development builds mark the Dock icon without changing the product name in the UI.
		if buildinfo.Development {
			application.SetDockBadge(a.text.App.DevBadge)
		}
		return nil
	})
	a.closeProject()
	a.wait()
	if a.logs != nil {
		a.logs.Wait()
	}
	return err
}

// systemAppearanceChanged hands the system event to the workbench thread before
// publishing the effective palette to its other windows.
func (a *App) systemAppearanceChanged() {
	a.post(func(a *App) {
		if a.settings.Theme != themeSystem {
			return
		}
		a.theme, a.colors = look(themeSystem)
		a.shared.dark.Store(a.colors.Dark)
		if a.logs != nil {
			a.logs.Invalidate()
		}
	})
}

// Config is the window's configuration.
func (a *App) Config() app.Config {
	a.fields = ui.Fields(&a.welcome.search, &a.clone.source, &a.clone.parent, &a.clone.name, &a.newProject.name, &a.newProject.parent, &a.newProject.search, &a.logView.search, &a.logView.refSearch, &a.logView.userSearch, &a.logView.pathField, &a.searchView.query, &a.searchView.mask, &a.everywhereView.query,
		&a.branch.search, &a.branch.name, &a.branch.revision, &a.navigation.input)
	return app.Config{
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
		Paint:          a.paint,
		OnPointer:      a.onPointer,
		OnKey:          a.onKey,
		OnShortcut:     a.onShortcut,
		OnScroll:       a.onScroll,
		TextInput:      a.textInput,
		Invalidator:    &a.invalidator,
		OnWake:         a.drain,
		OnCloseRequest: func(allow func()) { a.requestCloseProject(allow) },
		OnClosed:       a.closed,
	}
}

// closed runs when the window has closed: the project closes, and so does the log window,
// which would otherwise keep the application running without the window it belongs to.
func (a *App) closed() {
	a.closeClone()
	a.closeNewProject()
	a.closeWelcomeBranchReads()
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

func (a *App) paint(canvas *gfx.Canvas, size gfx.Size) {
	a.theme, a.colors = look(a.settings.Theme)
	a.shared.text.Store(a.text)
	a.shared.dark.Store(a.colors.Dark)
	bounds := gfx.Rect{Width: size.Width, Height: size.Height}
	canvas.Fill(bounds, a.colors.Chrome)
	a.status.frame(canvas, a.now())
	a.chrome.beginFrame()
	a.agentView.beginFrame()
	a.logView.beginFrame()
	a.commitView.beginFrame()
	a.beginTerminalFrame()
	paintTheme := a.theme
	if a.clone.open || a.newProject.open {
		// The original centered clone panel opens without a fade. The rest of
		// the window is blocked by its modal scope while this theme is used.
		paintTheme.Transition.Duration = 0
	}
	a.view.Draw(canvas, paintTheme, bounds, func(f *ui.Frame) {
		// Popups go on a layer of their own so the commit rows painted after Draw stay
		// under them.
		f.PopupLayer(1)
		if a.project != nil {
			a.drawWorkbench(f)
			a.drawEverywhere(f, a.project)
			a.drawNavigation(f, a.project)
		} else {
			a.drawWelcome(f)
		}
		a.drawCloneDialog(f)
		a.drawNewProjectDialog(f)
		a.drawPluginReview(f)
		if a.newProject.restoreFocus {
			f.Canvas().RequestFocus(a.newProject.returnFocus)
			a.newProject.restoreFocus = false
		}
		if a.clone.restoreFocus {
			f.Canvas().RequestFocus(a.clone.returnFocus)
			a.clone.restoreFocus = false
		}
		a.drawNotice(f)
	})
	a.chrome.capture()
	if a.project != nil {
		a.agentView.capture(&a.project.agent)
	}
	a.layout.capture()
	a.logView.capture()
	a.commitView.capture()
	a.paintGitLog(canvas)
	// Like the commit rows, the terminal is painted into a box of the frame that was just
	// laid out, under the menus and the dragged button.
	a.paintTerminal(canvas)
	a.captureTree(canvas)
	// The menus and the dragged buttons and tabs float above everything Draw painted.
	a.paintChromeMenus(canvas, bounds)
	a.paintDrag(canvas)
	a.paintTabDrag(canvas)
}

// notify shows message in the banner until it is dismissed or replaced.
func (a *App) notify(message string) { a.notice = message }

// drawNotice is the banner above the bottom right corner of the window.
func (a *App) drawNotice(f *ui.Frame) {
	if a.notice == "" {
		return
	}
	bounds := f.Bounds()
	anchor := gfx.Rect{X: bounds.X, Y: bounds.Y + bounds.Height - 32, Width: bounds.Width - 16, Height: 32}
	f.Popup().Above(anchor, 8, ui.End).Width(400).Pad(12).Gap(8).Items(ui.Start).
		Background(a.theme.Popover).Border(1, a.theme.Border).Radius(a.theme.Metrics.RadiusPopup()).Shadow(gfx.ShadowMD).
		Children(func() {
			f.Row().Children(func() {
				f.Icon(icons.CircleAlert).Size(16, 16).Color(a.colors.Warning)
			})
			f.Paragraph(a.notice, 4).Grow(1)
			dismiss := f.Row().Size(20, 20).Center().Radius(a.theme.Metrics.RadiusItem()).
				Hit(noticeDismiss, a.text.Errors.Dismiss).
				Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
			dismiss.Children(func() {
				f.Icon(icons.X).Size(12, 12).Color(a.colors.Subtle).StateFrom(dismiss).Hover(ui.Look{}.Color(a.colors.Text))
			})
			if dismiss.Clicked() {
				a.notice = ""
			}
		})
}

func (a *App) onPointer(event gfx.PointerEvent) gfx.EventResult {
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
	if result, handled := a.documentPointer(event); handled {
		return result
	}
	if result, handled := a.treePointer(event); handled {
		return result
	}
	return gfx.EventResult{}
}

func (a *App) onKey(event gfx.KeyEvent) gfx.EventResult {
	if result := a.welcomeMenuKey(event); result.Handled {
		return result
	}
	if a.project != nil && a.navigation.open {
		if result := a.navigationKey(a.project, event); result.Handled {
			return result
		}
	}
	if a.project != nil && a.everywhereView.open {
		if result := a.everywhereKey(a.project, event); result.Handled {
			return result
		}
	}
	if !event.Release && event.Key == gfx.KeyEscape {
		if a.project == nil && a.welcome.moreOpen {
			a.welcome.moreOpen = false
			a.welcome.moreFocus = false
			a.welcome.moreRestore = true
			return gfx.EventResult{Handled: true, Repaint: true}
		}
		if a.project == nil && a.welcome.menuPath != "" {
			a.welcome.restoreMenuFocus = a.welcome.menuPath
			a.welcome.menuPath = ""
			a.welcome.menuFocus = gfx.ID{}
			return gfx.EventResult{Handled: true, Repaint: true}
		}
		// Both are called: at most one gesture is under way, and neither may be left behind.
		button, tab := a.cancelDrag(), a.cancelTabDrag()
		if button || tab {
			return gfx.EventResult{Handled: true, Repaint: true}
		}
		if r := a.projectMenuKey(event); r.Handled {
			return r
		}
		if r := a.branchMenuKey(event); r.Handled {
			return r
		}
	}
	// The terminal sees the release of a key as well: a program can ask for them.
	if t := a.focusedTerminal(event.Target); t != nil {
		if result, handled := t.Key(event); handled {
			return result
		}
	}
	if v := a.focusedDocument(event.Target); v != nil {
		if result, handled := v.Key(event); handled {
			return result
		}
	}
	if event.Release {
		return gfx.EventResult{}
	}
	if r := a.treeKey(event); r.Handled {
		return r
	}
	if r := a.searchKey(event); r.Handled {
		return r
	}
	if r := a.commitKey(event); r.Handled {
		return r
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
func (a *App) onShortcut(event gfx.KeyEvent) gfx.EventResult {
	if a.newProject.open {
		if event.Target == newProjectName || event.Target == newProjectParent || event.Target == newProjectSearch {
			return gfx.EventResult{}
		}
		return gfx.EventResult{Handled: true}
	}
	if a.clone.open {
		if event.Target == cloneSource || event.Target == cloneParent || event.Target == cloneName {
			return gfx.EventResult{}
		}
		return gfx.EventResult{Handled: true}
	}
	if a.navigation.open {
		// Let the field's text system handle copy, paste, and select-all, while
		// keeping workbench shortcuts from changing the project behind a modal.
		if event.Target == navigationField {
			return gfx.EventResult{}
		}
		return gfx.EventResult{Handled: true}
	}
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
	if v := a.focusedDocument(event.Target); v != nil {
		if result, handled := v.Shortcut(event); handled {
			return result
		}
	}
	return gfx.EventResult{}
}

// windowShortcut handles the window's own command shortcuts: ⌘, opens the settings, ⌘O asks
// for a project folder, ⇧⌘L shows the log window and ⌘↩ in the commit message commits.
func (a *App) windowShortcut(event gfx.KeyEvent) gfx.EventResult {
	if isNavigationShortcut(runtime.GOOS, event) && a.project != nil && a.focusedTerminal(event.Target) == nil &&
		(runtime.GOOS == "darwin" || a.focusedDocument(event.Target) != nil) {
		if a.openNavigation(a.project) {
			return gfx.EventResult{Handled: true, Repaint: true}
		}
	}
	if event.Modifiers == gfx.ModifierMeta|gfx.ModifierShift && strings.EqualFold(event.Text, "o") && a.project != nil {
		a.performed("workspace.searchEverywhere.open", surfaceShortcut)
		a.openEverywhere(a.project)
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	if event.Modifiers == gfx.ModifierMeta|gfx.ModifierShift && strings.EqualFold(event.Text, "f") && a.project != nil {
		a.reduceChrome(core.SetChromeOpen(itemFind, true))
		a.searchView.focus = true
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	if event.Modifiers == gfx.ModifierMeta && event.Key == gfx.KeyEnter && event.Target == commitMessageID && a.project != nil {
		if a.project.canCommit() {
			a.startCommit(a.project, false, surfaceShortcut)
		}
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	if event.Modifiers == gfx.ModifierMeta|gfx.ModifierShift && strings.EqualFold(event.Text, "l") {
		a.openLogs()
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	if event.Modifiers != gfx.ModifierMeta {
		return gfx.EventResult{}
	}
	switch event.Text {
	case ",":
		a.openSettings(surfaceShortcut)
	case "o":
		a.chooseProject(surfaceShortcut)
	default:
		return gfx.EventResult{}
	}
	return gfx.EventResult{Handled: true, Repaint: true}
}

// setLanguage switches the window to a stored i18n code; empty follows the system.
func (a *App) setLanguage(code string) {
	if a.settings.Language == code {
		return
	}
	a.settings.Language = code
	a.text = i18n.For(a.language())
	a.shared.text.Store(a.text)
	if a.settingsWindow != nil {
		a.settingsWindow.Invalidate()
	}
	if a.logs != nil {
		a.logs.Invalidate()
	}
	a.saveSettings()
}

// setTheme switches the look of the window.
func (a *App) setTheme(choice themeChoice) {
	if a.settings.Theme == choice {
		return
	}
	a.settings.Theme = choice
	app.SetNativeAppearance(nativeAppearance(choice))
	a.theme, a.colors = look(choice)
	a.shared.dark.Store(a.colors.Dark)
	if a.settingsWindow != nil {
		a.settingsWindow.Invalidate()
	}
	if a.logs != nil {
		a.logs.Invalidate()
	}
	a.saveSettings()
}

func (a *App) saveSettings() {
	if err := a.store.Save(settingsFile, a.settings); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("settings_save", documentLogError(err)))
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
		if it.id == itemFind && a.chrome.isOpen(index) {
			a.searchView.focus = true
		}
	case it.id == itemTitleSettings:
		a.title.gearOpen = !a.title.gearOpen
		a.title.projectOpen = false
		a.closeBranches()
	case it.id == itemTitleRun:
		if a.project != nil {
			if !a.chrome.isOpen(catalogIndex[itemRun]) {
				a.reduceChrome(core.ToggleChrome(itemRun))
			}
			a.runSelectedBuildTask(a.project)
			return
		}
		a.notify(a.text.Title.RunLater)
	case it.id == itemRunConfig || it.id == itemTitleDebug:
		a.notify(a.text.Title.RunLater)
	case it.id == itemTitleSearch:
		if a.project != nil {
			a.performed("workspace.searchEverywhere.open", surfaceButton)
			a.openEverywhere(a.project)
		}
	case it.id == itemCaret:
		if a.project != nil {
			a.openNavigation(a.project)
		}
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
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_recent_reduce", documentLogError(err)))
		a.notify(a.text.Errors.Core(err.Error()))
		return
	}
	if save {
		if err := a.store.Save(recentFile, result.Entries); err != nil {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_recent_save", documentLogError(err)))
			a.notify(a.text.Errors.SaveFailed(err.Error()))
			return
		}
	}
	a.recent = result.Entries
	clear(a.missing)
	for _, entry := range a.recent {
		if info, err := os.Stat(entry.Path); err != nil || !info.IsDir() {
			a.missing[entry.Path] = true
		}
	}
	a.refreshWelcomeBranches()
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
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_open", documentLogError(err)))
		a.notify(a.text.Errors.OpenFailed(err.Error()))
		return
	}
	if info, err := os.Stat(root); err != nil || !info.IsDir() {
		if err == nil {
			err = errors.New("not a directory")
		}
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_open", documentLogError(err)))
		a.notify(a.text.Errors.FolderMissing(root))
		return
	}
	a.requestCloseProject(func() {
		a.reduceRecent(a.recent, core.RecordRecent(root, a.now()), true)
		ctx, cancel := context.WithCancel(context.Background())
		p := &project{root: root, name: filepath.Base(root), ctx: ctx, cancel: cancel, commit: newCommitState(), agent: newAgentState()}
		a.searchView.reset()
		a.openTerminals(p)
		a.project = p
		a.notice = ""
		a.logView.reset()
		a.loadGit(p)
		a.loadLog(p)
	})
}

// closeProject retains a dirty project if any save fails.
func (a *App) closeProject() { a.requestCloseProject(nil) }

// requestCloseProject waits for all document writes before destroying project resources.
func (a *App) requestCloseProject(after func()) {
	if a.closingProject {
		return
	}
	p := a.project
	if p == nil {
		if after != nil {
			after()
		}
		return
	}
	a.closingProject = true
	a.saveProjectDocuments(p, func(ok bool) {
		a.closingProject = false
		if !ok || a.project != p {
			return
		}
		a.closeEverywhere(p)
		if a.navigation.open && a.navigation.project == p {
			a.closeNavigation()
		}
		p.cancel()
		a.closeTree(p)
		a.releaseProjectSearch(p)
		a.closeDocuments(p)
		a.closeTerminals(p)
		// Build providers and prepared applications belong to the workspace and
		// are stopped before the project state is dropped.
		a.stopBuild(p)
		a.closeAgent(p)
		// A language server is bound to the workspace it was started for, so it goes
		// with the project rather than outliving it.
		a.stopAllPluginServers()
		a.clearAllPluginDiagnostics()
		a.problems.reset()
		a.project = nil
		a.cancelDrag()
		a.cancelTabDrag()
		a.title = titleState{}
		a.branch.branchSession = branchSession{}
		if after != nil {
			after()
		}
	})
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
func (s *statusState) frame(canvas *gfx.Canvas, now time.Time) {
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
