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

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugininstall"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// ErrAssembly reports a stack that cannot be built.
var ErrAssembly = errors.New("plugin service cannot be assembled")

// Kernel is the Core client surface the plugin stack needs. *core.Client
// satisfies it.
type Kernel interface {
	pluginhost.ManifestValidator
	pluginbackend.Kernel
	pluginsettings.Kernel
	ReadInstalledPluginSettingsState(context.Context, json.RawMessage, string, string) (core.PluginSettingsState, error)
	SelectInstalledPluginVersions(context.Context, []core.InstalledPluginFact, bool) (core.InstalledPluginSelection, error)
	ExpandPluginWorkspaceConfiguration(context.Context, json.RawMessage, string, map[string]json.RawMessage, map[string]json.RawMessage) (json.RawMessage, error)
	UpdatePluginWorkspaceConfiguration(context.Context, string, json.RawMessage) (bool, error)
	ReviewMarketplaceInstall(ctx context.Context, manifest json.RawMessage, expectedID, expectedVersion string, approvedPrograms []json.RawMessage, hostCapabilities map[string][]int) (core.MarketplaceReview, error)
	DecodePluginGrammar(ctx context.Context, manifest json.RawMessage, languageID, source string) (core.PluginEditorLanguage, error)
	SyncPluginDocument(ctx context.Context, request core.PluginDocumentSyncRequest) (core.PluginDocumentSync, error)
	SavePluginDocument(ctx context.Context, session, uri, text string) (sent bool, err error)
	ClosePluginDocument(ctx context.Context, session, uri string) error
}

// Service is the assembled plugin stack.
type Service struct {
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
	// kernel reads what only Core can validate, such as a plugin's grammar.
	kernel Kernel
}

// Open assembles the stack over one plugin root and one set of preferences.
func Open(kernel Kernel, preferences *store.Store, root string) (*Service, error) {
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
	if err := pluginpkg.Sweep(root); err != nil {
		return nil, fmt.Errorf("%w: %w", ErrAssembly, err)
	}
	return &Service{
		Root:         root,
		Manager:      pluginmanager.New(root, approvals, state),
		Installer:    plugininstall.New(kernel, NewReviewer(kernel), approvals, pluginhost.Declared()),
		Backend:      pluginbackend.New(kernel, hostServices),
		Settings:     pluginsettings.New(kernel, preferences.Dir()),
		HostServices: hostServices,
		kernel:       kernel,
	}, nil
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
