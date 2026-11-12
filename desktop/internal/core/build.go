package core

import (
	"context"
	"encoding/json"
)

// BuildInstance is one detected build-system instance. A provider-backed model
// is loaded later, so Model is nil until build.decodeModel succeeds.
type BuildInstance struct {
	ID                string                     `json:"id"`
	PluginID          string                     `json:"pluginID"`
	BuildSystemID     string                     `json:"buildSystemID"`
	DisplayName       string                     `json:"displayName"`
	Root              string                     `json:"root"`
	Markers           []string                   `json:"markers"`
	ModelSource       string                     `json:"modelSource"`
	Options           map[string]json.RawMessage `json:"options"`
	DroppedOptions    []string                   `json:"droppedOptions"`
	OptionFingerprint string                     `json:"optionFingerprint"`
	Model             json.RawMessage            `json:"model"`
	ModelError        *MarketplaceRejection      `json:"modelError"`
}

// BuildDetectionRejection reports one manifest build.detect could not validate.
type BuildDetectionRejection struct {
	Index int                  `json:"index"`
	Error MarketplaceRejection `json:"error"`
}

// BuildShadowed reports a lower-priority declaration hidden by another plugin.
type BuildShadowed struct {
	PluginID      string `json:"pluginID"`
	BuildSystemID string `json:"buildSystemID"`
	By            string `json:"by"`
}

// BuildDetection is Core's complete answer to build.detect. Invalid manifests
// are reported per entry rather than failing the whole detection.
type BuildDetection struct {
	Instances []BuildInstance           `json:"instances"`
	Rejected  []BuildDetectionRejection `json:"rejected"`
	Shadowed  []BuildShadowed           `json:"shadowed"`
}

// BuildSelection is one project, target, or model task selected from a decoded
// model. Paths are workspace-relative with forward slashes.
type BuildSelection struct {
	Name       string            `json:"name"`
	Path       string            `json:"path,omitempty"`
	Tags       []string          `json:"tags,omitempty"`
	Execution  string            `json:"execution,omitempty"`
	Properties map[string]string `json:"properties,omitempty"`
}

// BuildExecutableCandidate is one ordered way to run a build system. The host
// checks candidates in order; Core owns the order and the platform filter.
type BuildExecutableCandidate struct {
	Kind        string   `json:"kind"`
	Command     string   `json:"command,omitempty"`
	Path        string   `json:"path,omitempty"`
	Variable    string   `json:"variable,omitempty"`
	Runtime     string   `json:"runtime,omitempty"`
	ToolchainID string   `json:"toolchainID,omitempty"`
	Root        string   `json:"root,omitempty"`
	SettingID   string   `json:"settingID,omitempty"`
	Requires    []string `json:"requires,omitempty"`
}

// BuildRuntimeRequirement is a runtime the build tool needs, with the probe
// Core expects the host to run when it must check the version.
type BuildRuntimeRequirement struct {
	ID             string                     `json:"id"`
	DisplayName    string                     `json:"displayName"`
	HostManaged    bool                       `json:"hostManaged"`
	MinimumVersion string                     `json:"minimumVersion,omitempty"`
	Executables    []BuildExecutableCandidate `json:"executables"`
	Version        *BuildVersionProbe         `json:"version,omitempty"`
}

// BuildVersionProbe is the argv a version check runs.
type BuildVersionProbe struct {
	Arguments []string `json:"arguments"`
}

// BuildToolVersion is Core's decision on a version probe.
type BuildToolVersion struct {
	Satisfied bool   `json:"satisfied"`
	Version   string `json:"version,omitempty"`
}

// BuildInvocation is Core's ordered executable candidates for one build system.
type BuildInvocation struct {
	BuildSystemID       string                     `json:"buildSystemID"`
	Root                string                     `json:"root"`
	Executables         []BuildExecutableCandidate `json:"executables"`
	RuntimeDependencies []BuildRuntimeRequirement  `json:"runtimeDependencies"`
	Version             *BuildVersionProbe         `json:"version,omitempty"`
	MinimumVersion      string                     `json:"minimumVersion,omitempty"`
}

// BuildTool is the host-resolved build executable passed to a provider. Core
// validates that Executable is an absolute path; the host owns resolving it.
type BuildTool struct {
	Executable  string            `json:"executable"`
	Environment map[string]string `json:"environment,omitempty"`
}

// BuildPlanRequest is the common part of build.modelPlan, build.taskPlan, and
// build.prepareRunPlan. Optional fields stay out of the wire request when unset.
type BuildPlanRequest struct {
	Root                    string                     `json:"root"`
	Options                 map[string]json.RawMessage `json:"options,omitempty"`
	PluginDirectory         string                     `json:"pluginDirectory,omitempty"`
	WorkspaceStateDirectory string                     `json:"workspaceStateDirectory,omitempty"`
	Project                 *BuildSelection            `json:"project,omitempty"`
	Target                  *BuildSelection            `json:"target,omitempty"`
	ModelTask               *BuildSelection            `json:"modelTask,omitempty"`
	Task                    string                     `json:"task,omitempty"`
	Run                     string                     `json:"run,omitempty"`
	UserArguments           []string                   `json:"userArguments,omitempty"`
	OutputFile              string                     `json:"outputFile,omitempty"`
	Refresh                 bool                       `json:"refresh,omitempty"`
	Tool                    *BuildTool                 `json:"tool,omitempty"`
	WorkspaceRoot           string                     `json:"workspaceRoot,omitempty"`
	// LaunchOptions are a run configuration's choices (buildProviders 10).
	LaunchOptions *RunLaunchOptions `json:"launchOptions,omitempty"`
}

// BuildProviderRequest is the typed request a provider-backed plan names.
type BuildProviderRequest struct {
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

// BuildPlan is either a command plan or a provider request. A provider plan has
// no Arguments; the plugin owns the build semantics.
type BuildPlan struct {
	BuildSystemID       string                `json:"buildSystemID"`
	Root                string                `json:"root"`
	Arguments           []string              `json:"arguments"`
	Environment         map[string]string     `json:"environment"`
	WorkingDirectory    string                `json:"workingDirectory"`
	Execution           string                `json:"execution"`
	OptionFingerprint   string                `json:"optionFingerprint"`
	Output              string                `json:"output,omitempty"`
	Decoder             string                `json:"decoder,omitempty"`
	ExecutesProjectCode bool                  `json:"executesProjectCode,omitempty"`
	MayUseNetwork       bool                  `json:"mayUseNetwork,omitempty"`
	Provider            *BuildProviderRequest `json:"provider,omitempty"`
}

// BuildDecodeModelRequest decodes a static or command model, or the result a
// provider answered for lithe/build/model.
type BuildDecodeModelRequest struct {
	WorkspaceRoot string                     `json:"workspaceRoot"`
	Root          string                     `json:"root"`
	Output        string                     `json:"output,omitempty"`
	OutputFile    string                     `json:"outputFile,omitempty"`
	Result        json.RawMessage            `json:"result,omitempty"`
	Options       map[string]json.RawMessage `json:"options,omitempty"`
}

// BuildProject is one project a decoded build model contains.
type BuildProject struct {
	ID          string            `json:"id"`
	Path        string            `json:"path"`
	Name        string            `json:"name"`
	DisplayName string            `json:"displayName,omitempty"`
	ParentID    string            `json:"parentID,omitempty"`
	Properties  map[string]string `json:"properties"`
}

// BuildTarget is one target a decoded build model contains.
type BuildTarget struct {
	ID         string            `json:"id"`
	ProjectID  string            `json:"projectID"`
	Name       string            `json:"name"`
	Path       string            `json:"path"`
	Tags       []string          `json:"tags"`
	Properties map[string]string `json:"properties"`
}

// BuildTask is one model task a decoded build model contains.
type BuildTask struct {
	ID          string            `json:"id"`
	ProjectID   string            `json:"projectID"`
	Name        string            `json:"name"`
	Path        string            `json:"path"`
	DisplayName string            `json:"displayName,omitempty"`
	Description string            `json:"description,omitempty"`
	Template    string            `json:"template"`
	Group       string            `json:"group"`
	Category    []string          `json:"category,omitempty"`
	Execution   string            `json:"execution"`
	Properties  map[string]string `json:"properties"`
}

// BuildModel is the normalized model build.decodeModel returns. Run entries
// are command entries only; a provider run is prepared on demand.
type BuildModel struct {
	Projects     []BuildProject      `json:"projects"`
	Targets      []BuildTarget       `json:"targets"`
	Tasks        []BuildTask         `json:"tasks"`
	ContentRoots []json.RawMessage   `json:"contentRoots"`
	OptionValues map[string][]string `json:"optionValues"`
	Run          []json.RawMessage   `json:"run"`
}

// BuildExecutable is a validated launch executable reference: either a bare
// command the host resolves or a toolchain identifier the native Run host owns.
type BuildExecutable struct {
	Kind  string `json:"kind"`
	Value string `json:"value"`
}

// BuildLaunch is Core's validated portable application launch.
type BuildLaunch struct {
	Executable       BuildExecutable   `json:"executable"`
	Arguments        []string          `json:"arguments"`
	WorkingDirectory string            `json:"workingDirectory"`
	Environment      map[string]string `json:"environment"`
}

// BuildDecodeRunRequest validates the raw result of lithe/build/prepareRun.
type BuildDecodeRunRequest struct {
	WorkspaceRoot string          `json:"workspaceRoot"`
	Root          string          `json:"root"`
	Result        json.RawMessage `json:"result"`
	// LaunchOptions are the ones the preparation was asked with.
	LaunchOptions *RunLaunchOptions `json:"launchOptions,omitempty"`
}

type buildOutcome struct {
	Status     string                `json:"status"`
	Error      *MarketplaceRejection `json:"error"`
	Detection  *BuildDetection       `json:"detection"`
	Plan       *BuildPlan            `json:"plan"`
	Model      *BuildModel           `json:"model"`
	Launch     *BuildLaunch          `json:"launch"`
	Results    *BuildTestResults     `json:"results"`
	Invocation *BuildInvocation      `json:"invocation"`
	Version    *BuildToolVersion     `json:"version"`
	// Dependencies is the answer of build.decodeDependencies.
	Dependencies *BuildDependencyTree `json:"dependencies"`
	// Storage and Edit answer build.resolveStoredOptions and build.editStoredOption.
	Storage *BuildStoredOptions `json:"storage"`
	Edit    *BuildOptionEdit    `json:"edit"`
	// Discovery answers build.decodeTestDiscovery.
	Discovery *BuildTestDiscovery `json:"discovery"`
}

func (o buildOutcome) failure(command string) error {
	if o.Status == "rejected" && o.Error != nil {
		return o.Error
	}
	if o.Status != "ok" {
		return newParseError(command, "build command returned an invalid outcome", "")
	}
	return nil
}

// DetectBuildSystems asks Core for every build-system instance the enabled
// plugins declare in workspaceRoot. The manifests come from the installed,
// verified packages and are revalidated by Core.
func (c *Client) DetectBuildSystems(ctx context.Context, workspaceRoot string, manifests []json.RawMessage) (BuildDetection, error) {
	return c.DetectBuildSystemsWithOptions(ctx, workspaceRoot, manifests, BuildDetectOptions{})
}

// DetectBuildSystemsWithOptions is DetectBuildSystems with the stored option inputs of the workspace, so each
// instance carries the values Core accepted from them.
func (c *Client) DetectBuildSystemsWithOptions(ctx context.Context, workspaceRoot string, manifests []json.RawMessage, options BuildDetectOptions) (BuildDetection, error) {
	const command = "build.detect"
	type plugin struct {
		Manifest json.RawMessage `json:"manifest"`
	}
	plugins := make([]plugin, 0, len(manifests))
	for _, manifest := range manifests {
		plugins = append(plugins, plugin{Manifest: manifest})
	}
	var result buildOutcome
	if err := c.Execute(ctx, command, struct {
		WorkspaceRoot    string                                           `json:"workspaceRoot"`
		Plugins          []plugin                                         `json:"plugins"`
		Options          map[string]map[string]json.RawMessage            `json:"options,omitempty"`
		InstanceOptions  map[string]map[string]map[string]json.RawMessage `json:"instanceOptions,omitempty"`
		InstanceDefaults map[string]map[string]json.RawMessage            `json:"instanceDefaults,omitempty"`
		EmptySelections  map[string]map[string][]string                   `json:"emptySelections,omitempty"`
	}{workspaceRoot, plugins, options.Options, options.InstanceOptions, options.InstanceDefaults, options.EmptySelections}, &result); err != nil {
		return BuildDetection{}, err
	}
	if err := result.failure(command); err != nil {
		return BuildDetection{}, err
	}
	if result.Detection == nil {
		return BuildDetection{}, newParseError(command, "build.detect returned no detection", "")
	}
	return *result.Detection, nil
}

// BuildInvocationRequest supplies native facts and the actual global plugin layer.
// Core validates executable settings; project values cannot select local tools.
type BuildInvocationRequest struct {
	Root     string                     `json:"root"`
	Platform string                     `json:"platform"`
	Settings map[string]json.RawMessage `json:"settings,omitempty"`
}

// PlanBuildInvocation returns the ordered executable candidates Core chose for
// this platform. The host resolves them and must not invent another order.
func (c *Client) PlanBuildInvocation(ctx context.Context, manifest json.RawMessage, buildSystemID string, request BuildInvocationRequest) (BuildInvocation, error) {
	const command = "build.invocationPlan"
	var result buildOutcome
	if err := c.Execute(ctx, command, struct {
		Manifest      json.RawMessage        `json:"manifest"`
		BuildSystemID string                 `json:"buildSystemID"`
		Request       BuildInvocationRequest `json:"request"`
	}{manifest, buildSystemID, request}, &result); err != nil {
		return BuildInvocation{}, err
	}

	if err := result.failure(command); err != nil {
		return BuildInvocation{}, err
	}
	if result.Invocation == nil {
		return BuildInvocation{}, newParseError(command, "build invocation returned no plan", "")
	}
	return *result.Invocation, nil
}

// CheckBuildToolVersion compares one probe output with the declared minimum.
// runtime is empty for the build tool itself and names a runtime dependency
// otherwise.
func (c *Client) CheckBuildToolVersion(ctx context.Context, manifest json.RawMessage, buildSystemID, runtime, output string) (BuildToolVersion, error) {
	const command = "build.checkToolVersion"
	var result buildOutcome
	if err := c.Execute(ctx, command, struct {
		Manifest      json.RawMessage `json:"manifest"`
		BuildSystemID string          `json:"buildSystemID"`
		Request       struct {
			Runtime string `json:"runtime,omitempty"`
			Output  string `json:"output"`
		} `json:"request"`
	}{manifest, buildSystemID, struct {
		Runtime string `json:"runtime,omitempty"`
		Output  string `json:"output"`
	}{runtime, output}}, &result); err != nil {
		return BuildToolVersion{}, err
	}
	if err := result.failure(command); err != nil {
		return BuildToolVersion{}, err
	}
	if result.Version == nil {
		return BuildToolVersion{}, newParseError(command, "build version check returned no result", "")
	}
	return *result.Version, nil
}

// PlanBuildModel plans a command model or the request a provider answers.
func (c *Client) PlanBuildModel(ctx context.Context, manifest json.RawMessage, buildSystemID string, request BuildPlanRequest) (BuildPlan, error) {
	return c.planBuild(ctx, "build.modelPlan", manifest, buildSystemID, request)
}

// PlanBuildTask plans one declared or model task.
func (c *Client) PlanBuildTask(ctx context.Context, manifest json.RawMessage, buildSystemID string, request BuildPlanRequest) (BuildPlan, error) {
	return c.planBuild(ctx, "build.taskPlan", manifest, buildSystemID, request)
}

// PlanBuildRun prepares a provider-owned application, service, or task launch.
func (c *Client) PlanBuildRun(ctx context.Context, manifest json.RawMessage, buildSystemID string, request BuildPlanRequest) (BuildPlan, error) {
	return c.planBuild(ctx, "build.prepareRunPlan", manifest, buildSystemID, request)
}

// PlanBuildDebug prepares the native debug program a provider owns for one target, the
// request the Debug window makes before it starts a provider-prepared program. It answers
// the same plan envelope as PlanBuildRun, and the host reads the provider's debug program
// out of it.
func (c *Client) PlanBuildDebug(ctx context.Context, manifest json.RawMessage, buildSystemID string, request BuildPlanRequest) (BuildPlan, error) {
	return c.planBuild(ctx, "build.prepareDebugPlan", manifest, buildSystemID, request)
}

func (c *Client) planBuild(ctx context.Context, command string, manifest json.RawMessage, buildSystemID string, request BuildPlanRequest) (BuildPlan, error) {
	var result buildOutcome
	if err := c.Execute(ctx, command, struct {
		Manifest      json.RawMessage  `json:"manifest"`
		BuildSystemID string           `json:"buildSystemID"`
		WorkspaceRoot string           `json:"workspaceRoot,omitempty"`
		Request       BuildPlanRequest `json:"request"`
	}{manifest, buildSystemID, request.WorkspaceRoot, request}, &result); err != nil {
		return BuildPlan{}, err
	}
	if err := result.failure(command); err != nil {
		return BuildPlan{}, err
	}
	if result.Plan == nil {
		return BuildPlan{}, newParseError(command, "build plan returned no plan", "")
	}
	return *result.Plan, nil
}

// DecodeBuildModel turns static/command output or a provider result into the
// normalized model.
func (c *Client) DecodeBuildModel(ctx context.Context, manifest json.RawMessage, buildSystemID string, request BuildDecodeModelRequest) (BuildModel, error) {
	const command = "build.decodeModel"
	var result buildOutcome
	if err := c.Execute(ctx, command, struct {
		Manifest      json.RawMessage         `json:"manifest"`
		BuildSystemID string                  `json:"buildSystemID"`
		Request       BuildDecodeModelRequest `json:"request"`
	}{manifest, buildSystemID, request}, &result); err != nil {
		return BuildModel{}, err
	}
	if err := result.failure(command); err != nil {
		return BuildModel{}, err
	}
	if result.Model == nil {
		return BuildModel{}, newParseError(command, "build model returned no model", "")
	}
	return *result.Model, nil
}

// DecodeBuildRun validates the portable launch plan a provider returned.
func (c *Client) DecodeBuildRun(ctx context.Context, manifest json.RawMessage, buildSystemID string, request BuildDecodeRunRequest) (BuildLaunch, error) {
	const command = "build.decodeRunPreparation"
	var result buildOutcome
	if err := c.Execute(ctx, command, struct {
		Manifest      json.RawMessage       `json:"manifest"`
		BuildSystemID string                `json:"buildSystemID"`
		Request       BuildDecodeRunRequest `json:"request"`
	}{manifest, buildSystemID, request}, &result); err != nil {
		return BuildLaunch{}, err
	}
	if err := result.failure(command); err != nil {
		return BuildLaunch{}, err
	}
	if result.Launch == nil {
		return BuildLaunch{}, newParseError(command, "build run preparation returned no launch", "")
	}
	return *result.Launch, nil
}

// BuildProviderRequest is one typed request to a negotiated build-provider
// session. The completion arrives as a session event carrying the operation ID.
type PluginBuildProviderRequest struct {
	SessionID           string          `json:"sessionId"`
	OperationID         string          `json:"operationId,omitempty"`
	Method              string          `json:"method"`
	Params              json.RawMessage `json:"params"`
	TimeoutMilliseconds int             `json:"timeoutMilliseconds,omitempty"`
}

// RequestPluginBuild queues one build-provider request and returns Core's
// operation ID. Only methods negotiated by the session's litheBuild version are
// accepted by Core.
func (c *Client) RequestPluginBuild(ctx context.Context, request PluginBuildProviderRequest) (string, error) {
	var response struct {
		OperationID string `json:"operationId"`
	}
	if err := c.Execute(ctx, "lsp.buildRequest", request, &response); err != nil {
		return "", err
	}
	if response.OperationID == "" {
		return "", newParseError("lsp.buildRequest", "build request returned no operation ID", "")
	}
	return response.OperationID, nil
}
