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
	"github.com/1lck/Lithe-IDEA/desktop/internal/processledger"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/ai"
	"github.com/1lck/Lithe-IDEA/desktop/internal/buildinfo"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fontprefs"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logwindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugindiag"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/projectgen"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/wslpath"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// Kernel is what the window asks the kernel. *core.Client implements it; tests replace
// the calls that read the disk or run Git, so a screen can be checked against answers the
// test chooses.
type Kernel interface {
	ReadSourceSettings(context.Context, json.RawMessage) (core.SourceSettingsState, error)
	PlanSourceSettingsEdits(context.Context, core.SourceSettingsSnapshot, []core.SourceSettingsEdits, bool) ([]core.SourceSettingsWrite, error)
	DecodeSourceSettingsReceipt(context.Context, core.SourceSettingsWrite, json.RawMessage) (core.SourceSettingsReceipt, error)
	SelectPluginFunctionProvider(context.Context, string, string, string, string, []core.PluginFunctionProviderCandidate) (string, error)
	ReduceRecentProjects(ctx context.Context, entries []core.RecentProject, action core.RecentAction, capacity int) (core.RecentProjectsResult, error)
	GitCheckoutBranch(ctx context.Context, text string) (string, error)
	GitDirectoryPointer(ctx context.Context, text string) (string, error)
	ReduceChromeLayout(ctx context.Context, catalog []core.ChromeItem, state core.ChromeLayout, action core.ChromeAction) (core.ChromeLayout, bool, error)
	GitStatus(ctx context.Context, root string) (core.GitStatus, error)
	GitReferences(ctx context.Context, root string) (core.GitReferences, error)
	GitHistoryPage(ctx context.Context, root, reference, cursor string, limit, maxCommits int) (core.GitHistoryPage, error)
	DetectBuildSystems(ctx context.Context, workspaceRoot string, manifests []json.RawMessage) (core.BuildDetection, error)
	DetectBuildSystemsWithOptions(ctx context.Context, workspaceRoot string, manifests []json.RawMessage, options core.BuildDetectOptions) (core.BuildDetection, error)
	ResolveStoredBuildOptions(ctx context.Context, document, local json.RawMessage) (core.BuildStoredOptions, error)
	EditStoredBuildOption(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildOptionEditRequest) (core.BuildOptionEdit, error)
	EditBuildIgnoredPaths(ctx context.Context, request core.BuildIgnoredPathsEditRequest) (core.BuildIgnoredPathsEdit, error)
	IDEHostOpen(ctx context.Context, request core.IDEHostOpenRequest) (core.IDEHostOpenResult, error)
	IDEHostPoll(ctx context.Context, hostID string) (core.IDEHostPollResult, error)
	IDEHostClaim(ctx context.Context, hostID, requestID string) (core.IDEHostClaimResult, error)
	IDEHostRespond(ctx context.Context, hostID, requestID string, result any) (core.IDEHostRespondResult, error)
	IDEHostClose(ctx context.Context, hostID string) (core.IDEHostCloseResult, error)
	IDEHostValidate(ctx context.Context, name string, arguments any, permissions core.IDEPermissions, toolExposure []core.IDEToolExposure) (core.IDEHostValidateResult, error)
	IDEHostOutputPage(ctx context.Context, snapshot any, cursor string) (json.RawMessage, error)
	PlanBuildInvocation(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildInvocationRequest) (core.BuildInvocation, error)
	CheckBuildToolVersion(ctx context.Context, manifest json.RawMessage, buildSystemID, runtime, output string) (core.BuildToolVersion, error)
	PlanBuildModel(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildPlanRequest) (core.BuildPlan, error)
	PlanBuildTask(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildPlanRequest) (core.BuildPlan, error)
	PlanRunConfiguration(ctx context.Context, manifest json.RawMessage, buildSystemID, workspaceRoot string, request core.RunConfigurationPlanRequest) (core.BuildPlan, error)
	PlanBuildTest(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildTestRequest) (core.BuildPlan, error)
	DecodeBuildTestResults(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildTestResultsRequest) (core.BuildTestResults, error)
	ResolveBuildTestOutcome(ctx context.Context, termination core.BuildTestTermination, project, suite, caseName string, summary *core.BuildTestSummary) (core.BuildTestVerdict, error)
	InstantiateToolchainLaunch(context.Context, json.RawMessage, string, string, string, string, []string, []string) (core.ToolchainLaunch, error)
	ReadPluginSettingsState(context.Context, json.RawMessage, *string, *string, *core.PluginSettingsLocalizationRequest) (core.PluginSettingsState, error)
	EditPluginSettings(context.Context, json.RawMessage, string, *string, []core.PluginSettingEdit) (core.PluginSettingsEditPlan, error)
	PlanPluginDebugAdapter(context.Context, json.RawMessage, string, core.PluginBackendDirectories) (core.PluginBackendPlan, error)
	PlanDebugExecutable(context.Context, json.RawMessage, string, string, string, map[string]json.RawMessage, map[string]json.RawMessage) (*core.DebugExecutablePlan, error)
	PlanDebugStart(context.Context, json.RawMessage, string, string, core.DebugStartFacts, map[string]any) (core.DebugStart, error)
	DebugTransportPolicy(context.Context) (core.DebugTransportPolicy, error)
	ReadDebugAnnouncement(ctx context.Context, endpoint json.RawMessage, stream, line string) (core.DebugAnnouncement, error)
	debugTransportKernel
	debugStateKernel
	processExitKernel
	processMemoryKernel
	MatchOutputLinks(context.Context, core.OutputLinkRequest) ([]core.OutputLink, error)
	DecodeOutputStyle(ctx context.Context, text string, state json.RawMessage) (core.OutputStyleDecoding, error)
	CreateDebugSession(ctx context.Context, request core.DebugCreateSessionRequest) (core.DebugUpdate, error)
	LaunchDebug(ctx context.Context, sessionID, operationID string, configuration core.DebugLaunchConfiguration) (core.DebugUpdate, error)
	NormalizeSteppingFilters(ctx context.Context, adapterID string, filters core.DebugSteppingFilters) (core.DebugSteppingFilters, error)
	GenerateRunConfigurations(ctx context.Context, root string, providerRuns json.RawMessage) (core.RunConfigGeneration, error)
	ResolveRunConfigurations(ctx context.Context, root string, plugins []core.RunInstalledPlugin) (core.RunConfigResolution, error)
	DecideTitleAction(ctx context.Context, facts core.TitleActionFacts) (string, error)
	ProviderLaunchInputs(ctx context.Context, root, configurationID, providerRoot string) (core.RunProviderLaunchInputs, error)
	UpdateRunConfigurationOptions(ctx context.Context, edit core.RunOptionsEdit) ([]core.RunConfigChange, error)
	// RunConfigurationTypes, RunEditorForm, SaveRunConfiguration, DeleteRunConfiguration and
	// CreateRunLaunchPlan create, edit and start the built-in process runs (runconfig_process.go).
	RunConfigurationTypes(ctx context.Context, plugins *core.RunTypePlugins) ([]core.RunConfigurationType, []core.RunTypeLocalization, error)
	RunEditorForm(ctx context.Context, request core.RunEditorFormRequest) (core.RunEditorForm, error)
	SaveRunConfiguration(ctx context.Context, request core.RunConfigurationSave) (core.RunConfigurationSaved, error)
	DeleteRunConfiguration(ctx context.Context, root, configurationID string, plugins []core.RunInstalledPlugin) ([]core.RunConfigChange, error)
	CreateRunLaunchPlan(ctx context.Context, root, configurationID, inlineScriptBase string) (core.RunLaunchPlan, error)
	// CopyRunConfiguration and ArrangeRunConfigurations copy any configuration and save the
	// folders and order of the list (runconfig_dialog.go).
	CopyRunConfiguration(ctx context.Context, root, configurationID, name string, plugins []core.RunInstalledPlugin) (string, []core.RunConfigChange, error)
	ArrangeRunConfigurations(ctx context.Context, request core.RunConfigArrangement) ([]core.RunConfigChange, error)
	// RunBeforeLaunch expands the steps a configuration runs before it starts (runconfig_before_launch.go).
	RunBeforeLaunch(ctx context.Context, root, configurationID string) (core.RunBeforeLaunch, error)
	RunArgumentText(ctx context.Context, lists [][]string) ([]string, error)
	SetDebugBreakpoints(ctx context.Context, sessionID, sourcePath string, breakpoints []core.DebugSourceBreakpoint) (core.DebugUpdate, error)
	ExecuteDebug(ctx context.Context, sessionID, operationID, command string, threadID *int64, granularity string) (core.DebugUpdate, error)
	ExecuteDebugThread(ctx context.Context, sessionID, operationID, command string, threadID int64) (core.DebugUpdate, error)
	InspectDebug(ctx context.Context, request core.DebugInspectRequest) (core.DebugUpdate, error)
	ReceiveDebug(ctx context.Context, sessionID string, data []byte) (core.DebugUpdate, error)
	DisconnectDebug(ctx context.Context, sessionID string) (core.DebugUpdate, error)
	DestroyDebugSession(ctx context.Context, sessionID string) ([]string, error)
	PlanBuildRun(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildPlanRequest) (core.BuildPlan, error)
	// PlanBuildDebug plans the native debug program a provider owns for one target, and
	// DecodeBuildDebug validates the answer into the preparation the run's declared adapter
	// starts: the adapter's local ID and workspace-relative program, arguments and directory.
	PlanBuildDebug(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildPlanRequest) (core.BuildPlan, error)
	DecodeBuildDebug(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildDecodeDebugRequest) (core.BuildDebugPreparation, error)
	DecodeBuildModel(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildDecodeModelRequest) (core.BuildModel, error)
	// BuildModelTree lays out a loaded model as the Build tool window's tree (build_tree.go).
	BuildModelTree(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildModelTreeRequest) (core.BuildModelTree, error)
	DecodeBuildRun(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildDecodeRunRequest) (core.BuildLaunch, error)
	// PlanBuildRunEntrypoints, DecodeBuildRunEntrypoints and CreateRunEntrypointConfiguration
	// run the entrypoint the current file holds (title_run_entrypoints.go).
	PlanBuildRunEntrypoints(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildPlanRequest) (core.BuildPlan, error)
	DecodeBuildRunEntrypoints(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildDecodeRunEntrypointsRequest) ([]core.BuildRunEntrypoint, error)
	CreateRunEntrypointConfiguration(ctx context.Context, request core.RunEntrypointConfigurationRequest) (string, []core.RunConfigChange, error)
	ToolchainRegistryOf(ctx context.Context, manifests []json.RawMessage) (core.ToolchainRegistry, error)
	// CommandInstallerRequirements, PlanCommandInstaller and CommandInstallerDefaultDirectory
	// read a plugin's commandInstallers[]: which systemCommand launches name which commands,
	// one installer expanded for the target the user chose, and the directory a toolDefault
	// installation lands in from its probes' output (command_installers.go).
	CommandInstallerRequirements(ctx context.Context, manifest json.RawMessage) (core.CommandRequirements, error)
	PlanCommandInstaller(ctx context.Context, manifest json.RawMessage, installerID, target, installDirectory string) (core.CommandInstallPlan, error)
	CommandInstallerDefaultDirectory(ctx context.Context, manifest json.RawMessage, installerID string, outputs []*string) (string, bool, error)
	ToolchainDiscoveryPlanOf(ctx context.Context, registry json.RawMessage, platform string) (core.ToolchainDiscoveryPlan, error)
	ToolchainCandidatesOf(ctx context.Context, request core.ToolchainCandidatesRequest) (core.ToolchainCandidates, error)
	ResolveToolchain(ctx context.Context, request core.ToolchainResolveRequest) (core.ToolchainResolution, error)
	ResolveToolchainPins(ctx context.Context, document json.RawMessage, directory, tool string) (core.ToolchainPinResolution, error)
	EditToolchainPins(ctx context.Context, document json.RawMessage, directory string, edits []core.ToolchainPinEdit) (json.RawMessage, error)
	ToolchainPinStorage(ctx context.Context) (core.ToolchainPinStoragePlan, error)
	DecodeToolchainPinDocument(ctx context.Context, document *string) (json.RawMessage, error)
	EditToolchainPinSources(ctx context.Context, request core.ToolchainPinSourcesRequest) (core.ToolchainPinSourcesEdit, error)
	CloseGitHistoryCursor(ctx context.Context, root, cursor string) (bool, error)
	GitCommitFiles(ctx context.Context, root, commit string) ([]core.GitCommitFile, error)
	GitCommit(ctx context.Context, root, commit string) (core.GitCommitDetail, error)
	GitGraph(ctx context.Context, request core.GraphRequest) (core.Graph, error)
	GitReferenceTree(ctx context.Context, names []string, prioritized map[string]bool) ([]core.ReferenceTreeNode, error)
	GitChangedFileGroups(ctx context.Context, paths []string) ([]core.GitChangedFolder, error)
	GitHistoryDates(ctx context.Context, entries []core.HistoryDateEntry, after, before *int64) ([]string, error)
	ReduceEditorLayout(ctx context.Context, state core.EditorWorkbench, layout *core.EditorLayout, action core.EditorAction) (core.EditorLayoutResult, error)
	EditorDropTargets(ctx context.Context, query core.EditorDropQuery) (core.EditorDropRules, error)
	ReduceRowSelection(ctx context.Context, rows []string, selection core.RowSelection, action core.RowAction) (core.RowSelectionResult, error)
	ProjectTreeRows(ctx context.Context, query core.ProjectTreeQuery) (core.ProjectTreeRows, error)
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
	GitCreateTag(ctx context.Context, root, name, revision, message string) error
	GitRebasePreview(ctx context.Context, root, base string) (core.RebasePreview, error)
	GitRebaseStart(ctx context.Context, root string, preview core.RebasePreview, steps []core.RebaseStep) (*core.RebaseSession, error)
	GitRebaseSession(ctx context.Context, root string) (*core.RebaseSession, error)
	GitRebaseControl(ctx context.Context, root string, session core.RebaseSession, action, amendMessage, expectedHead string) (*core.RebaseSession, error)
	GitDeleteTag(ctx context.Context, root, name string) error
	GitBranchNamePreview(ctx context.Context, request core.BranchNameRequest) (core.BranchNamePreview, error)
	GitWorktrees(ctx context.Context, root string) ([]core.GitWorktree, error)
	GitWorktreesWithChanges(ctx context.Context, root string) ([]core.GitWorktree, error)
	GitWorktreeCreationPreview(ctx context.Context, input core.GitWorktreeCreationInput) (core.GitWorktreeCreationPreview, error)
	GitCreateWorktree(ctx context.Context, root string, creation core.GitWorktreeCreation) error
	GitRemoveWorktree(ctx context.Context, root, path string, force bool) error
	GitLockWorktree(ctx context.Context, root, path string) error
	GitUnlockWorktree(ctx context.Context, root, path string) error
	GitPruneWorktrees(ctx context.Context, root string) error
	GitRepairWorktrees(ctx context.Context, root string) error
	GitConsolePresentation(ctx context.Context, records []core.GitConsoleRecord, search string, display core.GitConsoleDisplay) (core.GitConsolePresentation, error)
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
	QueryReferences(ctx context.Context, request core.ReferencesQuery) (core.ReferencesResult, error)
	ReferenceLines(ctx context.Context, request core.ReferenceLinesRequest) ([]core.ReferenceLine, error)
	ResolveMarketplaceSource(context.Context, string) (core.MarketplaceSource, error)
	ValidateMarketplaceIndex(context.Context, json.RawMessage, core.MarketplaceSourceKind, string, map[string][]int) (core.MarketplaceIndex, error)
}

// Options configure a window.
type Options struct {
	Kernel Kernel
	// Store is where settings, recent projects and the layout are kept.
	Store *store.Store
	// OpenPath is a project folder the window opens when it starts; a window launched to show a
	// worktree in a new window gets it from the command line.
	OpenPath string
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
	// AIKernel runs AI generation (the ai package): the commit message, the inline edit and
	// the pull request description, with the providers of the user's Codex and Claude
	// configuration. nil leaves AI generation unavailable instead of refusing to start.
	AIKernel ai.Kernel
	// PluginInitializeTimeout bounds every plugin backend's startup handshake.
	// Zero keeps Core's default. Host tests whose fixture is a copy of the large
	// instrumented test binary raise it so scheduler load cannot masquerade as
	// a provider failure.
	PluginInitializeTimeout time.Duration
	// first is the window's first workbench when this one is another project tab of its
	// window; nil for the first (window_sessions.go).
	first *App
}

// LogSink is the client's log as the window uses it: the log window reads it and the
// window records what the user does to a project. *logstore.Store implements it.
type LogSink interface {
	logwindow.Source
	Emit(level core.LogLevel, event, op string, fields map[string]any)
}

// pluginFileSink is the part of the client's log that gives a plugin process the directory
// it writes its own files to. *logstore.Store implements it; a sink without it gives none.
type pluginFileSink interface {
	PluginFilesDirectory(ctx context.Context, pluginID string) (string, error)
}

// diagnosticsWatchSink is the part of the client's log that tells when detailed diagnostics
// turn on and off, so the upstream trace of plugin sessions follows the same switch.
// *logstore.Store implements it; with a sink without it the trace stays off.
type diagnosticsWatchSink interface {
	WatchDiagnostics(watch func(on bool)) (stop func())
}

// panicSink is the part of the client's log that records a panic recovered on any thread,
// without taking a lock. *logstore.Store implements it; with a sink without it the panics Viva
// recovers in its callbacks are not logged.
type panicSink interface {
	RecordPanic(boundary, value string, stack []byte)
}

// logsShortcut opens the log window, as on macOS.
const logsShortcut = "⇧⌘L"

// settings are the user's choices, kept in settingsFile.
type settings struct {
	EditorPreferences core.EditorStoredPreferences `json:"editorPreferences,omitzero"`
	KeymapSchemes     core.KeymapSchemes           `json:"keymapSchemes,omitzero"`
	// Language is a stored i18n code; empty follows the system.
	Language         string      `json:"language,omitempty"`
	Theme            themeChoice `json:"theme,omitempty"`
	MarketplaceWidth float32     `json:"marketplaceWidth,omitempty"`
	// MarketplaceSources are the custom plugin index URLs the user added, in the order they were added.
	MarketplaceSources []string `json:"marketplaceSources,omitempty"`
	// HideMinimap hides the minimap of every editor; the editors show it by default.
	HideMinimap bool `json:"hideMinimap,omitempty"`
	// HideGitGutter hides the Git change markers of the editor gutter; they show by default.
	HideGitGutter bool `json:"hideGitGutter,omitempty"`
	// HideProjectColors leaves the open project's color out of the window's chrome; it
	// shows by default (project_gradient.go).
	HideProjectColors bool `json:"hideProjectColors,omitempty"`
	// InlineGitBlame shows the blame of the caret line after its text; off by default.
	InlineGitBlame bool `json:"inlineGitBlame,omitempty"`
	// HideChangeLists lists the Commit window's changes flat, without the local ChangeLists; the
	// lists and their assignments are kept. They show by default (changelists_settings.go).
	HideChangeLists bool `json:"hideChangeLists,omitempty"`
	// HideParentReferences hides the option that records submodule commits in the parent
	// repositories; while it is hidden every commit updates them. The option shows by default.
	HideParentReferences bool `json:"hideParentReferences,omitempty"`
	// GitLogLimit and GitLogMergedLimit are the most commits the Git Log reads of one repository
	// and of several at once; zero is settingswindow.DefaultGitLogLimit and
	// DefaultGitLogMergedLimit (gitlog_limits.go).
	GitLogLimit       int `json:"gitLogLimit,omitempty"`
	GitLogMergedLimit int `json:"gitLogMergedLimit,omitempty"`
	// GitConsole says which internal Git queries the Git console records and how it draws its
	// records; the zero value is IntelliJ IDEA's console (gitconsole_settings.go).
	GitConsole core.GitConsolePreferences `json:"gitConsole,omitzero"`
	// DisableSemanticHighlight keeps the syntax colors alone; semantic coloring is on by default.
	DisableSemanticHighlight bool `json:"disableSemanticHighlight,omitempty"`
	// VimMode turns on the Vim keys of every editor; off by default (vim_mode.go).
	VimMode bool `json:"vimMode,omitempty"`
	// DisableAutoSave stops saving changed files a moment after typing stops
	// (document_autosave.go); auto-save is on by default.
	DisableAutoSave bool `json:"disableAutoSave,omitempty"`
	// EditorTabRows and EditorTabOverflow say how an editor group lays out tabs that do not
	// fit in one row, as settingswindow.Values does; see App.tabLayout.
	EditorTabRows     string `json:"editorTabRows,omitempty"`
	EditorTabOverflow string `json:"editorTabOverflow,omitempty"`
	// EditorTabLimit is the most file tabs open at once; nil is the default and 0 no limit.
	// EditorTabPolicy is which tab the limit closes (settingswindow.TabPolicyOldest or the
	// least recently used). See tab_limit.go.
	EditorTabLimit  *int   `json:"editorTabLimit,omitempty"`
	EditorTabPolicy string `json:"editorTabPolicy,omitempty"`
	// TerminalShell is the executable a new terminal runs, as settingswindow.Values says;
	// empty runs the user's default shell (localshell.DefaultShell).
	TerminalShell string `json:"terminalShell,omitempty"`
	// TerminalScrollback is the history lines a new terminal keeps; zero is
	// settingswindow.DefaultScrollback.
	TerminalScrollback int `json:"terminalScrollback,omitempty"`
	// TerminalCursorShape and TerminalCursorThickness are the terminal cursor the
	// Terminal page chose, as settingswindow.Values holds them; empty is the block of
	// normal thickness. See terminalCursor.
	TerminalCursorShape     string `json:"terminalCursorShape,omitempty"`
	TerminalCursorThickness string `json:"terminalCursorThickness,omitempty"`
	// TerminalBehavior is the Terminal page's switches; the zero value is the default of each.
	// See terminalOptions.
	TerminalBehavior settingswindow.TerminalBehavior `json:"terminalBehavior,omitzero"`
	// ProcessTermination is the user's part of Core's process termination settings, as the
	// Process Termination page edits it; the zero value keeps Core's defaults.
	ProcessTermination settingswindow.ProcessTermination `json:"processTermination,omitzero"`
	// DebugSteppingFilters are the user's stepping policies by debug adapter ID, as Core
	// normalized them; an adapter without one uses its plugin's declared defaults.
	DebugSteppingFilters map[string]core.DebugSteppingFilters `json:"debugSteppingFilters,omitempty"`
	// AIGeneration is the provider and output choice of commit message generation and inline
	// edits (ai_generation.go). It is Lithe's own preference, not the Codex or Claude configuration.
	AIGeneration settingswindow.AIGenerationSettings `json:"aiGeneration,omitempty"`
	// Fonts are the fonts of the editor, the terminal and the run output (fonts.go); none
	// is fontprefs.Default.
	Fonts []fontprefs.Font `json:"fonts,omitempty"`
	// Keymap is the user's changes to the keys of the shortcut catalog (shortcuts.Catalog),
	// by action ID; none keeps every default.
	Keymap shortcuts.Overrides `json:"keymap,omitempty"`
	// ProjectOpenDestination is where a project opened while another is open goes:
	// settingswindow.ProjectOpenThisWindow, ProjectOpenNewWindow, or empty to ask
	// (project_open_destination.go).
	ProjectOpenDestination string `json:"projectOpenDestination,omitempty"`
	// UpdatesManual turns off the automatic update check, which otherwise runs shortly
	// after launch and then hourly; UpdatesCheckedAt is the last check that read the feed.
	// Both are the window's (updater.store, updates.go).
	UpdatesManual    bool      `json:"updatesManual,omitempty"`
	UpdatesCheckedAt time.Time `json:"updatesCheckedAt,omitzero"`
	// UpdateChannel is the channel the user chose to update from when it is not the one the
	// build was packaged for; empty follows the build. UpdateSources are the feeds the user set
	// in place of a channel's default, and UpdateSkipped the version the user skipped, both by
	// channel. UpdateReturnNow and UpdateRestore are what the user chose with UpdateChannel:
	// stable's latest release at once on the way back from AutoBuild rather than the first one
	// past the build, and the settings kept when Lithe last left the channel brought back once
	// its release is installed. All are the window's (updater.store, updates.go).
	UpdateChannel   string            `json:"updateChannel,omitempty"`
	UpdateReturnNow bool              `json:"updateReturnNow,omitempty"`
	UpdateRestore   bool              `json:"updateRestore,omitempty"`
	UpdateSources   map[string]string `json:"updateSources,omitempty"`
	UpdateSkipped   map[string]string `json:"updateSkipped,omitempty"`
	// Network is the proxy settings of the application's own HTTP traffic (network.go).
	Network settingswindow.NetworkSettings `json:"network,omitzero"`
	// LocalHistory is which files local history leaves out and how much of it a project keeps
	// (local_history_settings.go).
	LocalHistory settingswindow.LocalHistorySettings `json:"localHistory,omitzero"`
	// WorkbenchBackground is the image chosen to show behind the workbench and how much of it
	// shows; the image itself is a copy in the data folder (workbench_background.go).
	WorkbenchBackground savedBackground `json:"workbenchBackground,omitzero"`
	// UnknownSettingsNoticed names the set of settings this version could not read that the
	// first window last told about, so the same set is told once (settings_kept.go).
	UnknownSettingsNoticed string `json:"unknownSettingsNoticed,omitempty"`
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
	// indexing is the search exclusion policy the project installed in Core (directory_exclusions.go).
	indexing projectIndexing
	// name is the folder's name, shown in the title bar.
	name string
	// ctx ends when the project closes, which stops its kernel calls.
	ctx    context.Context
	cancel context.CancelFunc
	git    gitState
	// gitStatusGeneration orders status reads, including reads begun after background writes.
	gitStatusGeneration atomic.Uint64
	log                 gitLogState
	commit              commitState
	// lists are the repository's local ChangeLists and the list each change belongs to.
	lists changeListState
	// worktrees is the Git tool window's Worktrees tab: the repository's worktrees and the
	// details of the selected one.
	worktrees worktreeState
	// terms are the project's terminals and where each one is placed: in the Terminal tool
	// window or in a group of the editor area. A terminal's shell starts when it is first
	// painted, and every shell ends when the project closes.
	terms terminalSet
	// docs are the project's open files. Each is a tab in a group of the editor area, next
	// to the terminals that were moved there.
	docs   documentSet
	search projectSearch
	// replace is Replace in Files: its preview and its application (search_replace.go).
	replace    projectReplace
	history    localHistoryState
	everywhere everywhereSearch
	// everywhereSymbols is the workspace/symbol query the language servers answer (search_everywhere_lsp.go).
	everywhereSymbols everywhereSymbolState
	// tree is the Project tool window's tree of the project folder.
	tree fileTree
	// nativePanels is the view state of each native plugin panel the project shows, by window, and
	// nativeSaved what the project kept for them when it last closed (plugin_native.go, plugin_native_state.go).
	nativePanels map[string]*nativePanelState
	nativeSaved  map[string]savedNativePanel
	// build is the Run tool window's provider-backed instances and output.
	build buildState
	// buildSessions are the build provider sessions the project started. They live beside build
	// rather than in it, so dropping the detected instances never overwrites sessions a background
	// task still holds or is closing.
	buildSessions buildRuntime
	// vcs is the state of the windows of the plugin version control providers (vcs.go).
	vcs vcsState
	// runConfigs are the run configurations Core resolved for the workspace.
	runConfigs runConfigState
	// links are the output link matchers and the answers for the lines shown.
	links outputLinkState
	// tests is the Tests tool window's run and decoded result tree.
	tests testState
	// debug is the Debug tool window's adapter session, breakpoints and stack.
	debug debugState
	// panels are the pages of the Run, Tests and Debug tool windows.
	panels runPanels
	// review holds the Git review dialogs: Push, stashes, worktrees and annotations.
	review gitReview
	// blame is the commit subjects the inline blame annotations show, kept per project.
	blame gitBlameSubjects
	// observe is the watch of the repository's Git metadata (see git_observation.go).
	observe gitObservation
	// ideAPI is the project's IDE API connection for plugins and MCP clients (ide_api.go).
	ideAPI ideAPIState
	// diffs are the Diff tabs of the editor area.
	diffs diffSet
	// viewers are the project's viewer tabs (viewer.go).
	viewers viewerSet
	// stash is the Commit tool window's Stash tab: the repository's stashes and the files of
	// the selected one.
	stash stashState
	// shelf is the Commit tool window's Shelf tab: the shelves Lithe keeps of the repository
	// and the files of the selected one (shelf.go).
	shelf shelfState
	// lineHistory is the editor's line history dialog (gitlinehistory.go).
	lineHistory lineHistoryState
	// nested is the repositories nested in the project folder (nested_repos.go).
	nested nestedState
	// rebase is the Rebase from Here dialog and the rebase session of the repository (git_rebase.go).
	rebase rebaseState
	// gitHistory is the history actions of the log's commit menu and the merge, cherry-pick or
	// revert Git holds active (git_history.go).
	gitHistory historyState
}

// App is the state of the window.
type App struct {
	chooseScratchPath func(string, string) (string, error)
	// chooseBackgroundImage replaces the system's file picker for the workbench background in
	// tests; nil is the system's.
	chooseBackgroundImage func(app.OpenFileOptions) ([]string, error)
	recovery              *recoveryWriter
	recentFiles           recentFileState
	drafts                draftListState
	editorPreferences     core.EditorPreferences
	// clipboardImage and pasteDirectory replace, in tests, reading the clipboard's picture
	// and the cache folder a picture pasted into a terminal is saved in
	// (terminal_paste_image.go); nil is the system's.
	clipboardImage func() ([]byte, error)
	pasteDirectory func() (string, error)
	// debugAttach are the host and port fields of the Debug panel's attach form.
	debugAttach debugAttachFields
	// root is the window's page; dnd are its drag and drop gestures and focus the control
	// that is to have the keyboard once it is on screen (see FocusBind).
	root *ui.Page
	dnd  dragDrop
	// treeApps is the Open With submenu of a Project tree row (filetree_openin.go).
	treeApps treeApps
	// editorFocus is the document whose editor had the keyboard last frame; the file is
	// saved when the keyboard leaves it (document_autosave.go).
	editorFocus int
	// statusPath is the navigation path at the leading end of the status bar (status_path.go).
	statusPath statusPath
	// github is the GitHub account and its sign-in (github_account.go).
	github githubAccount
	// pullRequests is the pull-request panel of the Git log (github_prs.go).
	pullRequests pullRequestState
	// prCreate is the create-pull-request dialog (github_create.go).
	prCreate prCreateState
	// savedBackground is the window background last stored (window_background.go).
	savedBackground gfx.Color
	focus           focusTarget
	// debugHostedPort and debugInitializeWindow replace, in tests, asking the
	// language server for a debug port and Core's initialize deadline. Production
	// leaves both zero.
	debugHostedPort       func(ctx context.Context, p *project, adapter debugAdapter) (int, error)
	debugInitializeWindow time.Duration
	kernel                Kernel
	store                 *store.Store
	// startupPath is the project folder the window opens once it exists (Options.OpenPath).
	startupPath string
	now         func() time.Time
	// invalidator asks the window for a repaint. Every workbench of the window shares the one
	// the window was opened with (window_sessions.go).
	invalidator windowWake
	// sessions are the workbenches of the window, one for each project tab.
	sessions *windowSessions
	// window is the workbench's native window once it is open; fullscreen is whether it
	// fills its monitor, as the host last reported.
	window     *app.Window
	fullscreen bool
	// windowInactive is set while another window holds the keyboard, which greys the
	// selection of every list (theme.go applySelectionFocus).
	windowInactive bool
	// memory is the memory monitor's last reading (memory_monitor.go).
	memory memoryState
	// backdrop is the window's background image, shared by its project tabs, and backdropOpen
	// is whether this workbench's stripe shows its popover (workbench_background.go).
	backdrop     *workbenchBackground
	backdropOpen bool
	// hiddenListOpen is whether the "…" button shows the list of the hidden stripe buttons
	// (chrome_view.go hiddenToolWindowsButton).
	hiddenListOpen bool
	// shownTitle is the system title last given to the window (window_title.go).
	shownTitle string
	// updates is the update check, download and install, which every tab of the window
	// shares (updates.go).
	updates *updater
	tasks   taskQueue
	// languages are the languages the editor knows, made when the first file is opened.
	languages *syntax.Registry

	settings settings
	// fonts is the font of each scope the settings name, worked out by applyFonts.
	fonts          appFonts
	systemLanguage i18n.Language
	// text is the catalog of the current language; theme and colors are the look
	// of the frame being painted.
	text   *i18n.Messages
	theme  gfx.Theme
	colors palette

	// notice is the last message shown as a toast; notify sets it.
	notice string
	// notifications is the history of the notices, which the status bar's bell opens.
	notifications notificationCenter
	// overlay hosts the dialogs and the notice painted over the workbench.
	overlay overlayHost
	// instructions is the commit options' draft of the generation instructions
	// (ai_generation.go).
	instructions aiInstructionsDraft
	// settingsWindow opens the settings window and keeps at most one open.
	settingsWindow *settingswindow.Controller
	// pluginCommands are the ui.commands of the enabled plugins, which the command palette offers
	// (plugintools.go). Only the window thread reads or writes them.
	pluginCommands []pluginservice.ToolCommand
	// startupSweep is the start-up question about processes an earlier run left behind (startup_sweep.go).
	startupSweep startupSweepState
	// stopGraceRequest numbers the requests for Core's stop time, so only the latest is applied.
	stopGraceRequest int
	// stopTime is Core's rule for the stop time once it was read (refreshStopGrace); the
	// settings window reads it from its own thread.
	stopTime atomic.Pointer[settingswindow.StopTime]

	settingsSubscription *settingsSubscription
	// plugins is the plugin stack, nil when the window was built without a plugin
	// kernel or without a writable plugin root.
	plugins *pluginservice.Service
	// pluginDownloads holds native temporary file leases for the open settings window.
	pluginDownloads *marketplace.ArchiveSession
	// prompts are the questions plugins ask the user, one sheet at a time.
	prompts pluginPrompts
	// web opens the pages of plugin web tool windows; webReady is set once it can.
	web      app.WebHost
	webReady bool
	// pluginPages are the open pages of web tool windows by chrome identifier.
	pluginPages map[string]*pluginPage
	// previews are the web pages of the editor area: Markdown pages and file viewers.
	previews previewPages
	// checker is the checkerboard the native image viewers draw images over (viewer_image.go).
	checker checker
	// credentialImport is the import of an earlier client's plugin secrets the user asked
	// for from the settings menu (credentials_import.go).
	credentialImport credentialImportState
	// legacyImport is the import of an earlier client's preferences and recent projects.
	legacyImport legacyImportState
	// pluginState is what the settings window reads from its own thread about
	// installed plugins; it is replaced whole, never mutated in place.
	pluginState atomic.Pointer[map[string]settingswindow.PluginState]
	// pluginFacts is what the Installed tab shows about each installed plugin, in name order,
	// read from disk off the window thread.
	pluginFacts atomic.Pointer[[]settingswindow.PluginFacts]
	// pluginServerMu guards the language-server maps because a build provider
	// may attach to a shared session from a background model load.
	pluginServerMu sync.Mutex
	// aiKernel runs AI generation (ai_generation.go), nil when the window was built without one.
	aiKernel ai.Kernel
	// inline is the editor's AI inline edit dialog (inlineedit.go).
	inline inlineEditState
	// ideAPIBridgeState lets the IDE Connection settings page reach the open project (settings_ide_api.go).
	ideAPIBridgeState ideAPIBridge
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
	// pluginServerFailed keeps the latest failed language server per language in
	// the open project so the status bar and menu show the failure and allow retry.
	pluginServerFailed map[string]*failedPluginServer
	// pluginServerNotifiedErrors tracks the last error message notified per
	// language in the current project so repeated opens do not spam duplicate toasts.
	pluginServerNotifiedErrors map[string]string
	// pluginDiagnostics holds what each running language server published for
	// the files of the open project, keyed by plugin so stopping one server
	// withdraws only its own diagnostics.
	pluginDiagnostics map[string]*plugindiag.Set
	// semantics is the editor's pending and presented language answers.
	semantics   pluginSemantics
	contentOpen *contentOpenRequest
	// editor holds the state of the editor features that are not part of the language
	// semantics: back/forward history, the outline, references and so on (editor_features.go).
	editor editorFeatures

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
	// documentLinkedWriter writes a hard-linked file the way the user chose for one save.
	documentLinkedWriter func(string, []byte, []byte, *documentio.HardLinkConsent) error
	documentCreator      func(string, []byte) error
	documentReader       func(string) ([]byte, error)
	chrome               *chromeState
	drag                 dragState
	title                titleState
	layout               layoutState
	logView              logView
	// branch is the title bar's branch popup and the dialogs it opens.
	branch branchState
	// commitView is the Commit tool window's splitter and message input.
	commitView commitView
	// reviewMenu is the state of the Git tools menu in the Git tool window.
	reviewMenu reviewMenuState
	// worktreeView is the page of the Git tool window's Worktrees tab.
	worktreeView worktreeView
	// gitConsole keeps the Git commands every project of the window ran, for the Git tool
	// window's Console tab; consoleView is that tab's page.
	gitConsole     *core.GitConsole
	consoleView    consoleView
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
	// runWrap says the Run window's consoles break their long lines onto more rows instead of
	// ending them in an ellipsis. The switch in the console's toolbar turns it on and off for
	// every execution at once, as the Git console's does for that console; it lasts until the
	// client quits.
	runWrap bool

	// application is the running application the log window opens in; it is nil until
	// Run has started it.
	application *app.Application
	// logSink is the client's log and logs the controller of its window; both are nil
	// when the window was made without a log.
	logSink LogSink
	logs    *logwindow.Controller
	// unwatchDiagnostics stops the detailed-diagnostics switch reaching this workbench's plugin
	// sessions; it is nil when nothing watches it.
	unwatchDiagnostics func()
	// logWindowOpen replaces how the log window opens, for tests, which have no application.
	logWindowOpen func(op string) error
	// op is the user action the window thread is running (operation.go); only the window
	// thread reads or sets it.
	op operation
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
		kernel:               options.Kernel,
		documentWriter:       documentio.WriteGuarded,
		documentLinkedWriter: documentio.WriteGuardedLinked,
		documentCreator:      documentio.WriteMissing,
		documentReader:       readDocument,
		store:                options.Store,
		startupPath:          options.OpenPath,
		now:                  now,
		systemLanguage:       i18n.Detect(languages),
		chrome:               newChromeState(),
		layout:               newLayoutState(),
		missing:              map[string]bool{},
		logView:              newLogView(),
		commitView:           newCommitView(),
		delays:               defaultLogDelays,
		aiKernel:             options.AIKernel,
		listShells:           localshell.InstalledShells,
	}
	a.gitConsole = core.NewGitConsole(a.gitConsoleChanged)
	// The settings are read before the log sink is in place; a failure is recorded below, once
	// it is. The first window first restores the settings an update to another channel asked
	// to bring back (update_snapshots.go).
	var restoreErr error
	if options.first == nil {
		_, restoreErr = restorePendingSettings(a.store, buildinfo.InstalledChannel(), options.Version)
	}
	_, settingsErr := a.store.Load(settingsFile, &a.settings)
	if settingsErr != nil {
		a.settings = settings{}
	}
	// A value of a shape this version cannot take leaves only its own setting on the default;
	// the rest loaded. It is logged below with the failures, and the notice tells it is kept.
	settingsUnread := a.store.Unread(settingsFile)
	a.settings.Keymap = shortcuts.Normalize(a.settings.Keymap)
	a.gitConsole.RecordQueries(a.settings.GitConsole.QueryCategories())
	a.loadEditorEssentials()
	a.initRecovery()
	a.applyNetwork()
	bundledInterfaceFamily()
	a.applyFonts()
	a.searchView.delay = -1
	a.everywhereView.delay = -1
	a.version = options.Version
	if options.first != nil {
		a.backdrop = options.first.backdrop
	} else {
		a.backdrop = &workbenchBackground{}
	}
	a.text = i18n.For(a.language())
	a.applyLook(a.settings.Theme)
	a.shared.text.Store(a.text)
	a.shared.dark.Store(a.colors.Dark)
	if first := options.first; first != nil {
		// Another project tab: the window, its log window and its process ledger are the first
		// workbench's.
		a.sessions = first.sessions
		a.invalidator = first.invalidator
		a.application, a.window, a.fullscreen = first.application, first.window, first.fullscreen
		a.logSink, a.logs = first.logSink, first.logs
		a.updates = first.updates
	} else {
		a.sessions = newWindowSessions(a, options)
		a.updates = newUpdater(a.settings)
		a.invalidator = windowWake{invalidator: new(app.Invalidator)}
	}
	if options.Logs != nil && options.first == nil {
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
	if a.store != nil && options.first == nil {
		// Processes started from now on are recorded in the preferences' ledger (startup_sweep.go).
		processledger.Activate(a.store.Dir())
	}
	if settingsErr != nil {
		a.storedStateFailed("settings", settingsErr)
	} else if settingsUnread != nil {
		a.storedStateFailed("settings", settingsUnread)
	}
	if restoreErr != nil {
		a.backgroundFailed("update_snapshot", restoreErr)
	}
	a.openPlugins(options)
	a.settingsWindow = a.newSettingsWindow()
	a.loadRecent()
	a.loadChrome()
	if options.first == nil && a.store != nil {
		a.restoreBackground()
		if settingsErr == nil {
			// After the background is restored: the notice saves the settings, which would
			// otherwise save no background.
			a.noticeUnknownSettings()
		}
	}
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
			a.operationFailed("plugin_root", err)
			return
		}
		root = resolved
	}
	open := pluginservice.Open
	if options.first != nil {
		open = pluginservice.OpenAnother
	}
	service, err := open(options.PluginKernel, a.store, root)
	if err != nil {
		a.operationFailed("plugin_open", err)
		return
	}
	a.plugins = service
	service.Backend.SetInitializeTimeout(options.PluginInitializeTimeout)
	service.Backend.SetToolResolver(a.resolveBackendTool)
	service.Backend.SetToolEntryResolver(a.resolveBackendToolEntry)
	service.Backend.SetLogFacts(a.recordEngineFact)
	service.Backend.SetTraceFailed(a.traceFailed)
	a.watchDiagnostics()
	service.LanguageTool = a.resolveLanguageTool
	service.LogDirectory = a.pluginLogDirectory
	service.RecordFailed = a.pluginOperationRecordFailed
	if err := service.AttachWorkbench(pluginWorkbench{app: a}); err != nil {
		a.operationFailed("plugin_host_services", err)
	}
	a.wirePluginRuns()
}

// Run shows the window and returns when it is closed.
func (a *App) Run() error {
	app.SetNativeAppearance(nativeAppearance(a.settings.Theme))
	stop := app.WatchSystemAppearance(a.systemAppearanceChanged)
	defer stop()
	faulted := a.watchFaults()
	defer app.SetFaultHandler(nil)
	// app.Run opens a bare window that never paints; the window with the frame callbacks
	// is opened by the application.
	err := app.RunApplication(func(application *app.Application) error {
		a.application = application
		// System Quit bypasses window close requests unless it is intercepted here.
		application.OnQuitRequest(a.sessions.closeAll)
		window, err := application.OpenWindow(a.Config(), nil)
		if err != nil {
			return err
		}
		a.window = window
		a.startUpdates()
		if path := a.startupPath; path != "" {
			a.startupPath = ""
			a.post(func(a *App) { a.openProject(path) })
		}
		// The plugin stack is assembled before the window exists, because opening a
		// window is what installs the invalidator its background work needs.
		a.reloadPluginLanguages()
		a.loadGitHubAccount()
		// Core's stop time applies to every process stopped from now on, and Core decides what an
		// earlier run left behind; both need the window, which delivers their answers.
		a.refreshStopGrace()
		a.planStartupSweep()
		// Development builds mark the Dock icon without changing the product name in the UI.
		if buildinfo.Development {
			application.SetDockBadge(a.text.App.DevBadge)
		}
		return nil
	})
	a.windowLoopEnded(err, faulted.Load())
	for _, session := range a.sessions.everyOne() {
		session.unsubscribeSettings()
		session.stopWatchingDiagnostics()
		session.closeProject()
		session.wait()
		if session.pluginDownloads != nil {
			session.recordPluginInstallCleanup(context.Background(), session.pluginDownloads.Close())
		}
		if session.plugins != nil && session.plugins.Runs != nil {
			// Runs of the closed project are already stopped; this ends any the
			// project close did not own and refuses new ones during shutdown.
			session.plugins.Runs.StopAll()
		}
	}
	if a.logs != nil {
		a.logs.Wait()
	}
	return err
}

// watchFaults has Viva hand each panic it recovers in a callback to the client's log, as
// app.runtime.panic_interrupted under the boundary viva:<where>. Viva calls the handler on the
// panicking thread, which may hold the framework's locks, so it only records and sets the
// returned flag; Run removes the handler when the window loop ends. Without a log that records
// panics the flag stays false.
func (a *App) watchFaults() *atomic.Bool {
	faulted := new(atomic.Bool)
	if record := a.faultRecorder(faulted); record != nil {
		app.SetFaultHandler(record)
	}
	return faulted
}

// faultRecorder is the fault handler watchFaults installs: it records the fault in the client's
// log and sets faulted. It is nil without a log that records panics.
func (a *App) faultRecorder(faulted *atomic.Bool) func(app.Fault) {
	sink, ok := a.logSink.(panicSink)
	if !ok {
		return nil
	}
	return func(fault app.Fault) {
		faulted.Store(true)
		sink.RecordPanic("viva:"+fault.Where, fault.Message, fault.Stack)
	}
}

// windowLoopEnded logs the error the window loop ended with, as app.window.loop_failed. When
// Viva recovered a panic during the loop the error is the one that panic caused, which is
// already logged.
func (a *App) windowLoopEnded(err error, faulted bool) {
	if err == nil {
		return
	}
	if faulted {
		// log-exempt: 同一次失败已经记录过：Viva 恢复的 panic 已经记成 app.runtime.panic_interrupted，窗口循环返回的就是它造成的错误。
		return
	}
	a.emitAs("", core.LevelError, "app.window.loop_failed", core.LogErrorFields(err))
}

// systemAppearanceChanged hands the system event to the workbench thread before
// publishing the effective palette to its other windows.
func (a *App) systemAppearanceChanged() {
	a.post(func(a *App) {
		if a.settings.Theme != themeSystem {
			return
		}
		a.applyLook(themeSystem)
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
	a.closeProject()
	a.settingsWindow.Close()
	a.stopUpdates()
}

// openLogs shows the log window.
func (a *App) openLogs() { a.showLogs("") }

// showLogs shows the log window, narrowed to the records of op when op is not empty. The
// window is opened from the queue drained in OnWake, not from the paint or the event that
// asked for it, because opening a window while this one is painting is not allowed.
func (a *App) showLogs(op string) {
	if a.logs == nil {
		// The client runs without a log writer, so there is nowhere to record this: a failure
		// of the writer itself is never written through the writer.
		a.notifyError(a.text.Title.LogsUnavailable)
		return
	}
	a.post(func(a *App) {
		if err := a.openLogWindow(op); err != nil {
			a.operationFailed("log_window_open", err)
			a.notifyError(a.text.Errors.LogsFailed(err.Error()))
		}
	})
}

// openLogWindow opens the log window in the application, on the records of op when op is not
// empty. It runs on the window thread.
func (a *App) openLogWindow(op string) error {
	if a.logWindowOpen != nil {
		return a.logWindowOpen(op)
	}
	if a.application == nil {
		return nil
	}
	if op == "" {
		return a.logs.Open(a.application)
	}
	return a.logs.OpenOperation(a.application, op)
}

// emit writes one of the window's own events to the client's log, when there is one, under the
// user action in progress. It reads the window thread's state: a goroutine records with emitIn.
func (a *App) emit(level core.LogLevel, event string, fields map[string]any) {
	a.emitAs(a.op.id, level, event, fields)
}

// emitIn writes one of the window's own events from any goroutine, under the user action ctx
// belongs to (core.OriginOf), for work that runs off the window thread.
func (a *App) emitIn(ctx context.Context, level core.LogLevel, event string, fields map[string]any) {
	a.emitAs(core.OriginOf(ctx).Operation, level, event, fields)
}

// emitAs writes one event under op; empty op means the event belongs to no action.
func (a *App) emitAs(op string, level core.LogLevel, event string, fields map[string]any) {
	if a.logSink != nil {
		a.logSink.Emit(level, event, op, fields)
	}
}

// recordEngineFact writes a catalog fact Core attached to a plugin session's runtime event:
// a language server's stderr line or logMessage, a provider's lifecycle, a session's exit.
// Core chose the event and already checked and redacted its fields against the catalog, so
// the window adds nothing; the writer checks it again on the way out. Engine facts belong to
// no user action. It is safe from any goroutine.
func (a *App) recordEngineFact(level core.LogLevel, event string, fields map[string]any) {
	a.emitAs("", level, event, fields)
}

// traceFailed records that Core refused to switch the upstream trace of a plugin session the
// way detailed diagnostics were last turned. The runner reports one refusal per choice, so a
// broken kernel cannot flood the log. It is safe from any goroutine.
func (a *App) traceFailed(err error) {
	a.emitAs("", core.LevelWarn, "app.logging.diagnostics_failed", core.LogErrorFields(err))
}

// watchDiagnostics makes the upstream trace of this workbench's plugin sessions follow the
// detailed-diagnostics switch of the client's log: the sessions running when it turns, and
// those started while it is on, as Core's logging contract asks. Without a log that tells
// the switch, or without plugins, the trace stays off.
func (a *App) watchDiagnostics() {
	a.stopWatchingDiagnostics()
	sink, ok := a.logSink.(diagnosticsWatchSink)
	if !ok || a.plugins == nil {
		return
	}
	a.unwatchDiagnostics = sink.WatchDiagnostics(a.plugins.Backend.SetDetailedDiagnostics)
}

// stopWatchingDiagnostics stops the plugin sessions of this workbench following the
// detailed-diagnostics switch; it runs once the workbench is done with them.
func (a *App) stopWatchingDiagnostics() {
	if a.unwatchDiagnostics != nil {
		a.unwatchDiagnostics()
		a.unwatchDiagnostics = nil
	}
}

// pluginLogDirectory is the ${logDir} of a process started for pluginID: this log session's
// plugins/<id>/files directory, whose files retention and Clear Logs treat like the
// session's own. It is empty when the client runs without a log store, and when the
// directory cannot be made, which is recorded; the process then starts without one. It is
// safe from any goroutine.
func (a *App) pluginLogDirectory(ctx context.Context, pluginID string) string {
	sink, ok := a.logSink.(pluginFileSink)
	if !ok {
		return ""
	}
	directory, err := sink.PluginFilesDirectory(ctx, pluginID)
	if err != nil {
		a.backgroundFailedIn(ctx, "plugin_log_directory", documentLogError(err))
		return ""
	}
	return directory
}

// pluginOperationRecordFailed records that Core refused, or could not queue, the result of a
// declarative plugin contribution the window ran. It is safe from any goroutine.
func (a *App) pluginOperationRecordFailed(ctx context.Context, err error) {
	a.backgroundFailedIn(ctx, "plugin_operation_record", err)
}

// actionSurface is the part of the window a user action was started from. The set is closed:
// it is the list the catalog gives for the surface field of app.action.performed, and the
// test that checks every logging call against the kernel rejects a value outside it.
type actionSurface string

// The surfaces, written as the catalog's tokens. Each one is typed, so performed cannot be
// handed a bare string.
const (
	// surfaceMenu is a menu bar menu, the compact menu, or a drop-down opened from a menu
	// button.
	surfaceMenu actionSurface = "menu"
	// surfaceShortcut is a key binding.
	surfaceShortcut actionSurface = "shortcut"
	// surfacePalette is a command picked in Search Everywhere.
	surfacePalette actionSurface = "palette"
	// surfaceToolbar is a control on the title bar.
	surfaceToolbar actionSurface = "toolbar"
	// surfaceButton is a control clicked in a panel, tool window, sheet or dialog: a button, a
	// link, a list row or a gutter mark.
	surfaceButton actionSurface = "button"
	// surfaceContextMenu is a menu opened with a secondary click or from a "more" button on
	// an item.
	surfaceContextMenu actionSurface = "context_menu"
	// surfaceNotification is a button on a notification.
	surfaceNotification actionSurface = "notification"
	// surfacePlugin is a plugin backend asking the host to do the action.
	surfacePlugin actionSurface = "plugin"
	// surfaceDragDrop is a drop of a dragged file, tab or tree item.
	surfaceDragDrop actionSurface = "drag_drop"
)

// performed logs that the user started the action with the stable id from surface; the id is
// never a localized title. It starts the action's operation
// (operation.go): what the action records and the Core requests it sends share its op.
func (a *App) performed(action string, surface actionSurface) {
	a.op = operation{id: core.NewOperation(), trigger: action}
	a.emit(core.LevelInfo, "app.action.performed", map[string]any{"action": action, "surface": string(surface)})
}

// performedIn logs an action the user started in a window other than this one, such as the
// settings window, from the goroutine that runs it. It never touches the window thread's
// operation: the action's operation travels in the returned context, under which the work
// records its events (emitIn) and sends its Core requests.
func (a *App) performedIn(ctx context.Context, action string, surface actionSurface) context.Context {
	id := core.NewOperation()
	a.emitAs(id, core.LevelInfo, "app.action.performed", map[string]any{"action": action, "surface": string(surface)})
	return core.WithOrigin(ctx, core.Origin{Operation: id, Trigger: action})
}

// chromeSurface is the surface a click on the rearrangeable button of catalog item index
// comes from: the toolbar while the button sits in the title bar, a button on a stripe.
func (a *App) chromeSurface(index int) actionSurface {
	if a.chrome.zoneOf(index).surface() == surfaceTitle {
		return surfaceToolbar
	}
	return surfaceButton
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
	a.applyLook(choice)
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
	// The background is the window's, which another tab may have changed since this one loaded.
	a.settings.WorkbenchBackground = a.savedBackgroundState()
	a.updates.store(&a.settings)
	if err := a.store.Save(settingsFile, a.settings); err != nil {
		a.operationFailed("settings_save", documentLogError(err))
		a.notifyError(a.text.Errors.SaveFailed(err.Error()))
	}
}

// resetLayout puts every rearrangeable button back where the catalog puts it.
func (a *App) resetLayout() { a.reduceChrome(core.ResetChrome()) }

// hideEntry takes the stripe button of catalog item index off its stripe. The kernel keeps its
// zone and position and closes its tool window; the background button's popover closes with
// it, because it hangs off the button.
func (a *App) hideEntry(index int) {
	id := a.chrome.catalog[index].id
	if id == itemToolWindows {
		// The "…" button is the way back to the hidden buttons (chromeState.apply).
		return
	}
	if id == itemBackground {
		a.backdropOpen = false
	}
	a.reduceChrome(core.SetChromeHidden(id, true))
}

// showEntry puts the hidden stripe button of catalog item index back where it was and, when
// open is set, opens what the button opens, as a click on it does: its tool window, or the
// background button's popover. A tool window that is already open, from a shortcut, stays
// open.
func (a *App) showEntry(index int, open bool) {
	it := a.chrome.catalog[index]
	a.reduceChrome(core.SetChromeHidden(it.id, false))
	if !open || a.chrome.isHidden(index) {
		// The kernel refused, which reduceChrome reported.
		return
	}
	switch {
	case it.id == itemBackground:
		a.backdropOpen = true
	case it.panel && !a.chrome.isOpen(index):
		a.activate(index)
	}
}

// activate is a click on the rearrangeable button of catalog item index: a tool
// button opens or closes its tool window, the settings button opens or closes its menu
// and the commands that need a provider that is not connected yet say so.
func (a *App) activate(index int) {
	it := a.chrome.catalog[index]
	switch {
	case it.panel:
		a.reduceChrome(core.ToggleChrome(it.id))
		if it.id == itemFind && a.chrome.isOpen(index) {
			a.searchView.focus = true
		}
	case it.id == itemTitleSettings:
		a.title.gearOpen = !a.title.gearOpen
		a.title.projectOpen, a.title.runConfigOpen = false, false
		a.closeBranches()
	case it.id == itemRunConfig:
		if a.title.runConfigOpen {
			a.title.runConfigOpen = false
		} else if a.project != nil {
			a.openRunConfigMenu()
		}
	case it.id == itemTitleRun:
		a.titleRun(a.project)
	case it.id == itemTitleDebug:
		a.titleDebug(a.project)
	case it.id == itemTitleSearch:
		if a.project != nil {
			a.performed("workspace.searchEverywhere.open", a.chromeSurface(index))
			a.openEverywhere(a.project)
		}
	case it.id == itemCaret:
		if a.project != nil {
			a.openNavigation(a.project)
		}
	case it.id == itemLSP:
		if a.project != nil {
			a.editor.lsp.menu = !a.editor.lsp.menu
		}
	case it.id == itemMemory:
		a.toggleMemoryDetails()
	case it.id == itemEncoding:
		if a.project != nil && a.project.selectedDocument(a.project.docs.group) != nil {
			a.editor.encoding.open = !a.editor.encoding.open
		}
	case it.id == itemIndent:
		a.toggleIndentation(a.selectedEditorDocument())
	case it.id == itemEOL:
		a.toggleLineEnding(a.selectedEditorDocument())
	case it.id == itemLock:
		a.toggleReadOnly(a.selectedEditorDocument())
	}
}

// hidePanel closes the tool window open in a slot.
func (a *App) hidePanel(s slot) {
	if index := a.chrome.open[s]; index >= 0 {
		a.reduceChrome(core.SetChromeOpen(a.chrome.catalog[index].id, false))
	}
}

// loadRecent reads the recent project list and lets the kernel order and bound it.
func (a *App) loadRecent() {
	var entries []core.RecentProject
	if _, err := a.store.Load(recentFile, &entries); err != nil {
		a.storedStateFailed("recent_projects", err)
		a.notifyError(a.text.Errors.Core(err.Error()))
		entries = nil
	}
	a.reduceRecent(entries, core.NormalizeRecent(), false)
}

// reduceRecent sends one change of the recent project list to the kernel and keeps
// the result, saving it when save is set.
func (a *App) reduceRecent(entries []core.RecentProject, action core.RecentAction, save bool) {
	ctx, cancel := context.WithTimeout(a.operationContext(context.Background()), kernelCallTimeout)
	defer cancel()
	result, err := a.kernel.ReduceRecentProjects(ctx, entries, action, 0)
	if err != nil {
		a.operationFailed("workspace_recent_reduce", documentLogError(err))
		a.notifyError(a.text.Errors.Core(err.Error()))
		return
	}
	if save {
		if err := a.store.Save(recentFile, result.Entries); err != nil {
			a.operationFailed("workspace_recent_save", documentLogError(err))
			a.notifyError(a.text.Errors.SaveFailed(err.Error()))
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
func (a *App) chooseProject(surface actionSurface) {
	title := a.text.Welcome.OpenDialogTitle
	a.background(nil, 0, func(context.Context) func(*App) {
		path, err := app.OpenDirectory(app.OpenDirectoryOptions{Title: title})
		return func(a *App) {
			switch {
			case errors.Is(err, app.ErrCanceled):
			case err != nil:
				a.operationFailed("project_open_dialog", err)
				a.notifyError(a.text.Errors.OpenFailed(err.Error()))
			default:
				a.performed("workspace.open", surface)
				a.openProject(path)
			}
		}
	})
}

// openProjectHere opens the folder at path as the project of the window, replacing the
// one that was open. openProject first asks where to open it.
func (a *App) openProjectHere(path string) {
	root, err := filepath.Abs(wslpath.ToNative(path))
	if err != nil {
		a.operationFailed("workspace_open", documentLogError(err))
		a.notifyError(a.text.Errors.OpenFailed(err.Error()))
		return
	}
	if info, err := os.Stat(root); err != nil || !info.IsDir() {
		if err == nil {
			err = errors.New("not a directory")
		}
		a.operationFailed("workspace_open", documentLogError(err))
		a.notifyError(a.text.Errors.FolderMissing(root))
		return
	}
	a.requestCloseProject(func() {
		a.reduceRecent(a.recent, core.RecordRecent(root, a.now()), true)
		// Every Git command the project runs is kept in the Git console.
		ctx, cancel := context.WithCancel(core.WithGitConsole(context.Background(), a.gitConsole, root))
		p := &project{root: root, name: filepath.Base(root), ctx: ctx, cancel: cancel, commit: newCommitState()}
		a.searchView.reset()
		a.openTerminals(p)
		a.project = p
		a.ideAPISetProject(p)
		rootCopy := root
		a.toolchainRoot.Store(&rootCopy)
		a.notice = ""
		a.logView.reset()
		a.worktreeView.reset()
		a.installIndexing(p, false)
		a.loadGit(p)
		a.startGitObservation(p)
		a.loadLog(p)
		a.activatePluginWorkspace(root)
		a.restoreEditorSession(p)
		a.restoreCheckpoints(p)
		a.restoreNativePanels(p)
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
		lifecycle := exitContextCloseWorkspace
		if after != nil {
			lifecycle = exitContextQuit
		}
		a.confirmProcessExit(p, lifecycle, func() { a.finishCloseProject(p, after) })
	})
}

// finishCloseProject takes the project apart once saving and the exit
// confirmation allowed it. Closing ends every run and the debug session the
// project started: they belong to the window, so nothing is left running.
func (a *App) finishCloseProject(p *project, after func()) {
	if a.project != p {
		return
	}
	{
		a.saveEditorSession(p)
		a.saveNativePanels(p)
		a.releaseIndexing(p)
		a.closeEverywhere(p)
		a.recentFiles.open = false
		a.recentFiles.generation++
		a.recentFiles.lastEdited = 0
		a.recentFiles.list = nil
		a.recentFiles.listState = ui.ListState{}
		a.drafts.open, a.drafts.loading = false, false
		a.drafts.generation++
		a.drafts.entries = nil
		a.drafts.list = ui.ListState{}
		if a.navigation.open && a.navigation.project == p {
			a.closeNavigation()
		}
		a.cancelPrompts()
		a.ideAPIDisable(p)
		p.cancel()
		a.closePluginPages()
		a.closePreviewPages()
		a.closeTree(p)
		a.closeGitObservation(p)
		a.releaseProjectSearch(p)
		a.closeDocuments(p)
		p.closeDiffs()
		a.closeTerminals(p)
		// A test run owns a process or provider request, so it is stopped before
		// the build providers it borrowed close.
		a.stopTestsForProject(p)
		a.stopDebugForProject(p)
		a.stopRunsForProject(p)
		// Build providers and prepared applications belong to the workspace and
		// are stopped before the project state is dropped.
		a.stopBuild(p)
		// Version control provider sessions run in the workspace too.
		a.stopVcs(p)
		// A language server is bound to the workspace it was started for, so it goes
		// with the project rather than outliving it.
		a.stopAllPluginServers()
		a.clearAllPluginDiagnostics()
		a.problems.reset()
		a.toolchainRoot.Store(nil)
		a.project = nil
		a.ideAPISetProject(nil)
		a.focus = focusTarget{}
		a.dnd.tool.Cancel()
		a.dnd.tab.Cancel()
		a.drag, a.term.drag = dragState{}, tabDrag{}
		a.title = titleState{}
		a.branch.branchSession = branchSession{}
		if after != nil {
			after()
		} else {
			// A project closed on its own leaves its tab when the window has others.
			a.sessions.leave(a)
		}
	}
}
