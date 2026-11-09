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
}

// ErrPinConflict reports that the pin document changed after it was read. The
// caller must keep its draft and show the conflict rather than overwrite it.
var ErrPinConflict = errors.New("toolchain: the local toolchain document changed since it was read")

// DefaultDocument is the empty local toolchain document. Reading a project that
// has none must not create one.
var DefaultDocument = []byte(`{"version":1,"toolchains":{}}`)

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
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	PluginID    string `json:"pluginID"`
	// Providers are the qualified provider IDs that declared this tool. Their
	// answers are not queried by this client yet, so the view states it.
	Providers []string `json:"providers"`

	Pin       *core.ToolchainPin `json:"pin,omitempty"`
	PinSource string             `json:"pinSource,omitempty"`

	Shell         []core.ToolchainShellCandidate      `json:"shell"`
	Installations []core.ToolchainInstallation        `json:"installations"`
	Skipped       []core.ToolchainSkippedInstallation `json:"skipped"`
	AutomaticHome string                              `json:"automaticHome,omitempty"`

	Effective *core.ToolchainSelection        `json:"effective,omitempty"`
	Trace     []core.ToolchainResolutionTrace `json:"trace"`
	Unmet     []json.RawMessage               `json:"unmet"`
	Conflicts []json.RawMessage               `json:"conflicts"`
	// Hidden lists provider declarations the host cannot query yet, so the
	// settings page says the tool may have more installations than shown.
	ProviderQueriesUnsupported bool `json:"providerQueriesUnsupported"`
}

// Snapshot is everything one settings load read for one project directory.
type Snapshot struct {
	Root      string                   `json:"root"`
	Directory string                   `json:"directory"`
	Tools     []Tool                   `json:"tools"`
	Conflicts []core.ToolchainConflict `json:"conflicts"`
	// Baseline is the exact bytes of .lithe/toolchains/local.json that the
	// snapshot was built from, nil when the file did not exist.
	Baseline []byte `json:"-"`
}

// Options configure one load. The zero value uses the host platform, the user's
// home, the process environment and a bounded native probe.
type Options struct {
	Platform    string
	Home        string
	Environment map[string]string
	Probe       ProbeFunc
	Lookup      LookupFunc
	// MinimumVersion is a consumer requirement for one operation; settings
	// loads leave it empty.
	MinimumVersion string
}

// Selection is the validated installation one consumer operation may launch.
type Selection = core.ToolchainSelection

// Fixed is an explicit per-operation consumer choice.
type Fixed = core.ToolchainFixed

// Edit is one explicit directory-pin change from the settings draft. A nil Pin
// removes the tool's pin for the directory and leaves the automatic layers.
type Edit = core.ToolchainPinEdit
