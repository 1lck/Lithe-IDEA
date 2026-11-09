package core

import (
	"context"
	"encoding/json"
)

// ToolchainPlugin is one enabled plugin manifest as the toolchain registry
// expects it. Core revalidates the manifest; the host supplies no origin proof.
type ToolchainPlugin struct {
	Manifest json.RawMessage `json:"manifest"`
}

// ToolchainDefinitionEntry is one definition Core accepted for an enabled plugin.
type ToolchainDefinitionEntry struct {
	PluginID   string                  `json:"pluginID"`
	Definition ToolchainToolDefinition `json:"definition"`
}

// ToolchainProviderEntry is one provider Core accepted for an enabled plugin.
type ToolchainProviderEntry struct {
	PluginID string            `json:"pluginID"`
	Provider ToolchainProvider `json:"provider"`
}

// ToolchainProvider is a plugin backend that answers toolchain queries.
type ToolchainProvider struct {
	ID          string                  `json:"id"`
	DisplayName string                  `json:"displayName"`
	Tools       []string                `json:"tools"`
	WatchFiles  []ToolchainWatchPattern `json:"watchFiles,omitempty"`
}

// ToolchainWatchPattern is one input a provider watches.
type ToolchainWatchPattern struct {
	Pattern string `json:"pattern"`
	Reader  string `json:"reader"`
}

// ToolchainConflict lists a tool ID several plugins define. Core registers none
// of them, so no host decision may pick one of the plugins.
type ToolchainConflict struct {
	Tool      string   `json:"tool"`
	PluginIDs []string `json:"pluginIDs"`
}

// ToolchainRegistry is Core's validated view of the enabled plugin definitions.
type ToolchainRegistry struct {
	Definitions []ToolchainDefinitionEntry `json:"definitions"`
	Providers   []ToolchainProviderEntry   `json:"providers"`
	Conflicts   []ToolchainConflict        `json:"conflicts"`
}

// ToolchainToolDefinition is the part of a tool definition the host reads. Core
// remains the authority for validation and resolution.
type ToolchainToolDefinition struct {
	ID                string                      `json:"id"`
	DisplayName       string                      `json:"displayName"`
	ExecutableLayouts []ToolchainExecutableLayout `json:"executableLayouts"`
	Executables       []ToolchainExecutable       `json:"executables"`
	Version           ToolchainVersionRule        `json:"version"`
	HomeLayouts       []ToolchainHomeLayout       `json:"homeLayouts,omitempty"`
	Discovery         []ToolchainDiscoveryScan    `json:"discovery,omitempty"`
	HomeVariable      string                      `json:"homeVariable,omitempty"`
	Commands          []string                    `json:"commands"`
	Wrappers          []ToolchainWrapper          `json:"wrappers,omitempty"`
	Exports           []ToolchainExport           `json:"exports,omitempty"`
	PathPrepend       []string                    `json:"pathPrepend,omitempty"`
	Launch            []string                    `json:"launch"`
}

// ToolchainExecutableLayout is one platform-specific program under a home.
type ToolchainExecutableLayout struct {
	Path      string   `json:"path"`
	Platforms []string `json:"platforms,omitempty"`
}

// ToolchainExecutable is one resolver candidate a definition declares.
type ToolchainExecutable struct {
	Kind      string   `json:"kind"`
	ID        string   `json:"id,omitempty"`
	SettingID string   `json:"settingID,omitempty"`
	Layer     string   `json:"layer,omitempty"`
	Scope     string   `json:"scope,omitempty"`
	Variable  string   `json:"variable,omitempty"`
	Path      string   `json:"path,omitempty"`
	Command   string   `json:"command,omitempty"`
	Platforms []string `json:"platforms,omitempty"`
}

// ToolchainVersionRule extracts a comparable version from probe output.
type ToolchainVersionRule struct {
	Arguments []string `json:"arguments"`
	Pattern   string   `json:"pattern"`
}

// ToolchainHomeLayout maps a discovered directory name to the tool home below it.
type ToolchainHomeLayout struct {
	Match     string   `json:"match"`
	Home      string   `json:"home"`
	Platforms []string `json:"platforms,omitempty"`
}

// ToolchainDiscoveryScan is one declarative installation scan the host expands.
type ToolchainDiscoveryScan struct {
	Root      ToolchainDiscoveryRoot `json:"root"`
	Pattern   string                 `json:"pattern"`
	Platforms []string               `json:"platforms,omitempty"`
}

// ToolchainDiscoveryRoot is the fixed root a scan starts from.
type ToolchainDiscoveryRoot struct {
	Kind     string `json:"kind"`
	Variable string `json:"variable,omitempty"`
	Path     string `json:"path,omitempty"`
}

// ToolchainWrapper is one declared project wrapper the resolver may run.
type ToolchainWrapper struct {
	Path      string   `json:"path"`
	Requires  []string `json:"requires,omitempty"`
	Platforms []string `json:"platforms,omitempty"`
}

// ToolchainExport is one environment variable a selected installation exports.
type ToolchainExport struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

// ToolchainDiscoveryPlanTool is the declared scan and provider surface of one tool.
type ToolchainDiscoveryPlanTool struct {
	Tool              string                      `json:"tool"`
	PluginID          string                      `json:"pluginID"`
	Scans             []ToolchainDiscoveryScan    `json:"scans"`
	Providers         []string                    `json:"providers"`
	HomeLayouts       []ToolchainHomeLayout       `json:"homeLayouts"`
	ExecutableLayouts []ToolchainExecutableLayout `json:"executableLayouts"`
	Version           ToolchainVersionRule        `json:"version"`
	PathPrepend       []string                    `json:"pathPrepend"`
	Environment       []ToolchainEnvironmentHome  `json:"environment"`
}

// ToolchainEnvironmentHome is one login-shell home variable a definition reads.
type ToolchainEnvironmentHome struct {
	Variable string `json:"variable"`
	Path     string `json:"path,omitempty"`
}

// ToolchainDiscoveryPlan is every declaration the host may expand, never a scan.
type ToolchainDiscoveryPlan struct {
	Tools  []ToolchainDiscoveryPlanTool `json:"tools"`
	Limits struct {
		Roots     int `json:"roots"`
		Entries   int `json:"entries"`
		Ancestors int `json:"ancestors"`
	} `json:"limits"`
}

// ToolchainFileFact is native filesystem evidence the host observed. Providers
// never populate this.
type ToolchainFileFact struct {
	Path          string `json:"path"`
	CanonicalPath string `json:"canonicalPath"`
	Kind          string `json:"kind"`
	Executable    bool   `json:"executable,omitempty"`
}

// ToolchainProbe is one host-observed version probe.
type ToolchainProbe struct {
	Executable string `json:"executable"`
	Output     string `json:"output"`
	ExitCode   int    `json:"exitCode"`
}

// ToolchainSystemInstallation is one home a declarative scan found.
type ToolchainSystemInstallation struct {
	Tool string `json:"tool"`
	Home string `json:"home"`
}

// ToolchainProviderInstallation is one home a decoded provider reply reported.
type ToolchainProviderInstallation struct {
	Tool     string `json:"tool"`
	Home     string `json:"home"`
	Provider string `json:"provider"`
}

// ToolchainFixed is one explicit consumer choice for a single operation.
type ToolchainFixed struct {
	Home       string `json:"home,omitempty"`
	Executable string `json:"executable,omitempty"`
}

// ToolchainCandidatesRequest is one toolchains.candidates input.
type ToolchainCandidatesRequest struct {
	Registry                json.RawMessage                 `json:"registry"`
	Tool                    string                          `json:"tool"`
	Platform                string                          `json:"platform"`
	FilesystemCaseSensitive *bool                           `json:"filesystemCaseSensitive,omitempty"`
	WorkspaceRoot           string                          `json:"workspaceRoot"`
	WorkspaceRoots          []string                        `json:"workspaceRoots,omitempty"`
	Filesystem              []ToolchainFileFact             `json:"filesystem"`
	MinimumVersion          string                          `json:"minimumVersion,omitempty"`
	Probes                  []ToolchainProbe                `json:"probes,omitempty"`
	SystemInstallations     []ToolchainSystemInstallation   `json:"systemInstallations,omitempty"`
	ProviderInstallations   []ToolchainProviderInstallation `json:"providerInstallations,omitempty"`
	Environment             map[string]string               `json:"environment,omitempty"`
	Fixed                   *ToolchainFixed                 `json:"fixed,omitempty"`
	ProjectCodeAllowed      bool                            `json:"projectCodeAllowed,omitempty"`
}

// ToolchainShellCandidate is one login-shell home variable candidate.
type ToolchainShellCandidate struct {
	CandidateID string  `json:"candidateID"`
	Variable    string  `json:"variable"`
	Home        string  `json:"home"`
	Executable  string  `json:"executable,omitempty"`
	Version     *string `json:"version,omitempty"`
	Reason      string  `json:"reason,omitempty"`
}

// ToolchainInstallation is one checked installation in the automatic layer.
type ToolchainInstallation struct {
	Home       string `json:"home"`
	Executable string `json:"executable"`
	Version    string `json:"version"`
	Provider   string `json:"provider"`
}

// ToolchainSkippedInstallation is one reported installation Core refused or
// could not version-check.
type ToolchainSkippedInstallation struct {
	Home       string `json:"home,omitempty"`
	Provider   string `json:"provider,omitempty"`
	Executable string `json:"executable,omitempty"`
	Reason     string `json:"reason"`
}

// ToolchainCandidates is what a settings page shows for one tool.
type ToolchainCandidates struct {
	Tool          string                         `json:"tool"`
	Shell         []ToolchainShellCandidate      `json:"shell"`
	Installations []ToolchainInstallation        `json:"installations"`
	Skipped       []ToolchainSkippedInstallation `json:"skipped"`
	Selected      *string                        `json:"selected"`
	Conflicts     []json.RawMessage              `json:"conflicts"`
}

// ToolchainQuery is one decoded provider reply the resolver accepts.
type ToolchainQuery struct {
	Registry                json.RawMessage     `json:"registry"`
	PluginID                string              `json:"pluginID"`
	Request                 json.RawMessage     `json:"request"`
	Response                json.RawMessage     `json:"response"`
	CurrentGeneration       uint64              `json:"currentGeneration"`
	Filesystem              []ToolchainFileFact `json:"filesystem"`
	Platform                string              `json:"platform"`
	FilesystemCaseSensitive *bool               `json:"filesystemCaseSensitive,omitempty"`
	WorkspaceRoots          []string            `json:"workspaceRoots,omitempty"`
}

// ToolchainResolveRequest is one toolchains.resolve input.
type ToolchainResolveRequest struct {
	Registry                json.RawMessage               `json:"registry"`
	Tool                    string                        `json:"tool"`
	Directory               string                        `json:"directory"`
	OperationID             string                        `json:"operationID"`
	Local                   json.RawMessage               `json:"local,omitempty"`
	Platform                string                        `json:"platform"`
	FilesystemCaseSensitive *bool                         `json:"filesystemCaseSensitive,omitempty"`
	WorkspaceRoot           string                        `json:"workspaceRoot"`
	WorkspaceRoots          []string                      `json:"workspaceRoots,omitempty"`
	Filesystem              []ToolchainFileFact           `json:"filesystem"`
	MinimumVersion          string                        `json:"minimumVersion,omitempty"`
	Probes                  []ToolchainProbe              `json:"probes,omitempty"`
	Queries                 []ToolchainQuery              `json:"queries,omitempty"`
	SystemInstallations     []ToolchainSystemInstallation `json:"systemInstallations,omitempty"`
	GlobalDefault           *ToolchainGlobalDefault       `json:"globalDefault,omitempty"`
	Environment             map[string]string             `json:"environment,omitempty"`
	CommandHomes            map[string]string             `json:"commandHomes,omitempty"`
	ProjectCodeAllowed      bool                          `json:"projectCodeAllowed,omitempty"`
	ProviderChoices         map[string]string             `json:"providerChoices,omitempty"`
	Generation              uint64                        `json:"generation"`
	Context                 json.RawMessage               `json:"context,omitempty"`
	Fixed                   *ToolchainFixed               `json:"fixed,omitempty"`
}

// ToolchainGlobalDefault is an application-wide installation Core may select.
type ToolchainGlobalDefault struct {
	Home string `json:"home"`
}

// ToolchainSelection is one resolved installation and its process environment.
type ToolchainSelection struct {
	Home        *string           `json:"home"`
	Executable  string            `json:"executable"`
	Version     string            `json:"version"`
	Provider    string            `json:"provider"`
	Layer       string            `json:"layer"`
	ProjectCode bool              `json:"projectCode"`
	Environment map[string]string `json:"environment"`
	PathPrepend []string          `json:"pathPrepend"`
}

// ToolchainReason is a stable resolution failure.
type ToolchainReason struct {
	Code     string `json:"code"`
	Tool     string `json:"tool"`
	Provider string `json:"provider,omitempty"`
	Source   string `json:"source,omitempty"`
	Request  string `json:"request,omitempty"`
}

// ToolchainOutcome is the selected installation or the reason none applies.
type ToolchainOutcome struct {
	Kind      string              `json:"kind"`
	Selection *ToolchainSelection `json:"selection,omitempty"`
	Reason    *ToolchainReason    `json:"reason,omitempty"`
}

// ToolchainResolutionTrace is one candidate the resolver considered.
type ToolchainResolutionTrace struct {
	CandidateID string           `json:"candidateID"`
	Layer       string           `json:"layer"`
	State       string           `json:"state"`
	Reason      *ToolchainReason `json:"reason,omitempty"`
}

// ToolchainResolution is the complete, deterministic resolution of one tool.
type ToolchainResolution struct {
	OperationID string                     `json:"operationID"`
	Tool        string                     `json:"tool"`
	Directory   string                     `json:"directory"`
	Outcome     ToolchainOutcome           `json:"outcome"`
	Trace       []ToolchainResolutionTrace `json:"trace"`
	Unmet       []json.RawMessage          `json:"unmet"`
	Conflicts   []json.RawMessage          `json:"conflicts"`
}

// ToolchainPin is one saved directory installation reference.
type ToolchainPin struct {
	Home     string `json:"home"`
	Version  string `json:"version"`
	Provider string `json:"provider"`
}

// ToolchainPinResolution is the nearest saved pin for a directory and tool.
type ToolchainPinResolution struct {
	Pin             *ToolchainPin `json:"pin"`
	SourceDirectory *string       `json:"sourceDirectory"`
}

// ToolchainVersion is Core's decision on one probe output.
type ToolchainVersion struct {
	Satisfied bool    `json:"satisfied"`
	Version   *string `json:"version"`
}

type toolchainOutcome struct {
	Status      string                  `json:"status"`
	Error       *MarketplaceRejection   `json:"error"`
	Registry    *ToolchainRegistry      `json:"registry"`
	Plan        *ToolchainDiscoveryPlan `json:"plan"`
	Candidates  *ToolchainCandidates    `json:"candidates"`
	Resolution  json.RawMessage         `json:"resolution"`
	Snapshot    json.RawMessage         `json:"snapshot"`
	Reply       json.RawMessage         `json:"reply"`
	Version     *ToolchainVersion       `json:"version"`
	Preferences json.RawMessage         `json:"preferences"`
	Edit        json.RawMessage         `json:"edit"`
}

func (o toolchainOutcome) failure(command string) error {
	if o.Status == "rejected" && o.Error != nil {
		return o.Error
	}
	if o.Status != "ok" {
		return newParseError(command, "toolchain command returned an invalid outcome", "")
	}
	return nil
}

// ToolchainRegistryOf asks Core to register every enabled plugin's tool
// definitions and providers. Conflicts are reported rather than resolved.
func (c *Client) ToolchainRegistryOf(ctx context.Context, manifests []json.RawMessage) (ToolchainRegistry, error) {
	const command = "toolchains.registry"
	plugins := make([]ToolchainPlugin, 0, len(manifests))
	for _, manifest := range manifests {
		plugins = append(plugins, ToolchainPlugin{Manifest: manifest})
	}
	var result toolchainOutcome
	if err := c.Execute(ctx, command, struct {
		Plugins []ToolchainPlugin `json:"plugins"`
	}{plugins}, &result); err != nil {
		return ToolchainRegistry{}, err
	}
	if err := result.failure(command); err != nil {
		return ToolchainRegistry{}, err
	}
	if result.Registry == nil {
		return ToolchainRegistry{}, newParseError(command, "toolchains.registry returned no registry", "")
	}
	return *result.Registry, nil
}

// ToolchainDiscoveryPlanOf lists the declarative scans and provider identities
// per tool. It performs no native I/O.
func (c *Client) ToolchainDiscoveryPlanOf(ctx context.Context, registry json.RawMessage, platform string) (ToolchainDiscoveryPlan, error) {
	const command = "toolchains.discoveryPlan"
	var result toolchainOutcome
	if err := c.Execute(ctx, command, struct {
		Registry json.RawMessage `json:"registry"`
		Platform string          `json:"platform"`
	}{registry, platform}, &result); err != nil {
		return ToolchainDiscoveryPlan{}, err
	}
	if err := result.failure(command); err != nil {
		return ToolchainDiscoveryPlan{}, err
	}
	if result.Plan == nil {
		return ToolchainDiscoveryPlan{}, newParseError(command, "toolchains.discoveryPlan returned no plan", "")
	}
	return *result.Plan, nil
}

// ToolchainCandidatesOf lists checked installations and the automatic choice
// for one tool from host-supplied native facts.
func (c *Client) ToolchainCandidatesOf(ctx context.Context, request ToolchainCandidatesRequest) (ToolchainCandidates, error) {
	const command = "toolchains.candidates"
	var result toolchainOutcome
	if err := c.Execute(ctx, command, request, &result); err != nil {
		return ToolchainCandidates{}, err
	}
	if err := result.failure(command); err != nil {
		return ToolchainCandidates{}, err
	}
	if result.Candidates == nil {
		return ToolchainCandidates{}, newParseError(command, "toolchains.candidates returned no candidates", "")
	}
	return *result.Candidates, nil
}

// ResolveToolchain selects one installation through the fixed four layers.
func (c *Client) ResolveToolchain(ctx context.Context, request ToolchainResolveRequest) (ToolchainResolution, error) {
	const command = "toolchains.resolve"
	var result toolchainOutcome
	if err := c.Execute(ctx, command, request, &result); err != nil {
		return ToolchainResolution{}, err
	}
	if err := result.failure(command); err != nil {
		return ToolchainResolution{}, err
	}
	if len(result.Resolution) == 0 {
		return ToolchainResolution{}, newParseError(command, "toolchains.resolve returned no resolution", "")
	}
	var resolution ToolchainResolution
	if err := json.Unmarshal(result.Resolution, &resolution); err != nil {
		return ToolchainResolution{}, newParseError(command, "toolchains.resolve returned an invalid resolution", err.Error())
	}
	return resolution, nil
}

// ResolveToolchainPins finds the nearest directory pin without native I/O.
func (c *Client) ResolveToolchainPins(ctx context.Context, document json.RawMessage, directory, tool string) (ToolchainPinResolution, error) {
	const command = "toolchains.resolvePins"
	var result toolchainOutcome
	if err := c.Execute(ctx, command, struct {
		Document  json.RawMessage `json:"document"`
		Directory string          `json:"directory"`
		Tool      string          `json:"tool"`
	}{document, directory, tool}, &result); err != nil {
		return ToolchainPinResolution{}, err
	}
	if err := result.failure(command); err != nil {
		return ToolchainPinResolution{}, err
	}
	if len(result.Resolution) == 0 {
		return ToolchainPinResolution{}, newParseError(command, "toolchains.resolvePins returned no resolution", "")
	}
	var resolution ToolchainPinResolution
	if err := json.Unmarshal(result.Resolution, &resolution); err != nil {
		return ToolchainPinResolution{}, newParseError(command, "toolchains.resolvePins returned an invalid resolution", err.Error())
	}
	return resolution, nil
}

// CheckToolchainVersion compares one probe output with a definition's rule.
func (c *Client) CheckToolchainVersion(ctx context.Context, registry json.RawMessage, tool, output, minimumVersion string) (ToolchainVersion, error) {
	const command = "toolchains.checkVersion"
	var result toolchainOutcome
	if err := c.Execute(ctx, command, struct {
		Registry       json.RawMessage `json:"registry"`
		Tool           string          `json:"tool"`
		Output         string          `json:"output"`
		MinimumVersion string          `json:"minimumVersion,omitempty"`
	}{registry, tool, output, minimumVersion}, &result); err != nil {
		return ToolchainVersion{}, err
	}
	if err := result.failure(command); err != nil {
		return ToolchainVersion{}, err
	}
	if result.Version == nil {
		return ToolchainVersion{}, newParseError(command, "toolchains.checkVersion returned no version", "")
	}
	return *result.Version, nil
}

// ToolchainLaunch is one expanded tool definition launch template.
type ToolchainLaunch struct {
	Executable       string   `json:"executable"`
	Arguments        []string `json:"arguments"`
	VersionArguments []string `json:"versionArguments"`
}

// InstantiateToolchainLaunch expands a definition's launch template for one
// selected executable. The host never writes a tool's argv itself.
func (c *Client) InstantiateToolchainLaunch(ctx context.Context, registry json.RawMessage, tool, executable, home string, runtimeArguments, arguments []string) (ToolchainLaunch, error) {
	const command = "toolchains.instantiateLaunch"
	var result struct {
		Status string                `json:"status"`
		Error  *MarketplaceRejection `json:"error"`
		Launch *ToolchainLaunch      `json:"launch"`
	}
	payload := struct {
		Registry         json.RawMessage `json:"registry"`
		Tool             string          `json:"tool"`
		Executable       string          `json:"executable"`
		Home             string          `json:"home,omitempty"`
		RuntimeArguments []string        `json:"runtimeArguments,omitempty"`
		Arguments        []string        `json:"arguments,omitempty"`
	}{registry, tool, executable, home, runtimeArguments, arguments}
	if err := c.Execute(ctx, command, payload, &result); err != nil {
		return ToolchainLaunch{}, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return ToolchainLaunch{}, result.Error
	}
	if result.Status != "ok" || result.Launch == nil {
		return ToolchainLaunch{}, newParseError(command, "toolchains.instantiateLaunch returned no launch", "")
	}
	return *result.Launch, nil
}

// ToolchainPinEdit changes one directory override; nil removes it.
type ToolchainPinEdit struct {
	Tool string        `json:"tool"`
	Pin  *ToolchainPin `json:"pin"`
}

// EditToolchainPins delegates document validation and batch editing to Core.
func (c *Client) EditToolchainPins(ctx context.Context, document json.RawMessage, directory string, edits []ToolchainPinEdit) (json.RawMessage, error) {
	const command = "toolchains.editPins"
	var result struct {
		Status string                `json:"status"`
		Error  *MarketplaceRejection `json:"error"`
		Edit   *struct {
			Document json.RawMessage `json:"document"`
		} `json:"edit"`
	}
	if err := c.Execute(ctx, command, struct {
		Document  json.RawMessage    `json:"document"`
		Directory string             `json:"directory"`
		Edits     []ToolchainPinEdit `json:"edits"`
	}{document, directory, edits}, &result); err != nil {
		return nil, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return nil, result.Error
	}
	if result.Status != "ok" || result.Edit == nil || len(result.Edit.Document) == 0 {
		return nil, newParseError(command, "toolchains.editPins returned no document", "")
	}
	return result.Edit.Document, nil
}
