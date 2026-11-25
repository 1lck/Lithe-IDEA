package core

import (
	"context"
	"encoding/json"
	"strings"
)

// RunProviderReference selects one build provider run: the plugin's build system
// instance, the run declaration and the model project and target it runs. Core
// keeps the identity stable while labels and arguments change.
type RunProviderReference struct {
	PluginID      string   `json:"pluginID"`
	BuildSystemID string   `json:"buildSystemID"`
	Root          string   `json:"root"`
	Run           string   `json:"run"`
	ProjectID     string   `json:"projectID"`
	TargetID      string   `json:"targetID"`
	Execution     string   `json:"execution,omitempty"`
	UserArguments []string `json:"userArguments"`
}

// RunProviderRun is one entry of the providerRuns snapshot: either a build
// provider selector (Reference) or a generated run-configuration-type entry
// (RunType, CWD, Execution, Selector), under the workspace-relative project
// path that owns it.
type RunProviderRun struct {
	ProjectPath string                `json:"projectPath"`
	Name        string                `json:"name"`
	Reference   *RunProviderReference `json:"reference,omitempty"`
	CWD         string                `json:"cwd,omitempty"`
	Execution   string                `json:"execution,omitempty"`
	Selector    string                `json:"selector,omitempty"`
	RunType     *RunTypeReference     `json:"runType,omitempty"`
}

// RunConfiguration is one effective run configuration after Core merged the
// detected, team and local layers. Extensions stay raw except for the build
// reference the host needs to find the provider instance.
type RunConfiguration struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// Folder is the folder the configuration is listed in within its kind; "" when
	// it is in none. It is display only.
	Folder     string                     `json:"folder,omitempty"`
	Provider   string                     `json:"provider"`
	Execution  string                     `json:"execution"`
	Category   string                     `json:"category,omitempty"`
	Args       []string                   `json:"args"`
	Cwd        string                     `json:"cwd"`
	Env        map[string]string          `json:"env"`
	Disabled   bool                       `json:"disabled"`
	Source     string                     `json:"source,omitempty"`
	Extensions map[string]json.RawMessage `json:"extensions,omitempty"`
	// Plugin is the plugin the configuration needs, as its document records it.
	Plugin *RunPluginDependency `json:"plugin,omitempty"`
	// Availability is set when the saved configuration cannot run, such as when
	// the plugin it needs is not installed. The host shows it and never starts it.
	Availability *RunAvailability `json:"availability,omitempty"`
	// BeforeLaunch names the built-in process runs and plugin tasks started, in order,
	// before this one.
	BeforeLaunch []RunBeforeLaunchStep `json:"beforeLaunch,omitempty"`
	// AllowMultipleInstances lets a new run start beside one still running instead of
	// stopping it first.
	AllowMultipleInstances bool `json:"allowMultipleInstances,omitempty"`
}

// RunBeforeLaunchStep is one saved step of a configuration's beforeLaunch: the
// built-in process run to start first, or a plugin Task.
type RunBeforeLaunchStep struct {
	Configuration string            `json:"configuration,omitempty"`
	Task          *RunTaskReference `json:"task,omitempty"`
}

// RunPluginDependency is the plugin a configuration needs: its ID, and what the
// configuration's plugin document recorded when it was saved. A build run outside
// a plugin document carries only the ID.
type RunPluginDependency struct {
	ID                 string `json:"id"`
	Name               string `json:"name,omitempty"`
	Author             string `json:"author,omitempty"`
	Repository         string `json:"repository,omitempty"`
	Version            string `json:"version,omitempty"`
	VersionRequirement string `json:"versionRequirement,omitempty"`
}

// RunAvailability says why a saved configuration cannot run. Code is
// pluginMissing, pluginRepositoryMismatch, pluginVersionUnsupported,
// invalidConfiguration, unsupportedPlatform (a built-in kind this platform
// cannot run, such as a batch script outside Windows) or
// missingWorkingDirectory; Message is Core's English
// description, which the host shows only as the detail of its own text.
type RunAvailability struct {
	Status  string `json:"status"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

// ProcessProviderPrefix starts the providers of the built-in process runs Core
// plans without any plugin: shell, PowerShell and batch scripts, and programs.
const ProcessProviderPrefix = "process."

// IsProcess says the configuration is a built-in process run the host starts itself.
func (r RunConfiguration) IsProcess() bool {
	return strings.HasPrefix(r.Provider, ProcessProviderPrefix)
}

// Unavailable says resolution found that the configuration cannot run.
func (r RunConfiguration) Unavailable() bool {
	return r.Availability != nil && r.Availability.Status == "unavailable"
}

// UserDefined says the user created the configuration, so it can be deleted.
func (r RunConfiguration) UserDefined() bool {
	return strings.HasPrefix(r.ID, "user:")
}

// RunInstalledPlugin is one installed, enabled plugin as `runConfig.resolve`
// and the edit commands check it: the fields of its plugin.json.
type RunInstalledPlugin struct {
	ID               string          `json:"id"`
	DisplayName      string          `json:"displayName,omitempty"`
	Version          string          `json:"version"`
	Repository       string          `json:"repository,omitempty"`
	PluginAPIVersion *int            `json:"pluginAPIVersion,omitempty"`
	Requires         json.RawMessage `json:"requires,omitempty"`
}

// RunConfigChange is one file an edit command changes. Path is workspace-relative
// with '/', BaseSHA256 the lowercase hex SHA-256 of the bytes Core read (nil when
// the file did not exist) and Content the new text (nil deletes the file). Core
// writes nothing: the host applies the changes of one reply as one transaction,
// and only while every file still has its base bytes.
type RunConfigChange struct {
	Path       string  `json:"path"`
	BaseSHA256 *string `json:"baseSha256"`
	Content    *string `json:"content"`
}

// BuildReference is the configuration's build provider selector, when it has one.
func (r RunConfiguration) BuildReference() (RunProviderReference, bool) {
	raw, ok := r.Extensions["build"]
	if !ok || r.Provider != "build.provider" {
		return RunProviderReference{}, false
	}
	var reference RunProviderReference
	if json.Unmarshal(raw, &reference) != nil || reference.PluginID == "" || reference.Run == "" {
		return RunProviderReference{}, false
	}
	return reference, true
}

// RunTypeReference is the declared kind a `build.run-type` configuration belongs to,
// when it is one.
func (r RunConfiguration) RunTypeReference() (RunTypeKey, bool) {
	raw, ok := r.Extensions["build"]
	if !ok || r.Provider != RunTypeProvider {
		return RunTypeKey{}, false
	}
	var key RunTypeKey
	if json.Unmarshal(raw, &key) != nil || key.PluginID == "" || key.BuildSystemID == "" || key.Type == "" {
		return RunTypeKey{}, false
	}
	return key, true
}

// RunConfigResolution is what `runConfig.resolve` returns: the effective
// configurations, Core's findings about them and the default one.
type RunConfigResolution struct {
	Configurations []RunConfiguration `json:"configurations"`
	Diagnostics    []struct {
		ID   string `json:"id,omitempty"`
		Code string `json:"code"`
		// Path is the workspace-relative file a diagnostic about a whole saved document
		// names, such as a plugin's TOML document that cannot be read; Core left the
		// configurations it holds out.
		Path    string `json:"path,omitempty"`
		Message string `json:"message"`
	} `json:"diagnostics"`
	DefaultRunConfiguration *string `json:"defaultRunConfiguration"`
	// SortAlphabetically says Configurations are listed by name; otherwise they come in
	// the order the user placed them on this machine.
	SortAlphabetically bool `json:"sortAlphabetically"`
}

// ResolveRunConfigurations merges the workspace's run configuration layers
// (local over team over detected) without writing anything. plugins lists the
// enabled plugins, so a configuration whose plugin is missing comes back
// unavailable; nil skips that check.
func (c *Client) ResolveRunConfigurations(ctx context.Context, root string, plugins []RunInstalledPlugin) (RunConfigResolution, error) {
	var result RunConfigResolution
	err := c.Execute(ctx, "runConfig.resolve", struct {
		Root    string               `json:"root"`
		Plugins []RunInstalledPlugin `json:"plugins,omitempty"`
	}{root, plugins}, &result)
	return result, err
}

// TitleConfiguration describes the configuration the title bar shows, as far as starting it
// depends on. Kind is "unsupported", "process", "unavailable", "instanceMissing",
// "modelNotLoaded" (with Failed) or "modelLoaded" (with Debuggable).
type TitleConfiguration struct {
	Kind       string `json:"kind"`
	Failed     *bool  `json:"failed,omitempty"`
	Debuggable *bool  `json:"debuggable,omitempty"`
}

// TitleActionFacts are the facts one title bar Run or Debug decision depends on.
type TitleActionFacts struct {
	// Action is "run" or "debug".
	Action string `json:"action"`
	// Trigger is "press", or "settled" when the host asks again for a press it kept.
	Trigger           string `json:"trigger"`
	CurrentFileChosen bool   `json:"currentFileChosen"`
	// Settled says detection answered, no model is loading and the configurations were
	// resolved since.
	Settled       bool                `json:"settled"`
	Configuration *TitleConfiguration `json:"configuration,omitempty"`
}

// DecideTitleAction asks Core what a title bar press does. The answer is "currentFile",
// "wait", "loadModel", "unsupported", "unavailable", "targetMissing", "modelFailed", "run",
// "debug" or "notDebuggable".
func (c *Client) DecideTitleAction(ctx context.Context, facts TitleActionFacts) (string, error) {
	var decision struct {
		Kind string `json:"kind"`
	}
	if err := c.Execute(ctx, "runConfig.decideTitleAction", facts, &decision); err != nil {
		return "", err
	}
	return decision.Kind, nil
}

// RunLaunchOptions are the typed launch options of a build provider run
// (buildProviders 10): the user's resolved choices, passed to the provider's
// prepareRun and to the decoder of its answer.
type RunLaunchOptions struct {
	Execution        string            `json:"execution"`
	RuntimeArguments []string          `json:"runtimeArguments"`
	Arguments        []string          `json:"arguments"`
	Environment      map[string]string `json:"environment"`
	Entrypoint       string            `json:"entrypoint,omitempty"`
	WorkingDirectory string            `json:"workingDirectory,omitempty"`
	// Debug asks for a service suspended until the selected adapter attaches
	// (registry connection debugging); nil runs it without a debugger. Core
	// resolves no debug choice from the saved layers: the host sets it per launch.
	Debug *RunLaunchDebug `json:"debug,omitempty"`
}

// RunLaunchDebug is `launchOptions.debug`: the registry adapter the host selected
// for the run's declared type, and the loopback endpoint the host owns, on which
// the service waits for that adapter.
type RunLaunchDebug struct {
	// AdapterID is the selected adapter's qualified identity, `pluginID/adapterID`.
	AdapterID         string             `json:"adapterID"`
	ConfigurationType string             `json:"configurationType"`
	Target            RunDebugConnection `json:"target"`
}

// RunDebugConnection is a debuggee endpoint: Kind "connection" on Host:Port.
type RunDebugConnection struct {
	Kind string `json:"kind"`
	Host string `json:"host"`
	Port int    `json:"port"`
}

// Customized says whether the options ask for anything a launch without them
// would not do, so an application run with none keeps the version 4 request.
func (o RunLaunchOptions) Customized() bool {
	return (o.Execution != "" && o.Execution != "application") || len(o.RuntimeArguments) > 0 || len(o.Arguments) > 0 ||
		len(o.Environment) > 0 || o.Entrypoint != "" || o.WorkingDirectory != "" || o.Debug != nil
}

// RunProviderLaunchInputs is what `runConfig.providerLaunchInputs` resolves for
// one build provider configuration.
type RunProviderLaunchInputs struct {
	BuildSystemID   string                     `json:"buildSystemID"`
	Provider        string                     `json:"provider"`
	ProjectPath     string                     `json:"projectPath"`
	LaunchOptions   RunLaunchOptions           `json:"launchOptions"`
	OptionOverrides map[string]json.RawMessage `json:"optionOverrides"`
	Reference       RunProviderReference       `json:"reference"`
}

// ProviderLaunchInputs resolves the launch options of one build provider run
// configuration for the provider instance at providerRoot.
func (c *Client) ProviderLaunchInputs(ctx context.Context, root, configurationID, providerRoot string) (RunProviderLaunchInputs, error) {
	var result RunProviderLaunchInputs
	err := c.Execute(ctx, "runConfig.providerLaunchInputs", struct {
		Root            string `json:"root"`
		ConfigurationID string `json:"configurationId"`
		ProviderRoot    string `json:"providerRoot"`
	}{root, configurationID, providerRoot}, &result)
	return result, err
}

// RunOptionsEdit is a `runConfig.updateOptions` request: the user's arguments
// (editor text Core splits), working directory and environment for one
// configuration in the local or project layer.
type RunOptionsEdit struct {
	Root             string            `json:"root"`
	Scope            string            `json:"scope"`
	ConfigurationID  string            `json:"configurationId"`
	WorkingDirectory string            `json:"workingDirectory"`
	Arguments        string            `json:"arguments"`
	Environment      map[string]string `json:"environment"`
	// ProviderRunOptions replaces the build provider choices of the selected layer when set.
	ProviderRunOptions json.RawMessage `json:"providerRunOptions,omitempty"`
	// BeforeLaunch replaces the steps of the selected layer when set, in the shape of
	// the editor field's value; an empty list removes them (and in the local layer
	// hides the project's).
	BeforeLaunch *[]RunBeforeLaunchEntry `json:"beforeLaunch,omitempty"`
	// RunTypePlugins are the enabled plugins, so Core can check the task steps.
	RunTypePlugins *RunTypePlugins `json:"runTypePlugins,omitempty"`
	// Plugins is the enabled plugin list of ResolveRunConfigurations, so a plugin
	// document Core writes records the installed plugin.
	Plugins []RunInstalledPlugin `json:"plugins,omitempty"`
}

// ProviderRunOptionsSnapshot is the typed choices of a build provider configuration
// (extensions.build-run): runtime arguments, an entrypoint, the build option overrides and
// the tool choices by qualified tool ID. A tool choice is {home} or {executable}; a nil
// entry clears an inherited choice.
type ProviderRunOptionsSnapshot struct {
	RuntimeArguments []string                     `json:"runtimeArguments"`
	Entrypoint       string                       `json:"entrypoint"`
	Options          map[string]json.RawMessage   `json:"options"`
	Tools            map[string]map[string]string `json:"tools"`
}

// UpdateRunConfigurationOptions returns the file changes that apply the edit.
// Core writes nothing; the host applies them as one transaction.
func (c *Client) UpdateRunConfigurationOptions(ctx context.Context, edit RunOptionsEdit) ([]RunConfigChange, error) {
	var result struct {
		Changes []RunConfigChange `json:"changes"`
	}
	err := c.Execute(ctx, "runConfig.updateOptions", edit, &result)
	return result.Changes, err
}

// RunArgumentText formats each argument vector as the editor text that
// `runConfig.updateOptions` splits back into the same vector.
func (c *Client) RunArgumentText(ctx context.Context, lists [][]string) ([]string, error) {
	var result []string
	err := c.Execute(ctx, "runConfig.argumentText", struct {
		ArgumentLists [][]string `json:"argumentLists"`
	}{lists}, &result)
	return result, err
}
