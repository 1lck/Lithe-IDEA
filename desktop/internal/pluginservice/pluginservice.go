// Package pluginservice assembles the plugin stack the workbench uses.
//
// Every other plugin package is deliberately narrow and free of the others:
// pluginpkg extracts, plugintrust approves, pluginhost verifies, plugininstall
// orchestrates and pluginbackend runs. This package is the single place that
// knows how they fit together, so the workbench never has to.
//
// It is also where Core's own review type is adapted to the shape the trust rules
// use. That adapter is the only reason this package imports the Core bridge.
package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"sync/atomic"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/credentials"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugininstall"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
	"github.com/1lck/Lithe-IDEA/desktop/internal/processledger"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

// ErrAssembly reports a stack that cannot be built.
var ErrAssembly = errors.New("plugin service cannot be assembled")

// Kernel is the Core client surface the plugin stack needs. *core.Client
// satisfies it.
type Kernel interface {
	PlanPluginSettingsAction(context.Context, core.PluginSettingsActionRequest) (core.PluginSettingsActionPlan, error)
	pluginhost.ManifestValidator
	pluginbackend.Kernel
	pluginsettings.Kernel
	ReadInstalledPluginSettingsState(context.Context, json.RawMessage, string, string) (core.PluginSettingsState, error)
	ApplyPluginViewResult(ctx context.Context, manifest json.RawMessage, surface core.PluginViewSurface, view, result json.RawMessage) (json.RawMessage, bool, error)
	SelectInstalledPluginVersions(context.Context, []core.InstalledPluginFact, bool) (core.InstalledPluginSelection, error)
	pluginmanager.Kernel
	ExpandPluginWorkspaceConfiguration(context.Context, json.RawMessage, string, map[string]json.RawMessage, map[string]json.RawMessage) (json.RawMessage, error)
	UpdatePluginWorkspaceConfiguration(context.Context, string, json.RawMessage) (bool, error)
	ReviewMarketplaceInstall(ctx context.Context, manifest json.RawMessage, expectedID, expectedVersion string, approvedPrograms []json.RawMessage, hostCapabilities map[string][]int) (core.MarketplaceReview, error)
	DecodePluginGrammar(ctx context.Context, manifest json.RawMessage, languageID, source string) (core.PluginEditorLanguage, error)
	SyncPluginDocument(ctx context.Context, request core.PluginDocumentSyncRequest) (core.PluginDocumentSync, error)
	SavePluginDocument(ctx context.Context, session, uri, text string) (sent bool, err error)
	ClosePluginDocument(ctx context.Context, session, uri string) error
	ConfigureFunctionRelay(ctx context.Context, plugins []core.RelayPlugin, contexts []core.RelayContext) error
	DecodeRunStart(ctx context.Context, manifest json.RawMessage, workspaceRoot, temporaryDirectory string, params json.RawMessage) (core.RunStart, error)
	DecodeDebugBackendConfiguration(ctx context.Context, manifest json.RawMessage, params json.RawMessage) (core.DebugBackendStart, error)
	DecodeOutputLinkResolution(ctx context.Context, reply json.RawMessage) (*core.OutputLocation, error)
	DecodePluginLanguageServerLaunch(ctx context.Context, manifest json.RawMessage, languageID string, directories core.PluginBackendDirectories, answer json.RawMessage) (core.PluginBackendPlan, error)
	RecordPluginOperation(ctx context.Context, operation core.PluginOperation) error
}

// Service is the assembled plugin stack.
type Service struct {
	toolchainProviders *toolchain.ProviderClient
	toolchainKernel    toolchainProviderKernel
	// ToolchainIssue records discovery failures that left declared fallback sources usable.
	ToolchainIssue func(context.Context, error)
	// BuildConfigurationIssue records native failures opening or rebinding configuration watches.
	BuildConfigurationIssue func(context.Context, error)
	// WorkspaceWatchIssue records native failures establishing or maintaining a workspace stream.
	WorkspaceWatchIssue func(context.Context, error)
	// providers2 holds the editor provider registrations of the window (hostproviders.go).
	providers2 *editorProviderBindings
	// actions holds the editor action registrations of the window (hostactions.go).
	actions *editorActionBindings
	// ledger records the run processes this app started, so the next start can end leftovers.
	ledger *processledger.Ledger
	// startupLeftovers are the processes an earlier run left behind that are not settled yet.
	// leftoversMu guards it, since settling runs off the window thread.
	leftoversMu      sync.Mutex
	startupLeftovers []processledger.Record
	// Root is the directory installed packages live in.
	Root string
	// Manager owns the installed set, uninstall and enablement.
	Manager *pluginmanager.Manager
	// Installer prepares and commits an installation.
	Installer *plugininstall.Service
	// Backend starts and stops plugin backends and answers their host requests.
	Backend *pluginbackend.Runner
	// Commands records the commands the host installed through plugins' command
	// installers, below the plugin root's state directory; Backend's
	// system-command launches look there after PATH.
	Commands *pluginhost.CommandStore
	// Settings reads actual plugin-owned preference layers from native storage.
	Settings *pluginsettings.Store
	// HostServices is the registry a backend's grants are narrowed against.
	HostServices *pluginhost.Services
	// Credentials is the platform secret store behind credentials/*.
	Credentials *credentials.Store
	// Host starts plugin backends on demand and calls their functions.
	Host *BackendHost
	// Contexts holds the workspace contexts plugin backends see.
	Contexts *WorkspaceContexts
	// ContextIssue records a failed notification to an already running backend.
	ContextIssue func(context.Context, error)
	// contextsNotifyMu serializes didChangeContexts delivery with backend activation so a
	// backend that starts after a workspace opens receives the latest revision once.
	contextsNotifyMu sync.Mutex
	contextsNotified map[string]workspaceNotificationRevision
	// workbench is the window the document, editor, window and terminal services drive.
	workbench Workbench
	messages  *messageLimiter
	// terminalHost and terminals serve the plugin terminal methods; both are nil
	// when the window cannot start terminals.
	terminalHost TerminalHost
	terminals    *terminalRegistry
	// virtualHost and providers serve content providers; nil without a window.
	virtualHost VirtualDocumentHost
	providers   *contentProviders
	// resources are the subscriptions, providers and terminals backends hold.
	resources   *hostResources
	workflow    *workflowResources
	viewRefresh viewRefreshRegistry
	// Runs owns the processes backends start through run/start.
	Runs *Runs
	// LanguageTool resolves an optional installation for a backend-resolved
	// language server. A nil installation means the tool is unavailable.
	LanguageTool func(context.Context, string, string) (*core.ToolchainSelection, error)
	// RuntimeIssue records a damaged cache being repaired or a native cleanup failure.
	// Production always wires the owning log boundary before preparing any runtime.
	RuntimeIssue func(context.Context, error)
	// RuntimeDownloader is the application's HTTPS transport for pinned dependency archives.
	RuntimeDownloader *marketplace.ArchiveDownloader
	runtimeLanguage   atomic.Pointer[string]
	// runtimeBlocked closes preparation admission after disable/uninstall. The
	// cross-window runtimePreparationCoordinator guards it and active preparations.
	runtimeBlocked map[string]bool
	// LogDirectory gives the ${logDir} of a process started for a plugin: the current log
	// session's plugins/<id>/files directory, created by the window's log store. An empty
	// answer, or a nil LogDirectory, means there is no local log store; the process then gets
	// no logDirectory and a launch that names ${logDir} is refused, as the contract says.
	LogDirectory func(ctx context.Context, pluginID string) string
	// RecordFailed reports that Core refused or could not queue the result of a declarative
	// contribution the host ran. A nil RecordFailed drops the error: the result is diagnostics,
	// and the attempt it describes already went its own way.
	RecordFailed func(ctx context.Context, err error)
	// kernel reads what only Core can validate, such as a plugin's grammar.
	kernel      Kernel
	preferences *store.Store
	// lsMu guards the running plugin-owned language servers backends reach.
	lsMu          sync.Mutex
	lsSessions    map[languageKey]*LanguageSession
	lsGenerations map[languageKey]uint64
}

// ActivatePendingUpdates moves fully approved packages into the installed inventory at startup.
func (s *Service) ActivatePendingUpdates(ctx context.Context) error {
	return s.Installer.ActivatePending(ctx, s.Root, s.BeginRuntimeInstallation, func(ctx context.Context, id string) (string, error) {
		entries, err := s.CurrentInstalled(ctx)
		if err != nil {
			return "", err
		}
		for _, entry := range entries {
			if entry.Installed.ID == id && entry.Enabled {
				return entry.Installed.Version, nil
			}
		}
		return "", nil
	})
}

// Open assembles the stack over one plugin root and one set of preferences.
func Open(kernel Kernel, preferences *store.Store, root string) (*Service, error) {
	return open(kernel, preferences, root, true)
}

// OpenAnother assembles the stack of another workbench of the same process, over the root and
// preferences the first one opened. It leaves out what only the first may do at start-up: the sweep
// of interrupted installs, which would remove an install the first is running, and the leftover
// processes, which here would be the first's own runs.
func OpenAnother(kernel Kernel, preferences *store.Store, root string) (*Service, error) {
	return open(kernel, preferences, root, false)
}

func open(kernel Kernel, preferences *store.Store, root string, first bool) (*Service, error) {
	if kernel == nil {
		return nil, fmt.Errorf("%w: no kernel", ErrAssembly)
	}
	if preferences == nil {
		return nil, fmt.Errorf("%w: no preferences", ErrAssembly)
	}
	if root == "" || !filepath.IsAbs(root) {
		return nil, fmt.Errorf("%w: the plugin root must be an absolute path", ErrAssembly)
	}
	approvals := plugintrust.New(preferences)
	state := pluginstate.New(preferences)
	hostServices := pluginhost.NewServices()
	// Nothing else removes what an interrupted install or uninstall left behind, and
	// Open runs before any installation can start.
	if first {
		if err := pluginpkg.Sweep(root); err != nil {
			return nil, fmt.Errorf("%w: %w", ErrAssembly, err)
		}
	}
	// The processes an earlier run left behind are only read here: the window's start-up sweep has
	// Core decide each (end it, or ask the user) and settles them through SettleStartupLeftovers.
	// Until then they stay recorded, so a start that ends before the sweep finds them again.
	ledger := processledger.Open(preferences.Dir())
	var leftovers []processledger.Record
	if first {
		leftovers, _ = ledger.Leftovers()
	}
	service := &Service{
		startupLeftovers:  leftovers,
		Root:              root,
		Manager:           pluginmanager.New(kernel, root, approvals, state),
		Installer:         plugininstall.New(kernel, NewReviewer(kernel), approvals, pluginhost.Declared()),
		Backend:           pluginbackend.New(kernel, hostServices),
		Commands:          &pluginhost.CommandStore{State: filepath.Join(root, pluginpkg.StateDirectory)},
		Settings:          pluginsettings.New(kernel, preferences.Dir()),
		HostServices:      hostServices,
		Credentials:       credentials.Default(),
		kernel:            kernel,
		preferences:       preferences,
		resources:         newHostResources(),
		ledger:            ledger,
		messages:          newMessageLimiter(),
		RuntimeDownloader: marketplace.NewArchiveDownloader(nil),
	}
	service.Backend.SetCommandStore(service.Commands)
	service.Host = newBackendHost(service)
	if providerKernel, ok := kernel.(toolchainProviderKernel); ok {
		service.toolchainKernel = providerKernel
		service.toolchainProviders = &toolchain.ProviderClient{
			Request:      service.queryToolchain,
			FailureReply: providerKernel.ToolchainFailureReply,
			Decode:       providerKernel.DecodeToolchainReply,
			Failed: func(ctx context.Context, err error) {
				if service.ToolchainIssue != nil {
					service.ToolchainIssue(ctx, err)
				}
			},
		}
	}
	service.Runs = newRuns(service)
	service.Contexts = newWorkspaceContexts(filepath.Join(root, pluginpkg.StateDirectory))
	service.Contexts.SetObserver(service.contextsChanged)
	service.Contexts.SetClosedObserver(service.resources.releaseContext)
	if err := service.registerHostServices(); err != nil {
		return nil, fmt.Errorf("%w: %w", ErrAssembly, err)
	}
	return service, nil
}

// Capabilities reports the contract capabilities the installer validates against.
func (s *Service) Capabilities() pluginhost.Capabilities {
	return pluginhost.Declared()
}

// Reviewer adapts Core's install review to the shape plugintrust and
// plugininstall use.
type Reviewer struct {
	kernel Kernel
}

// NewReviewer returns a reviewer backed by Core.
func NewReviewer(kernel Kernel) *Reviewer {
	return &Reviewer{kernel: kernel}
}

// ReviewPluginInstall asks Core to validate the package and enumerate its
// programs.
//
// The capabilities passed to Core are the ones this client actually implements,
// so a package that needs an unwired capability is refused here rather than at
// first use.
func (r *Reviewer) ReviewPluginInstall(ctx context.Context, manifest json.RawMessage, expectedID, expectedVersion string, approvedPrograms []json.RawMessage) (plugintrust.Review, error) {
	if r == nil || r.kernel == nil {
		return plugintrust.Review{}, fmt.Errorf("%w: no kernel", ErrAssembly)
	}
	review, err := r.kernel.ReviewMarketplaceInstall(ctx, manifest, expectedID, expectedVersion, approvedPrograms, pluginhost.Declared().Clone())
	if err != nil {
		return plugintrust.Review{}, err
	}
	return plugintrust.Review{
		Permissions: append([]string(nil), review.Permissions...),
		Programs:    cloneRaw(review.Programs),
		NewPrograms: cloneRaw(review.NewPrograms),
	}, nil
}

func cloneRaw(values []json.RawMessage) []json.RawMessage {
	if len(values) == 0 {
		return nil
	}
	cloned := make([]json.RawMessage, len(values))
	for i, value := range values {
		cloned[i] = append(json.RawMessage(nil), value...)
	}
	return cloned
}
