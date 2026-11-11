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

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/credentials"
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
	ValidatePluginNativeData(ctx context.Context, declaration, data json.RawMessage) (json.RawMessage, error)
	SelectInstalledPluginVersions(context.Context, []core.InstalledPluginFact, bool) (core.InstalledPluginSelection, error)
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
}

// Service is the assembled plugin stack.
type Service struct {
	// providers2 holds the editor provider registrations of the window (hostproviders.go).
	providers2 *editorProviderBindings
	// actions holds the editor action registrations of the window (hostactions.go).
	actions *editorActionBindings
	// ledger records the run processes this app started, so the next start can end leftovers.
	ledger *processledger.Ledger
	// startupLeftovers are the processes an earlier run left behind, awaiting the user's decision.
	startupLeftovers []processledger.Record
	// Root is the directory installed packages live in.
	Root string
	// Manager owns the installed set, uninstall and enablement.
	Manager *pluginmanager.Manager
	// Installer prepares and commits an installation.
	Installer *plugininstall.Service
	// Backend starts and stops plugin backends and answers their host requests.
	Backend *pluginbackend.Runner
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
	resources *hostResources
	// Runs owns the processes backends start through run/start.
	Runs *Runs
	// kernel reads what only Core can validate, such as a plugin's grammar.
	kernel Kernel
	// lsMu guards the running plugin-owned language servers backends reach.
	lsMu          sync.Mutex
	lsSessions    map[languageKey]*LanguageSession
	lsGenerations map[languageKey]uint64
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
	// Runs the earlier app left behind are ended before anything new starts. A failure leaves them
	// running, as they were before the ledger existed; the next start tries again.
	// The leftovers are offered for the user's decision at start-up instead of ended silently.
	ledger := processledger.Open(preferences.Dir())
	var leftovers []processledger.Record
	if first {
		leftovers, _ = ledger.Leftovers()
	}
	service := &Service{
		startupLeftovers: leftovers,
		Root:             root,
		Manager:          pluginmanager.New(root, approvals, state),
		Installer:        plugininstall.New(kernel, NewReviewer(kernel), approvals, pluginhost.Declared()),
		Backend:          pluginbackend.New(kernel, hostServices),
		Settings:         pluginsettings.New(kernel, preferences.Dir()),
		HostServices:     hostServices,
		Credentials:      credentials.Default(),
		kernel:           kernel,
		resources:        newHostResources(),
		ledger:           ledger,
		messages:         newMessageLimiter(),
	}
	service.Host = newBackendHost(service)
	service.Runs = newRuns(service)
	service.Contexts = newWorkspaceContexts(filepath.Join(root, pluginStateDirectory))
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
