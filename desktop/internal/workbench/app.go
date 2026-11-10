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
	"sync"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildinfo"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logwindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugindiag"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/projectgen"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// Kernel is what the window asks the kernel. *core.Client implements it; tests replace
// the calls that read the disk or run Git, so a screen can be checked against answers the
// test chooses.
type Kernel interface {
	SelectPluginFunctionProvider(context.Context, string, string, string, string, []core.PluginFunctionProviderCandidate) (string, error)
	Version() string
	ReduceRecentProjects(ctx context.Context, entries []core.RecentProject, action core.RecentAction, capacity int) (core.RecentProjectsResult, error)
	GitCheckoutBranch(ctx context.Context, text string) (string, error)
	GitDirectoryPointer(ctx context.Context, text string) (string, error)
	ReduceChromeLayout(ctx context.Context, catalog []core.ChromeItem, state core.ChromeLayout, action core.ChromeAction) (core.ChromeLayout, bool, error)
	GitStatus(ctx context.Context, root string) (core.GitStatus, error)
	GitReferences(ctx context.Context, root string) (core.GitReferences, error)
	GitHistoryPage(ctx context.Context, root, reference, cursor string, limit int) (core.GitHistoryPage, error)
	DetectBuildSystems(ctx context.Context, workspaceRoot string, manifests []json.RawMessage) (core.BuildDetection, error)
	PlanBuildInvocation(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildInvocationRequest) (core.BuildInvocation, error)
	CheckBuildToolVersion(ctx context.Context, manifest json.RawMessage, buildSystemID, runtime, output string) (core.BuildToolVersion, error)
	PlanBuildModel(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildPlanRequest) (core.BuildPlan, error)
	PlanBuildTask(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildPlanRequest) (core.BuildPlan, error)
	PlanBuildTest(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildTestRequest) (core.BuildPlan, error)
	DecodeBuildTestResults(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildTestResultsRequest) (core.BuildTestResults, error)
	ResolveBuildTestOutcome(ctx context.Context, termination core.BuildTestTermination, project, suite, caseName string, summary *core.BuildTestSummary) (core.BuildTestVerdict, error)
	InstantiateToolchainLaunch(context.Context, json.RawMessage, string, string, string, string, []string, []string) (core.ToolchainLaunch, error)
	ReadPluginSettingsState(context.Context, json.RawMessage, *string, *string) (core.PluginSettingsState, error)
	EditPluginSettings(context.Context, json.RawMessage, string, *string, []core.PluginSettingEdit) (core.PluginSettingsEditPlan, error)
	PlanPluginDebugAdapter(context.Context, json.RawMessage, string, core.PluginBackendDirectories) (core.PluginBackendPlan, error)
	PlanDebugExecutable(context.Context, json.RawMessage, string, string, string, map[string]json.RawMessage, map[string]json.RawMessage) (*core.DebugExecutablePlan, error)
	PlanDebugStart(context.Context, json.RawMessage, string, string, core.DebugStartFacts) (core.DebugStart, error)
	DebugTransportPolicy(context.Context) (core.DebugTransportPolicy, error)
	MatchOutputLinks(context.Context, core.OutputLinkRequest) ([]core.OutputLink, error)
	CreateDebugSession(ctx context.Context, request core.DebugCreateSessionRequest) (core.DebugUpdate, error)
	LaunchDebug(ctx context.Context, sessionID, operationID string, configuration core.DebugLaunchConfiguration) (core.DebugUpdate, error)
	SetDebugBreakpoints(ctx context.Context, sessionID, sourcePath string, breakpoints []core.DebugSourceBreakpoint) (core.DebugUpdate, error)
	ExecuteDebug(ctx context.Context, sessionID, operationID, command string, threadID *int64) (core.DebugUpdate, error)
	InspectDebug(ctx context.Context, request core.DebugInspectRequest) (core.DebugUpdate, error)
	ReceiveDebug(ctx context.Context, sessionID string, data []byte) (core.DebugUpdate, error)
	DisconnectDebug(ctx context.Context, sessionID string) (core.DebugUpdate, error)
	DestroyDebugSession(ctx context.Context, sessionID string) ([]string, error)
	PlanBuildRun(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildPlanRequest) (core.BuildPlan, error)
	DecodeBuildModel(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildDecodeModelRequest) (core.BuildModel, error)
	DecodeBuildRun(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildDecodeRunRequest) (core.BuildLaunch, error)
	ToolchainRegistryOf(ctx context.Context, manifests []json.RawMessage) (core.ToolchainRegistry, error)
	ToolchainDiscoveryPlanOf(ctx context.Context, registry json.RawMessage, platform string) (core.ToolchainDiscoveryPlan, error)
	ToolchainCandidatesOf(ctx context.Context, request core.ToolchainCandidatesRequest) (core.ToolchainCandidates, error)
	ResolveToolchain(ctx context.Context, request core.ToolchainResolveRequest) (core.ToolchainResolution, error)
	ResolveToolchainPins(ctx context.Context, document json.RawMessage, directory, tool string) (core.ToolchainPinResolution, error)
	ToolchainPinStorage(ctx context.Context) (core.ToolchainPinStoragePlan, error)
	DecodeToolchainPinDocument(ctx context.Context, document *string) (json.RawMessage, error)
	EditToolchainPinSources(ctx context.Context, request core.ToolchainPinSourcesRequest) (core.ToolchainPinSourcesEdit, error)
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
	ProjectGeneratorCatalogOf(context.Context, []core.ProjectGeneratorPlugin) (core.ProjectGeneratorCatalog, error)
	ProjectGeneratorFormOf(context.Context, json.RawMessage, string, core.ProjectGeneratorFormInput) (core.ProjectGeneratorForm, error)
	ProjectGenerationPlanOf(context.Context, json.RawMessage, string, string, core.ProjectGeneratorFormInput) (core.ProjectGenerationPlan, error)
	ExtractProjectArchive(context.Context, string, string) (int, error)
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
	GitFetch(ctx context.Context, root string, options *core.GitFetchOptions) error
	GitPullPreflight(ctx context.Context, root string) (core.GitPullPreflight, error)
	GitFetchSettingsOf(ctx context.Context, root string) (core.GitFetchSettings, error)
	GitPull(ctx context.Context, root string, strategy core.GitPullStrategy) error
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
	ResolvePluginDocumentIdentity(ctx context.Context, root, input, platform string) (*core.PluginDocumentIdentity, error)
	ApplyPluginTextEdits(ctx context.Context, text string, edits []core.PluginTextEdit) (string, error)
	PlainPluginSnippet(ctx context.Context, value string) (string, error)
	PlanPluginWorkspaceEdit(ctx context.Context, workspaceRoot string, changes map[string][]core.PluginTextEdit, open []core.PluginOpenDocument) (core.PluginWorkspaceEditPlan, error)
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
	// EditorTabRows and EditorTabOverflow say how an editor group lays out tabs that do not
	// fit in one row, as settingswindow.Values does; see App.tabLayout.
	EditorTabRows     string `json:"editorTabRows,omitempty"`
	EditorTabOverflow string `json:"editorTabOverflow,omitempty"`
	// TerminalShell is the executable a new terminal runs, as settingswindow.Values says;
	// empty runs the user's default shell (localshell.DefaultShell).
	TerminalShell string `json:"terminalShell,omitempty"`
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
	// links are the output link matchers and the answers for the lines shown.
	links outputLinkState
	// tests is the Tests tool window's run and decoded result tree.
	tests testState
	// debug is the Debug tool window's adapter session, breakpoints and stack.
	debug debugState
	// panels are the pages of the Run, Tests and Debug tool windows.
	panels runPanels
	// agent is the project's Agent panel and connection.
	agent agentState
}

// App is the state of the window.
type App struct {
	// debugAttach are the host and port fields of the Debug panel's attach form.
	debugAttach debugAttachFields
	// root is the window's page; dnd are its drag and drop gestures and focus the control
	// that is to have the keyboard once it is on screen (see FocusBind).
	root  *ui.Page
	dnd   dragDrop
	focus focusTarget
	// debugHostedPort and debugInitializeWindow replace, in tests, asking the
	// language server for a debug port and Core's initialize deadline. Production
	// leaves both zero.
	debugHostedPort       func(ctx context.Context, p *project, adapter debugAdapter) (int, error)
	debugInitializeWindow time.Duration
	kernel                Kernel
	store                 *store.Store
	now                   func() time.Time
	invalidator           app.Invalidator
	tasks                 taskQueue
	// languages are the languages the editor knows, made when the first file is opened.
	languages *syntax.Registry

	settings       settings
	systemLanguage i18n.Language
	// text is the catalog of the current language; theme and colors are the look
	// of the frame being painted.
	text   *i18n.Messages
	theme  gfx.Theme
	colors palette

	// notice is the last message shown as a toast; notify sets it.
	notice string
	// overlay hosts the dialogs and the notice painted over the workbench.
	overlay overlayHost
	// settingsWindow opens the settings window and keeps at most one open.
	settingsWindow       *settingswindow.Controller
	settingsSubscription *settingsSubscription
	// plugins is the plugin stack, nil when the window was built without a plugin
	// kernel or without a writable plugin root.
	plugins *pluginservice.Service
	// prompts are the questions plugins ask the user, one sheet at a time.
	prompts pluginPrompts
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
	// agentClosing tracks Core sessions being closed off the window thread, so
	// shutdown waits for their process trees.
	agentClosing sync.WaitGroup
	// pluginServers are the language servers this window started, keyed by plugin.
	pluginServers map[string]*pluginServer
	// Native restart tokens prevent a late stop completion from restarting a
	// plugin that the user disabled or whose workspace has since closed.
	pluginServerRestarting map[string]*pluginServer
	pluginSettingsRestart  sync.Map
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
	// semantics is the editor's pending and presented language answers.
	semantics pluginSemantics

	welcome    welcomeState
	clone      cloneState
	newProject newProjectState
	// generatorPlugins, projectToolLists and projectCommand replace the plugin
	// service, the toolchain discovery and the PATH lookup the New Project window
	// uses; tests set them.
	generatorPlugins func(context.Context) ([]pluginservice.GeneratorPlugin, error)
	projectToolLists func(context.Context, []string) (map[string]toolList, error)
	projectCommand   func(context.Context, string) (projectgen.Command, error)
	// pendingOpen is what a generator asked to open once its project is open.
	pendingOpen pendingOpenFiles
	recent      []core.RecentProject
	// missing marks recent projects whose folder was gone when the list last changed.
	missing map[string]bool

	project *project
	// toolchainRoot is the open project's root, read by the settings window from
	// its own thread. Nil means no project is open.
	toolchainRoot atomic.Pointer[string]
	// toolchainResolve is the execution-side selector; tests replace it to keep
	// workspace file reads out of the window. Production leaves it nil.
	toolchainResolve func(ctx context.Context, root, directory, tool, minimumVersion string) (core.ToolchainSelection, error)
	closingProject   bool
	documentWriter   func(string, []byte, []byte) error
	documentCreator  func(string, []byte) error
	documentReader   func(string) ([]byte, error)
	chrome           *chromeState
	drag             dragState
	title            titleState
	layout           layoutState
	status           statusState
	logView          logView
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
	// listShells finds the installed shells for the new-terminal menu and the Terminal
	// settings page. It runs off the window thread; tests replace it.
	listShells func() []localshell.Choice
	// softWrap says the open files wrap their long lines at the width of their group instead
	// of scrolling sideways. The switch at the end of each group's strip of tabs turns it on
	// and off for every file at once; it lasts until the client quits.
	softWrap bool

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
		listShells:      localshell.InstalledShells,
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
	if err := service.AttachWorkbench(pluginWorkbench{app: a}); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_host_services", err))
	}
	a.wirePluginRuns()
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
	a.unsubscribeSettings()
	a.closeProject()
	a.wait()
	if a.plugins != nil && a.plugins.Runs != nil {
		// Runs of the closed project are already stopped; this ends any the
		// project close did not own and refuses new ones during shutdown.
		a.plugins.Runs.StopAll()
	}
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

// closed runs when the window has closed: the project closes, and so does the log window,
// which would otherwise keep the application running without the window it belongs to.
func (a *App) closed() {
	a.unsubscribeSettings()
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

// notify shows message in a toast.
func (a *App) notify(message string) {
	a.notice = message
	a.overlay.toaster.Show(message, "", ui.ToastWarning)
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
		rootCopy := root
		a.toolchainRoot.Store(&rootCopy)
		a.notice = ""
		a.logView.reset()
		a.loadGit(p)
		a.loadLog(p)
		a.activatePluginWorkspace(root)
		a.openPendingFiles(p)
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
		a.cancelPrompts()
		p.cancel()
		a.closeTree(p)
		a.releaseProjectSearch(p)
		a.closeDocuments(p)
		a.closeTerminals(p)
		// A test run owns a process or provider request, so it is stopped before
		// the build providers it borrowed close.
		a.stopTestsForProject(p)
		a.stopDebugForProject(p)
		a.stopRunsForProject(p)
		// Build providers and prepared applications belong to the workspace and
		// are stopped before the project state is dropped.
		a.stopBuild(p)
		a.closeAgent(p)
		// A language server is bound to the workspace it was started for, so it goes
		// with the project rather than outliving it.
		a.stopAllPluginServers()
		a.clearAllPluginDiagnostics()
		a.problems.reset()
		a.toolchainRoot.Store(nil)
		a.project = nil
		a.dnd.tool.Cancel()
		a.dnd.tab.Cancel()
		a.drag, a.term.drag = dragState{}, tabDrag{}
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
