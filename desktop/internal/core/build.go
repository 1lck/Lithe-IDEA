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
	PathVariable   string                     `json:"pathVariable,omitempty"`
	ID             string                     `json:"id"`
	DisplayName    string                     `json:"displayName"`
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
	// OptionOverrides are the saved per-run build options, layered by Core.
	OptionOverrides map[string]json.RawMessage `json:"optionOverrides,omitempty"`
	// LaunchOptions are a run configuration's choices.
	LaunchOptions *RunLaunchOptions `json:"launchOptions,omitempty"`
	// File is the workspace-relative source file build.runEntrypointsPlan asks about.
	File string `json:"file,omitempty"`
	// ProjectCodeAllowed is the workspace's trust; without it Core refuses a plan that runs
	// project code with BuildUntrustedWorkspace.
	ProjectCodeAllowed bool `json:"projectCodeAllowed,omitempty"`
}

// BuildUntrustedWorkspace is the code Core refuses a plan with when it would run project
// code in a workspace the user has not trusted.
const BuildUntrustedWorkspace = "plugin.build.untrustedWorkspace"

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
	Projects              []BuildProject             `json:"projects"`
	Targets               []BuildTarget              `json:"targets"`
	Tasks                 []BuildTask                `json:"tasks"`
	ContentRoots          []json.RawMessage          `json:"contentRoots"`
	OptionValues          map[string][]string        `json:"optionValues"`
	OptionDefaults        map[string][]string        `json:"optionDefaults,omitempty"`
	OptionExcludePrefixes map[string]string          `json:"optionExcludePrefixes,omitempty"`
	OptionSelection       *BuildModelOptionSelection `json:"optionSelection,omitempty"`
	Run                   []BuildRunEntry            `json:"run"`
}

// BuildModelOptionSelection contains choices observed by the tool for one build configuration.
type BuildModelOptionSelection struct {
	Fingerprint   string              `json:"fingerprint"`
	ActiveChoices map[string][]string `json:"activeChoices"`
}

// RunTypeReference identifies a declared run configuration type together with
// its field values, as emitted by build.decodeModel (`runConfigurationTypes` 0)
// and stored under `extensions.build` on `build.run-type` configurations.
type RunTypeReference struct {
	PluginID      string                     `json:"pluginID"`
	BuildSystemID string                     `json:"buildSystemID"`
	Type          string                     `json:"type"`
	Values        map[string]json.RawMessage `json:"values,omitempty"`
}

// BuildRunEntry is a Run entry Core derived from a decoded model: either a
// command entry with expanded Arguments, or a generated `build.run-type` entry
// carrying RunType. Provider runs have no entry; they are prepared on demand.
type BuildRunEntry struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Provider  string `json:"provider,omitempty"`
	Execution string `json:"execution"`
	// Arguments follow the build tool, which the host resolves as for a task.
	Arguments []string `json:"args"`
	// WorkingDirectory is relative to the workspace root, like a plan's.
	WorkingDirectory string               `json:"cwd"`
	Environment      map[string]string    `json:"env"`
	BuildSystem      BuildRunEntryBinding `json:"buildSystem"`
	// RunType is populated when a run declaration targets a runConfigurationType.
	RunType *RunTypeReference `json:"runType,omitempty"`
}

// BuildRunEntryBinding names the model item a Run entry was derived from:
// a target or a model task of the project.
type BuildRunEntryBinding struct {
	ProjectID string `json:"projectID"`
	TargetID  string `json:"targetID,omitempty"`
	TaskID    string `json:"taskID,omitempty"`
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
	OutputEncoding   string            `json:"outputEncoding,omitempty"`
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
	Status    string                `json:"status"`
	Error     *MarketplaceRejection `json:"error"`
	Detection *BuildDetection       `json:"detection"`
	Plan      *BuildPlan            `json:"plan"`
	Model     *BuildModel           `json:"model"`
	Launch    *BuildLaunch          `json:"launch"`
	// Preparation answers build.decodeDebugPreparation.
	Preparation *BuildDebugPreparation `json:"preparation"`
	Results     *BuildTestResults      `json:"results"`
	Invocation  *BuildInvocation       `json:"invocation"`
	Version     *BuildToolVersion      `json:"version"`
	// Dependencies is the answer of build.decodeDependencies.
	Dependencies *BuildDependencyTree `json:"dependencies"`
	// Storage and Edit answer build.resolveStoredOptions and build.editStoredOption; build.editIgnoredPaths
	// decodes its own edit, and Options answers build.resolveOptions.
	Storage *BuildStoredOptions   `json:"storage"`
	Edit    *BuildOptionEdit      `json:"edit"`
	Options *BuildResolvedOptions `json:"options"`
	// Discovery answers build.decodeTestDiscovery.
	Discovery *BuildTestDiscovery `json:"discovery"`
	// Tree answers build.modelTree.
	Tree *BuildModelTree `json:"tree"`
	// Entrypoints answers build.decodeRunEntrypoints.
	Entrypoints *BuildRunEntrypoints `json:"entrypoints"`
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
		IgnoredPaths     []string                                         `json:"ignoredPaths"`
	}{workspaceRoot, plugins, options.Options, options.InstanceOptions, options.InstanceDefaults, options.EmptySelections, options.IgnoredPaths}, &result); err != nil {
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

// BuildOptionPlugin is one enabled build plugin of a build.localizeOptions request: its manifest and, once
// read, the translation files Core named, by package-relative path.
type BuildOptionPlugin struct {
	Manifest      json.RawMessage   `json:"manifest"`
	Localizations map[string]string `json:"localizations,omitempty"`
}

// BuildOptionTexts is Core's answer to build.localizeOptions: one manifest per plugin, in request order, with
// the option text translated when a file applied, and one translation report per plugin that declares a build
// option.
type BuildOptionTexts struct {
	Manifests     []json.RawMessage     `json:"manifests"`
	Localizations []RunTypeLocalization `json:"localizations"`
}

// LocalizeBuildOptions asks Core for the build plugins' manifests with their option text in language. Sent
// without localizations, the reports name the files to read; sent again with them, the manifests are
// translated.
func (c *Client) LocalizeBuildOptions(ctx context.Context, language string, plugins []BuildOptionPlugin) (BuildOptionTexts, error) {
	const command = "build.localizeOptions"
	var result BuildOptionTexts
	if err := c.Execute(ctx, command, struct {
		Language string              `json:"language,omitempty"`
		Plugins  []BuildOptionPlugin `json:"plugins"`
	}{language, plugins}, &result); err != nil {
		return BuildOptionTexts{}, err
	}
	if len(result.Manifests) != len(plugins) {
		return BuildOptionTexts{}, newParseError(command, "build.localizeOptions returned a manifest count that does not match the request", "")
	}
	return result, nil
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

// RunTypeInstance is one detected instance of a build system as
// `build.runConfigurationPlan` takes it: its workspace-relative root and stored options.
type RunTypeInstance struct {
	Root    string                     `json:"root"`
	Options map[string]json.RawMessage `json:"options,omitempty"`
}

// RunConfigurationPlanRequest asks for the launch of saved configuration
// ConfigurationID of a kind the build system declares. Core runs it with the
// instance whose root holds the configuration's working directory.
type RunConfigurationPlanRequest struct {
	ConfigurationID         string            `json:"configurationId"`
	Instances               []RunTypeInstance `json:"instances"`
	PluginDirectory         string            `json:"pluginDirectory,omitempty"`
	WorkspaceStateDirectory string            `json:"workspaceStateDirectory,omitempty"`
	// ProjectCodeAllowed is the workspace's trust, as in BuildPlanRequest.
	ProjectCodeAllowed bool `json:"projectCodeAllowed,omitempty"`
}

// PlanRunConfiguration plans a saved configuration of a plugin-declared run kind
// (`build.runConfigurationPlan`): the command plan of the chosen instance, whose
// Root names it, with the configuration's environment already in Environment.
func (c *Client) PlanRunConfiguration(ctx context.Context, manifest json.RawMessage, buildSystemID, workspaceRoot string, request RunConfigurationPlanRequest) (BuildPlan, error) {
	const command = "build.runConfigurationPlan"
	var result buildOutcome
	if err := c.Execute(ctx, command, struct {
		Manifest      json.RawMessage             `json:"manifest"`
		BuildSystemID string                      `json:"buildSystemID"`
		WorkspaceRoot string                      `json:"workspaceRoot"`
		Request       RunConfigurationPlanRequest `json:"request"`
	}{manifest, buildSystemID, workspaceRoot, request}, &result); err != nil {
		return BuildPlan{}, err
	}
	if err := result.failure(command); err != nil {
		return BuildPlan{}, err
	}
	if result.Plan == nil {
		return BuildPlan{}, newParseError(command, "run configuration plan returned no plan", "")
	}
	return *result.Plan, nil
}

// BeforeLaunchTaskPlanRequest asks for the command of a plugin task step, with
// Task and WorkingDirectory as `runConfig.beforeLaunch` returned the step. Core
// runs it with the instance whose root holds the working directory.
type BeforeLaunchTaskPlanRequest struct {
	Task                    RunTaskReference  `json:"task"`
	WorkingDirectory        string            `json:"workingDirectory"`
	Instances               []RunTypeInstance `json:"instances"`
	PluginDirectory         string            `json:"pluginDirectory,omitempty"`
	WorkspaceStateDirectory string            `json:"workspaceStateDirectory,omitempty"`
	// ProjectCodeAllowed is the workspace's trust, as in BuildPlanRequest.
	ProjectCodeAllowed bool `json:"projectCodeAllowed,omitempty"`
}

// PlanBeforeLaunchTask plans a task step of a Before Launch list
// (`build.beforeLaunchTaskPlan`): the command plan of the chosen instance, whose
// Root names it, run to completion at the step's working directory.
func (c *Client) PlanBeforeLaunchTask(ctx context.Context, manifest json.RawMessage, buildSystemID, workspaceRoot string, request BeforeLaunchTaskPlanRequest) (BuildPlan, error) {
	const command = "build.beforeLaunchTaskPlan"
	var result buildOutcome
	if err := c.Execute(ctx, command, struct {
		Manifest      json.RawMessage             `json:"manifest"`
		BuildSystemID string                      `json:"buildSystemID"`
		WorkspaceRoot string                      `json:"workspaceRoot"`
		Request       BeforeLaunchTaskPlanRequest `json:"request"`
	}{manifest, buildSystemID, workspaceRoot, request}, &result); err != nil {
		return BuildPlan{}, err
	}
	if err := result.failure(command); err != nil {
		return BuildPlan{}, err
	}
	if result.Plan == nil {
		return BuildPlan{}, newParseError(command, "before-launch task plan returned no plan", "")
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

// BuildModelTreeRequest asks for the tree of one loaded model (build.modelTree): its projects
// nested by parent, each with its tasks in folders, its dependencies and its targets. Query
// narrows the tree to the nodes it matches; GroupHeadings labels the folder of each task group
// in the user's language, and the query matches those labels too.
type BuildModelTreeRequest struct {
	Model         BuildModelTreeInput        `json:"model"`
	Options       map[string]json.RawMessage `json:"options,omitempty"`
	Query         string                     `json:"query,omitempty"`
	GroupHeadings map[string]string          `json:"groupHeadings,omitempty"`
}

// BuildModelTreeInput is the part of a decoded model the tree reads.
type BuildModelTreeInput struct {
	Projects              []BuildProject             `json:"projects"`
	Targets               []BuildTarget              `json:"targets"`
	Tasks                 []BuildTask                `json:"tasks"`
	OptionValues          map[string][]string        `json:"optionValues,omitempty"`
	OptionDefaults        map[string][]string        `json:"optionDefaults,omitempty"`
	OptionExcludePrefixes map[string]string          `json:"optionExcludePrefixes,omitempty"`
	OptionSelection       *BuildModelOptionSelection `json:"optionSelection,omitempty"`
}

// BuildModelTree is the Build tool window's tree of one instance. Project is the instance's
// only root project, whose contents Nodes holds beside the instance's own; with several root
// projects or none it is nil and Nodes holds the instance's nodes, then the root projects.
// Truncated says Core cut a tree too large to show whole.
type BuildModelTree struct {
	Project   *BuildTreeNode  `json:"project"`
	Nodes     []BuildTreeNode `json:"nodes"`
	Truncated bool            `json:"truncated"`
}

// The kinds of a BuildTreeNode.
const (
	BuildTreeOption       = "option"
	BuildTreeOptionChoice = "optionChoice"
	BuildTreeProject      = "project"
	BuildTreeFolder       = "folder"
	BuildTreeTask         = "task"
	BuildTreeTargets      = "targets"
	BuildTreeTarget       = "target"
	BuildTreeDependencies = "dependencies"
	BuildTreeTests        = "tests"
)

// BuildTreeNode is one node of a BuildModelTree. Key is unique in the instance and stable
// across reloads and filters. ProjectID and TargetID are what a task runs on, empty for the
// whole instance; TaskID is a declared or a model task. OptionID and OptionValue name the
// option and choice an option or optionChoice node shows, with Checked and DefaultActive on
// each choice. Group names the task group a folder stands for, empty for a category folder.
// Matched marks a node the query matches itself. Targets, dependencies and tests nodes have no
// label: the host names them.
type BuildTreeNode struct {
	Kind          string          `json:"kind"`
	Key           string          `json:"key"`
	Label         string          `json:"label"`
	Detail        string          `json:"detail"`
	Tooltip       string          `json:"tooltip"`
	Group         string          `json:"group"`
	ProjectID     string          `json:"projectID"`
	TargetID      string          `json:"targetID"`
	TaskID        string          `json:"taskID"`
	OptionID      string          `json:"optionID"`
	OptionValue   string          `json:"optionValue"`
	Checked       bool            `json:"checked"`
	DefaultActive bool            `json:"defaultActive"`
	Matched       bool            `json:"matched"`
	Children      []BuildTreeNode `json:"children"`
}

// BuildModelTree lays out the tree of one loaded model for the Build tool window.
func (c *Client) BuildModelTree(ctx context.Context, manifest json.RawMessage, buildSystemID string, request BuildModelTreeRequest) (BuildModelTree, error) {
	const command = "build.modelTree"
	var result buildOutcome
	if err := c.Execute(ctx, command, struct {
		Manifest      json.RawMessage       `json:"manifest"`
		BuildSystemID string                `json:"buildSystemID"`
		Request       BuildModelTreeRequest `json:"request"`
	}{manifest, buildSystemID, request}, &result); err != nil {
		return BuildModelTree{}, err
	}
	if err := result.failure(command); err != nil {
		return BuildModelTree{}, err
	}
	if result.Tree == nil {
		return BuildModelTree{}, newParseError(command, "build model tree returned no tree", "")
	}
	return *result.Tree, nil
}

// BuildDecodeDebugRequest validates the raw result of a provider's debug preparation. Run is
// the run declaration the preparation was planned for, whose `debug.adapter` Core answers.
// Native debug preparation takes no launch options, so the request carries none.
type BuildDecodeDebugRequest struct {
	WorkspaceRoot string          `json:"workspaceRoot"`
	Root          string          `json:"root"`
	Run           string          `json:"run"`
	Result        json.RawMessage `json:"result"`
}

// BuildDebugPreparation is the native debug program a provider prepared, as Core validated it:
// the local ID of the plugin's own adapter the run declares, and the program with its process
// facts. Program and WorkingDirectory are relative to the workspace root.
type BuildDebugPreparation struct {
	Adapter          string            `json:"adapter"`
	Root             string            `json:"root"`
	Program          string            `json:"program"`
	Arguments        []string          `json:"arguments"`
	WorkingDirectory string            `json:"workingDirectory"`
	Environment      map[string]string `json:"environment"`
}

// DecodeBuildDebug validates the native debug program a provider prepared
// (`build.decodeDebugPreparation`).
func (c *Client) DecodeBuildDebug(ctx context.Context, manifest json.RawMessage, buildSystemID string, request BuildDecodeDebugRequest) (BuildDebugPreparation, error) {
	const command = "build.decodeDebugPreparation"
	var result buildOutcome
	if err := c.Execute(ctx, command, struct {
		Manifest      json.RawMessage         `json:"manifest"`
		BuildSystemID string                  `json:"buildSystemID"`
		Request       BuildDecodeDebugRequest `json:"request"`
	}{manifest, buildSystemID, request}, &result); err != nil {
		return BuildDebugPreparation{}, err
	}
	if err := result.failure(command); err != nil {
		return BuildDebugPreparation{}, err
	}
	if result.Preparation == nil {
		return BuildDebugPreparation{}, newParseError(command, "build debug preparation returned no preparation", "")
	}
	return *result.Preparation, nil
}
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
