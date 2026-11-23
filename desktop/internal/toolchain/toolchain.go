// Package toolchain turns enabled plugins' tool definitions into the native facts
// Core needs: declarative scans, filesystem evidence, bounded version probes and
// one saved directory choice. Core alone validates declarations, orders
// candidates and decides which layer wins; this package performs the native I/O
// and never branches on a tool name.
package toolchain

import (
	"context"
	"encoding/json"
	"errors"
	"os"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// Kernel is the part of the Core client this package uses. *core.Client
// satisfies it.
type Kernel interface {
	ToolchainRegistryOf(ctx context.Context, manifests []json.RawMessage) (core.ToolchainRegistry, error)
	ToolchainDiscoveryPlanOf(ctx context.Context, registry json.RawMessage, platform string) (core.ToolchainDiscoveryPlan, error)
	ToolchainCandidatesOf(ctx context.Context, request core.ToolchainCandidatesRequest) (core.ToolchainCandidates, error)
	ResolveToolchain(ctx context.Context, request core.ToolchainResolveRequest) (core.ToolchainResolution, error)
	ResolveToolchainPins(ctx context.Context, document json.RawMessage, directory, tool string) (core.ToolchainPinResolution, error)
	EditToolchainPins(ctx context.Context, document json.RawMessage, directory string, edits []core.ToolchainPinEdit) (json.RawMessage, error)
	ToolchainPinStorage(ctx context.Context) (core.ToolchainPinStoragePlan, error)
	DecodeToolchainPinDocument(ctx context.Context, document *string) (json.RawMessage, error)
	EditToolchainPinSources(ctx context.Context, request core.ToolchainPinSourcesRequest) (core.ToolchainPinSourcesEdit, error)
}

// ErrPinConflict reports that the pin document changed after it was read. The
// caller must keep its draft and show the conflict rather than overwrite it.
var ErrPinConflict = errors.New("toolchain: the local toolchain document changed since it was read")

// ProbeFunc runs one bounded version probe. A non-zero exit code is a probe
// result, not a Go error.
type ProbeFunc func(ctx context.Context, executable string, arguments []string) (output string, exitCode int, err error)

// LookupFunc resolves a shell command to its executable path.
type LookupFunc func(command string) (string, error)

// PlatformName is the Core platform spelling for the running host.
func PlatformName(goos string) string {
	switch goos {
	case "darwin":
		return "macos"
	case "windows":
		return "windows"
	default:
		return "linux"
	}
}

// Tool is one definition the settings view presents.
type Tool struct {
	CustomHomes []string `json:"customHomes,omitempty"`
	ID          string   `json:"id"`
	DisplayName string   `json:"displayName"`
	PluginID    string   `json:"pluginID"`
	// PluginName is the declaring plugin's manifest display name, empty when the
	// manifest has none; the settings page then shows PluginID.
	PluginName string `json:"pluginName,omitempty"`
	// Category and Audience are the definition's display group (toolDefinitions
	// 1); empty means other and user.
	Category string `json:"category,omitempty"`
	Audience string `json:"audience,omitempty"`
	// ManagedRuntime reports that the declaring plugin manages this tool through
	// managedRuntimes, so the settings page can prepare or repair it on demand.
	ManagedRuntime bool `json:"managedRuntime,omitempty"`
	// ManagedRuntimeHomes lists canonical directories prepared via managedRuntimes
	// so the settings UI can distinguish them from generic system discovery.
	ManagedRuntimeHomes []string `json:"managedRuntimeHomes,omitempty"`
	// ManagedOnly reports a plugin managedRuntimes dependency that does not bind a
	// toolDefinition, surfaced read-only under Plugin Runtimes.
	ManagedOnly bool `json:"managedOnly,omitempty"`
	// Reason is Core's stable code when no installation applies, empty when the
	// tool resolved.
	Reason string `json:"reason,omitempty"`
	// Providers are the qualified provider IDs that declared this tool.
	Providers []string `json:"providers"`

	Pin       *core.ToolchainPin `json:"pin,omitempty"`
	PinSource string             `json:"pinSource,omitempty"`

	Project       []core.ToolchainProjectCandidate    `json:"project,omitempty"`
	Shell         []core.ToolchainShellCandidate      `json:"shell"`
	Installations []core.ToolchainInstallation        `json:"installations"`
	Skipped       []core.ToolchainSkippedInstallation `json:"skipped"`
	AutomaticHome string                              `json:"automaticHome,omitempty"`
	// Automatic is the whole selection behind AutomaticHome: what the tool falls back
	// to when the scope pins nothing, with its version and layer. Nil when that
	// resolution found nothing; AutomaticReason is then Core's code.
	Automatic       *core.ToolchainSelection `json:"automatic,omitempty"`
	AutomaticReason string                   `json:"automaticReason,omitempty"`

	Effective *core.ToolchainSelection        `json:"effective,omitempty"`
	Trace     []core.ToolchainResolutionTrace `json:"trace"`
	Unmet     []json.RawMessage               `json:"unmet"`
	Conflicts []json.RawMessage               `json:"conflicts"`
	// Hidden lists provider declarations the host cannot query yet, so the
	// settings page says the tool may have more installations than shown.
}

// Snapshot is everything one settings load read for one project directory.
type Snapshot struct {
	Global             bool `json:"global,omitempty"`
	ProjectCodeAllowed bool `json:"projectCodeAllowed,omitempty"`
	// DiscoveryIncomplete reports that another enabled plugin could not be
	// read; usable tools remain available but this is not a complete catalog.
	DiscoveryIncomplete bool `json:"discoveryIncomplete,omitempty"`
	catalog             *catalogSource
	Root                string                   `json:"root"`
	Directory           string                   `json:"directory"`
	Tools               []Tool                   `json:"tools"`
	Conflicts           []core.ToolchainConflict `json:"conflicts"`
	// Baseline is the exact bytes of .lithe/toolchains/local.json that the
	// snapshot was built from, nil when the file did not exist.
	Baseline []byte `json:"-"`
	// rootIdentity belongs to the loaded native workspace, not its pathname.
	rootIdentity os.FileInfo
	source       pinSource
}

// Options configure one load. The zero value uses the host platform, the user's
// home, the process environment and a bounded native probe.
type Options struct {
	// Providers are the enabled plugins' on-demand query transport and cache.
	// ProviderScope is required when Providers queries an open project.
	Providers           *ProviderClient
	ProviderScope       *ProviderScope
	providerVersions    map[string]string
	skipPinnedProviders bool

	// DiscoveryTools restricts Load to the consumer's requested tool IDs. An
	// empty list loads the complete settings catalog.
	DiscoveryTools []string

	// Global permits discovery without any project; GlobalRoot owns the native SDK
	// registry and per-workspace toolchain trust in user application settings.
	Global     bool
	GlobalRoot string
	// WorkspaceRoots are native open-workspace facts, including other workbenches.
	// Global selection still excludes their code before any version probe.
	WorkspaceRoots []string
	// ProjectCodeAllowed grants probing and selection of workspace-local tool
	// candidates only when GlobalRoot is unset in unit tests. Production loads and
	// launches always supply GlobalRoot so trust comes solely from local storage.
	ProjectCodeAllowed bool
	catalog            *core.ToolchainCatalog
	Platform           string
	Home               string
	Environment        map[string]string
	Probe              ProbeFunc
	Lookup             LookupFunc
	// MinimumVersion is a consumer requirement for one operation; settings
	// loads leave it empty.
	MinimumVersion string
	// ManagedHomes are ready managed-runtime home directories keyed by bound tool ID.
	ManagedHomes map[string][]string
	// ManagedTools maps a bound tool ID to the plugin ID that declares it in managedRuntimes.
	ManagedTools map[string]string
	// ManagedDependencies lists declared managedRuntimes dependencies that do not bind a tool.
	ManagedDependencies []ManagedDependency
}

// ManagedDependency is a plugin-declared managedRuntimes dependency that does
// not bind a toolDefinition, surfaced read-only under Plugin Runtimes so users
// can inspect its location, version and readiness, and prepare or repair it.
type ManagedDependency struct {
	PluginID   string
	PluginName string
	ID         string
	Version    string
	Home       string
	Ready      bool
}

// Selection is the validated installation one consumer operation may launch.
type Selection = core.ToolchainSelection

// Fixed is an explicit per-operation consumer choice.
type Fixed = core.ToolchainFixed

// Edit is one explicit directory-pin change from the settings draft. A nil Pin
// removes the tool's pin for the directory and leaves the automatic layers.
type Edit = core.ToolchainPinEdit
