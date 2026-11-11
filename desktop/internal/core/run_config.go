package core

import (
	"context"
	"encoding/json"
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

// RunProviderRun is one entry of the providerRuns snapshot: a run the current
// build models offer, under the workspace-relative project path that owns it.
type RunProviderRun struct {
	ProjectPath string               `json:"projectPath"`
	Name        string               `json:"name"`
	Reference   RunProviderReference `json:"reference"`
}

// RunConfiguration is one effective run configuration after Core merged the
// detected, team and local layers. Extensions stay raw except for the build
// reference the host needs to find the provider instance.
type RunConfiguration struct {
	ID         string                     `json:"id"`
	Name       string                     `json:"name"`
	Provider   string                     `json:"provider"`
	Execution  string                     `json:"execution"`
	Category   string                     `json:"category,omitempty"`
	Args       []string                   `json:"args"`
	Cwd        string                     `json:"cwd"`
	Env        map[string]string          `json:"env"`
	Disabled   bool                       `json:"disabled"`
	Source     string                     `json:"source,omitempty"`
	Extensions map[string]json.RawMessage `json:"extensions,omitempty"`
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

// RunConfigResolution is what `runConfig.resolve` returns: the effective
// configurations, Core's findings about them and the default one.
type RunConfigResolution struct {
	Configurations []RunConfiguration `json:"configurations"`
	Diagnostics    []struct {
		ID      string `json:"id,omitempty"`
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"diagnostics"`
	DefaultRunConfiguration *string `json:"defaultRunConfiguration"`
}

// ResolveRunConfigurations merges the workspace's run configuration layers
// (local over team over detected) without writing anything.
func (c *Client) ResolveRunConfigurations(ctx context.Context, root string) (RunConfigResolution, error) {
	var result RunConfigResolution
	err := c.Execute(ctx, "runConfig.resolve", struct {
		Root string `json:"root"`
	}{root}, &result)
	return result, err
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
}

// Customized says whether the options ask for anything a launch without them
// would not do, so an application run with none keeps the version 4 request.
func (o RunLaunchOptions) Customized() bool {
	return (o.Execution != "" && o.Execution != "application") || len(o.RuntimeArguments) > 0 || len(o.Arguments) > 0 ||
		len(o.Environment) > 0 || o.Entrypoint != "" || o.WorkingDirectory != ""
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
// configuration in the local or project layer. LocalDocument, when set, is the
// captured local layer Core edits and resolves against instead of reading it.
type RunOptionsEdit struct {
	Root             string            `json:"root"`
	Scope            string            `json:"scope"`
	ConfigurationID  string            `json:"configurationId"`
	WorkingDirectory string            `json:"workingDirectory"`
	Arguments        string            `json:"arguments"`
	Environment      map[string]string `json:"environment"`
	LocalDocument    json.RawMessage   `json:"localDocument,omitempty"`
	// ProviderRunOptions replaces the build provider choices of the selected layer when set.
	ProviderRunOptions json.RawMessage `json:"providerRunOptions,omitempty"`
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

// UpdateRunConfigurationOptions returns the layer document with the edit applied.
// Core writes nothing; the host publishes the document to the scope's file.
func (c *Client) UpdateRunConfigurationOptions(ctx context.Context, edit RunOptionsEdit) (string, error) {
	var result struct {
		Document string `json:"document"`
	}
	err := c.Execute(ctx, "runConfig.updateOptions", edit, &result)
	return result.Document, err
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
