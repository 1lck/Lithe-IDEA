package toolchain

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"sync/atomic"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// loadSequence makes every operation ID unique across concurrent loads and
// run-time resolutions. Core keeps a process-wide cancellation registry.
var loadSequence atomic.Uint64

// UnavailableError reports that Core refused to select an installation. Code is
// a stable Core reason; callers localize it rather than parsing the text.
type UnavailableError struct {
	Tool string
	Code string
}

func (e *UnavailableError) Error() string {
	return fmt.Sprintf("toolchain %s is unavailable: %s", e.Tool, e.Code)
}

// rawRegistry is the request shape every registry input expects. Core treats it
// as inert data and revalidates the complete manifests.
func rawRegistry(manifests []json.RawMessage) (json.RawMessage, error) {
	type plugin struct {
		Manifest json.RawMessage `json:"manifest"`
	}
	plugins := make([]plugin, 0, len(manifests))
	for _, manifest := range manifests {
		plugins = append(plugins, plugin{Manifest: manifest})
	}
	return json.Marshal(struct {
		Plugins []plugin `json:"plugins"`
	}{plugins})
}

// Load reads one project directory: declared scans, native evidence, bounded
// probes, Core's candidate report and the effective layer for every definition.
// It writes nothing.
func Load(ctx context.Context, kernel Kernel, root, directory string, manifests []json.RawMessage, options Options) (Snapshot, error) {
	if kernel == nil {
		return Snapshot{}, fmt.Errorf("toolchain: no Core client")
	}
	workspace, err := newWorkspace(root, options)
	if err != nil {
		return Snapshot{}, err
	}
	rootIdentity, err := directoryIdentity(ctx, workspace.root)
	if err != nil {
		return Snapshot{}, err
	}
	registryRequest, err := rawRegistry(manifests)
	if err != nil {
		return Snapshot{}, err
	}
	registry, err := kernel.ToolchainRegistryOf(ctx, manifests)
	if err != nil {
		return Snapshot{}, err
	}
	plan, err := kernel.ToolchainDiscoveryPlanOf(ctx, registryRequest, workspace.platform)
	if err != nil {
		return Snapshot{}, err
	}
	definitions := make(map[string]core.ToolchainToolDefinition, len(registry.Definitions))
	for _, entry := range registry.Definitions {
		definitions[entry.Definition.ID] = entry.Definition
	}
	document, baseline, err := readDocument(workspace.root)
	if err != nil {
		return Snapshot{}, err
	}
	snapshot := Snapshot{
		Root:         workspace.root,
		rootIdentity: rootIdentity,
		Directory:    directory,
		Conflicts:    registry.Conflicts,
		Baseline:     baseline,
	}
	sequence := loadSequence.Add(1)
	for index, planned := range plan.Tools {
		if ctx.Err() != nil {
			return Snapshot{}, ctx.Err()
		}
		definition, ok := definitions[planned.Tool]
		if !ok {
			continue
		}
		prepared, pin, source, err := prepareTool(ctx, kernel, workspace, registryRequest, document, planned, definition, directory, options, nil)
		if err != nil {
			return Snapshot{}, err
		}
		resolution, err := resolveTool(ctx, kernel, workspace, registryRequest, prepared, document, directory,
			options.MinimumVersion, fmt.Sprintf("settings-%d-%d", sequence, index))
		if err != nil {
			return Snapshot{}, err
		}
		tool := Tool{
			ID:                         planned.Tool,
			DisplayName:                definition.DisplayName,
			PluginID:                   planned.PluginID,
			Providers:                  planned.Providers,
			Shell:                      prepared.candidates.Shell,
			Installations:              prepared.candidates.Installations,
			Skipped:                    prepared.candidates.Skipped,
			Trace:                      resolution.Trace,
			Unmet:                      resolution.Unmet,
			Conflicts:                  resolution.Conflicts,
			ProviderQueriesUnsupported: len(planned.Providers) > 0,
		}
		if pin != nil {
			tool.Pin = pin
			tool.PinSource = source
		}
		if prepared.candidates.Selected != nil {
			tool.AutomaticHome = *prepared.candidates.Selected
		}
		if resolution.Outcome.Kind == "resolved" {
			tool.Effective = resolution.Outcome.Selection
		}
		snapshot.Tools = append(snapshot.Tools, tool)
	}
	return snapshot, nil
}

// Resolve selects one installation for one consumer operation. It reads the same
// facts and Core entry points as the settings page, so a displayed value and a
// launched executable cannot come from two rule sets.
func Resolve(ctx context.Context, kernel Kernel, root, directory, tool, minimumVersion string, fixed *Fixed, manifests []json.RawMessage, options Options) (Selection, error) {
	if kernel == nil {
		return Selection{}, fmt.Errorf("toolchain: no Core client")
	}
	workspace, err := newWorkspace(root, options)
	if err != nil {
		return Selection{}, err
	}
	registryRequest, err := rawRegistry(manifests)
	if err != nil {
		return Selection{}, err
	}
	registry, err := kernel.ToolchainRegistryOf(ctx, manifests)
	if err != nil {
		return Selection{}, err
	}
	plan, err := kernel.ToolchainDiscoveryPlanOf(ctx, registryRequest, workspace.platform)
	if err != nil {
		return Selection{}, err
	}
	definitions := make(map[string]core.ToolchainToolDefinition, len(registry.Definitions))
	for _, entry := range registry.Definitions {
		definitions[entry.Definition.ID] = entry.Definition
	}
	document, _, err := readDocument(workspace.root)
	if err != nil {
		return Selection{}, err
	}
	for _, planned := range plan.Tools {
		if planned.Tool != tool {
			continue
		}
		definition, ok := definitions[tool]
		if !ok {
			continue
		}
		prepared, _, _, err := prepareTool(ctx, kernel, workspace, registryRequest, document, planned, definition, directory, options, fixed)
		if err != nil {
			return Selection{}, err
		}
		resolution, err := resolveTool(ctx, kernel, workspace, registryRequest, prepared, document, directory, minimumVersion,
			fmt.Sprintf("run-%d", loadSequence.Add(1)))
		if err != nil {
			return Selection{}, err
		}
		if resolution.Outcome.Kind != "resolved" || resolution.Outcome.Selection == nil {
			code := "notFound"
			if resolution.Outcome.Reason != nil && resolution.Outcome.Reason.Code != "" {
				code = resolution.Outcome.Reason.Code
			}
			return Selection{}, &UnavailableError{Tool: tool, Code: code}
		}
		return *resolution.Outcome.Selection, nil
	}
	return Selection{}, &UnavailableError{Tool: tool, Code: "definitionUnavailable"}
}

type preparedTool struct {
	definition    core.ToolchainToolDefinition
	candidates    core.ToolchainCandidates
	facts         []core.ToolchainFileFact
	probes        []core.ToolchainProbe
	installations []core.ToolchainSystemInstallation
	environment   map[string]string
	commandHomes  map[string]string
	fixed         *Fixed
}

// prepareTool performs the declared native reads for one tool. Core only sees
// facts this function observed; a probe is run only for executables Core would
// otherwise consider.
func prepareTool(ctx context.Context, kernel Kernel, workspace *workspace, registry json.RawMessage, document json.RawMessage, planned core.ToolchainDiscoveryPlanTool, definition core.ToolchainToolDefinition, directory string, options Options, fixed *Fixed) (preparedTool, *core.ToolchainPin, string, error) {
	prepared := preparedTool{definition: definition, fixed: fixed}
	pinResolution, err := kernel.ResolveToolchainPins(ctx, document, directory, planned.Tool)
	if err != nil {
		return prepared, nil, "", err
	}
	homes, err := workspace.expandScans(planned)
	if err != nil {
		return prepared, nil, "", err
	}
	for _, home := range homes {
		prepared.installations = append(prepared.installations, core.ToolchainSystemInstallation{Tool: planned.Tool, Home: home})
	}
	prepared.environment = declaredEnvironment(planned, workspace.environment)
	// Every home whose executable Core may select has to be in the evidence set,
	// including a stored pin and a per-operation fixed choice.
	// Both the lexical spelling a user configured and its canonical target are
	// evidence: Core resolves the lexical home through the facts, then checks the
	// canonical executable and home.
	evidenceHomes := append([]string(nil), homes...)
	for _, variable := range planned.Environment {
		value := workspace.environment[variable.Variable]
		if value == "" || !filepath.IsAbs(value) {
			continue
		}
		canonical, err := canonicalPath(value)
		if err != nil || workspace.insideRoot(canonical) {
			continue
		}
		evidenceHomes = append(evidenceHomes, value, canonical)
	}
	var pin *core.ToolchainPin
	if pinResolution.Pin != nil {
		pin = pinResolution.Pin
		evidenceHomes = append(evidenceHomes, pin.Home)
		if home, err := canonicalPath(pin.Home); err == nil {
			evidenceHomes = append(evidenceHomes, home)
		}
	}
	if prepared.fixed != nil && prepared.fixed.Home != "" {
		evidenceHomes = append(evidenceHomes, prepared.fixed.Home)
		if home, err := canonicalPath(prepared.fixed.Home); err == nil {
			evidenceHomes = append(evidenceHomes, home)
		}
	}
	workspace.observe(workspace.root)
	prepared.commandHomes = commandHomes(workspace, definition)
	for _, home := range uniqueSorted(evidenceHomes) {
		workspace.observe(home)
		for _, layout := range definition.ExecutableLayouts {
			if !platformMatches(layout.Platforms, workspace.platform) {
				continue
			}
			workspace.observe(filepath.Join(home, filepath.FromSlash(layout.Path)))
		}
		for _, template := range definition.PathPrepend {
			if name, ok := prependPath(home, template); ok {
				workspace.observe(name)
			}
		}
	}
	for _, home := range uniqueSorted(valuesOf(prepared.commandHomes)) {
		workspace.observe(home)
		for _, layout := range definition.ExecutableLayouts {
			if !platformMatches(layout.Platforms, workspace.platform) {
				continue
			}
			workspace.observe(filepath.Join(home, filepath.FromSlash(layout.Path)))
		}
		for _, template := range definition.PathPrepend {
			if name, ok := prependPath(home, template); ok {
				workspace.observe(name)
			}
		}
	}
	if prepared.fixed != nil {
		workspace.observe(prepared.fixed.Executable)
	}
	prepared.facts = workspace.all()

	request := core.ToolchainCandidatesRequest{
		Registry:            registry,
		Tool:                planned.Tool,
		Platform:            workspace.platform,
		WorkspaceRoot:       workspace.root,
		Filesystem:          prepared.facts,
		MinimumVersion:      options.MinimumVersion,
		SystemInstallations: prepared.installations,
		Environment:         prepared.environment,
		Fixed:               prepared.fixed,
	}
	candidates, err := kernel.ToolchainCandidatesOf(ctx, request)
	if err != nil {
		return prepared, nil, "", err
	}
	var probeTargets []string
	for _, row := range candidates.Shell {
		if row.Executable != "" {
			probeTargets = append(probeTargets, row.Executable)
		}
	}
	for _, row := range candidates.Skipped {
		if row.Executable != "" {
			probeTargets = append(probeTargets, row.Executable)
		}
	}
	if pin != nil {
		for _, home := range uniqueSorted(evidenceHomes) {
			if executable := executablePath(home, definition.ExecutableLayouts, workspace.platform); executable != "" {
				probeTargets = append(probeTargets, executable)
			}
		}
	}
	if prepared.fixed != nil && prepared.fixed.Executable != "" {
		probeTargets = append(probeTargets, prepared.fixed.Executable)
	}
	for _, home := range uniqueSorted(valuesOf(prepared.commandHomes)) {
		if executable := executablePath(home, definition.ExecutableLayouts, workspace.platform); executable != "" {
			probeTargets = append(probeTargets, executable)
		}
	}
	prepared.probes = workspace.probeAll(ctx, definition, probeTargets)
	if ctx.Err() != nil {
		return prepared, nil, "", ctx.Err()
	}
	request.Probes = prepared.probes
	candidates, err = kernel.ToolchainCandidatesOf(ctx, request)
	if err != nil {
		return prepared, nil, "", err
	}
	prepared.candidates = candidates
	source := ""
	if pinResolution.SourceDirectory != nil {
		source = *pinResolution.SourceDirectory
	}
	return prepared, pin, source, nil
}

// resolveTool runs Core's four-layer resolution over the prepared evidence.
func resolveTool(ctx context.Context, kernel Kernel, workspace *workspace, registry json.RawMessage, prepared preparedTool, document json.RawMessage, directory, minimumVersion, operationID string) (core.ToolchainResolution, error) {
	request := core.ToolchainResolveRequest{
		Registry:            registry,
		Tool:                prepared.definition.ID,
		Directory:           directory,
		OperationID:         operationID,
		Local:               document,
		Platform:            workspace.platform,
		WorkspaceRoot:       workspace.root,
		Filesystem:          prepared.facts,
		MinimumVersion:      minimumVersion,
		Probes:              prepared.probes,
		SystemInstallations: prepared.installations,
		Environment:         prepared.environment,
		CommandHomes:        prepared.commandHomes,
		Generation:          loadSequence.Add(1),
		Fixed:               prepared.fixed,
	}
	return kernel.ResolveToolchain(ctx, request)
}

// declaredEnvironment passes only the home variables the definition declares.
// Other login-shell values never cross the Core boundary.
func declaredEnvironment(planned core.ToolchainDiscoveryPlanTool, environment map[string]string) map[string]string {
	values := make(map[string]string)
	for _, candidate := range planned.Environment {
		if value := environment[candidate.Variable]; value != "" {
			values[candidate.Variable] = value
		}
	}
	return values
}

// commandHomes maps each declared shell command to the installation home its
// found executable belongs to. Core owns the ordering; this only reports where
// the shell found the command.
func commandHomes(workspace *workspace, definition core.ToolchainToolDefinition) map[string]string {
	homes := make(map[string]string)
	for _, command := range definition.Commands {
		executable, err := workspace.lookup(command)
		if err != nil || executable == "" {
			continue
		}
		for _, layout := range definition.ExecutableLayouts {
			if !platformMatches(layout.Platforms, workspace.platform) {
				continue
			}
			suffix := string(filepath.Separator) + filepath.FromSlash(layout.Path)
			if !strings.HasSuffix(executable, suffix) {
				continue
			}
			home := strings.TrimSuffix(executable, suffix)
			if home == "" {
				continue
			}
			homes[command] = home
			break
		}
	}
	return homes
}

func valuesOf(values map[string]string) []string {
	result := make([]string, 0, len(values))
	for _, value := range values {
		result = append(result, value)
	}
	return result
}
