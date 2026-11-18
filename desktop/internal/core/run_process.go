package core

import (
	"context"
	"encoding/json"
)

// RunFormVersion is the `runConfig.editorForm` version this host draws. A newer
// form is refused, since its fields may mean something this host cannot show.
const RunFormVersion = 1

// RunConfigurationType is one run configuration kind a user can create: a built-in
// one such as `process.shell`, or, with provider `build.run-type`, one an installed
// plugin declares, named by RunType and shown with the plugin's DisplayName,
// Description and Icon. Availability is set when this platform cannot run the kind,
// such as a batch script outside Windows; its configurations are still created and
// edited.
type RunConfigurationType struct {
	Provider     string           `json:"provider"`
	Availability *RunAvailability `json:"availability,omitempty"`
	RunType      *RunTypeKey      `json:"runType,omitempty"`
	DisplayName  string           `json:"displayName,omitempty"`
	Execution    string           `json:"execution,omitempty"`
	Description  string           `json:"description,omitempty"`
	Icon         *RunTypeIcon     `json:"icon,omitempty"`
}

// RunTypeProvider is the provider of every configuration of a plugin-declared kind.
const RunTypeProvider = "build.run-type"

// RunTypeKey names a plugin-declared run configuration kind: the plugin, its build
// system and the kind's ID within it.
type RunTypeKey struct {
	PluginID      string `json:"pluginID"`
	BuildSystemID string `json:"buildSystemID"`
	Type          string `json:"type"`
}

// RunTypeIcon is the icon a declared kind names: a host icon such as `run`, or a
// package image (Path, DarkPath) relative to the plugin directory.
type RunTypeIcon struct {
	Host     string `json:"host,omitempty"`
	Path     string `json:"path,omitempty"`
	DarkPath string `json:"darkPath,omitempty"`
	Mode     string `json:"mode,omitempty"`
}

// RunTypePlugins is the `runTypePlugins` the run configuration editor commands take:
// every enabled plugin's manifest, and the interface Language their text is
// translated to. Core lists the kinds the manifests declare; a manifest that declares
// none, or does not validate, adds nothing.
type RunTypePlugins struct {
	Language string          `json:"language,omitempty"`
	Plugins  []RunTypePlugin `json:"plugins"`
}

// RunTypePlugin is one enabled plugin. Localizations are the translation files the
// host read from the package, by package-relative path; nil until a report asked for
// them, so Core tells which files to read. An empty map that is not nil says the
// host read the candidates and found none, so it is sent as {} and nil as null.
type RunTypePlugin struct {
	Manifest      json.RawMessage   `json:"manifest"`
	Localizations map[string]string `json:"localizations"`
}

// RunTypeLocalization is the translation report of one plugin that declares a kind,
// the report of plugin settings with the plugin it is about.
type RunTypeLocalization struct {
	PluginID string `json:"pluginID"`
	PluginSettingsLocalization
}

// Unavailable says this platform cannot run configurations of the kind.
func (t RunConfigurationType) Unavailable() bool {
	return t.Availability != nil && t.Availability.Status == "unavailable"
}

// RunConfigurationTypes lists the kinds a user can create, in display order: the
// built-in ones, then the kinds plugins declare. Every platform lists every built-in
// kind; one it cannot run says so. With a language, the answer reports per plugin
// which translation files to read, for a second call with them.
func (c *Client) RunConfigurationTypes(ctx context.Context, plugins *RunTypePlugins) ([]RunConfigurationType, []RunTypeLocalization, error) {
	var result struct {
		Types         []RunConfigurationType `json:"types"`
		Localizations []RunTypeLocalization  `json:"localizations"`
	}
	err := c.Execute(ctx, "runConfig.configurationTypes", struct {
		RunTypePlugins *RunTypePlugins `json:"runTypePlugins,omitempty"`
	}{plugins}, &result)
	return result.Types, result.Localizations, err
}

// RunEditorField is one field of a run configuration editor. Kind is text,
// checkbox, choice, file, multilineText, arguments, directory, environment or
// executable; a host skips a kind it does not know and still sends its value
// back. Automatic is the value used while the field is empty, shown as its
// placeholder. Note is an explanation key, such as windowsOnly. ShellFamily, on
// an executable field, is the family of shell it takes (posix, powershell or
// cmd), so a host can offer the installed shells of that family. A field a
// plugin declares (ID `field:<id>`) carries its own translated Label,
// Description, Placeholder and the titles of its Options in OptionLabels.
type RunEditorField struct {
	ID           string             `json:"id"`
	Kind         string             `json:"kind"`
	Required     bool               `json:"required,omitempty"`
	Placement    string             `json:"placement,omitempty"`
	Automatic    *string            `json:"automatic,omitempty"`
	Options      []string           `json:"options,omitempty"`
	VisibleWhen  *RunFieldCondition `json:"visibleWhen,omitempty"`
	Note         string             `json:"note,omitempty"`
	ShellFamily  string             `json:"shellFamily,omitempty"`
	Label        string             `json:"label,omitempty"`
	Description  string             `json:"description,omitempty"`
	Placeholder  string             `json:"placeholder,omitempty"`
	OptionLabels map[string]string  `json:"optionLabels,omitempty"`
	// Candidates are the configurations a beforeLaunch field may name.
	Candidates []RunConfigurationName `json:"candidates,omitempty"`
}

// RunConfigurationName is a run configuration's ID and name.
type RunConfigurationName struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// RunFieldCondition shows a field only while Field has the value Equals.
type RunFieldCondition struct {
	Field  string `json:"field"`
	Equals any    `json:"equals"`
}

// RunEditorForm is what `runConfig.editorForm` returns: the fields in order and
// the current value of each, by field ID. Values stay raw so keys this host
// does not show go back unchanged. Availability is set when this platform cannot
// run the kind; the form still edits and saves it. RunType names the declared kind
// of a `build.run-type` form; Localizations report the translation files to read,
// as RunConfigurationTypes does.
type RunEditorForm struct {
	FormVersion     int                        `json:"formVersion"`
	Provider        string                     `json:"provider"`
	ConfigurationID *string                    `json:"configurationId"`
	Values          map[string]json.RawMessage `json:"values"`
	Fields          []RunEditorField           `json:"fields"`
	Availability    *RunAvailability           `json:"availability,omitempty"`
	RunType         *RunTypeKey                `json:"runType,omitempty"`
	Localizations   []RunTypeLocalization      `json:"localizations,omitempty"`
}

// RunEditorFormRequest asks for the editor of a new configuration of Provider (and
// RunType, for a declared kind) or of the saved ConfigurationID. Values are the open
// editor's unsaved values, so the automatic values follow the edit. RunTypePlugins
// list the kinds plugins declare; a declared kind's form needs them.
type RunEditorFormRequest struct {
	Root            string                     `json:"root"`
	Provider        string                     `json:"provider,omitempty"`
	RunType         *RunTypeKey                `json:"runType,omitempty"`
	ConfigurationID string                     `json:"configurationId,omitempty"`
	Values          map[string]json.RawMessage `json:"values,omitempty"`
	RunTypePlugins  *RunTypePlugins            `json:"runTypePlugins,omitempty"`
}

// RunEditorForm describes the editor fields and current values of a built-in run configuration.
func (c *Client) RunEditorForm(ctx context.Context, request RunEditorFormRequest) (RunEditorForm, error) {
	var result RunEditorForm
	err := c.Execute(ctx, "runConfig.editorForm", request, &result)
	return result, err
}

// RunFieldError is one wrong editor value: the field and a code such as
// required, notFound or outsideProject, which the host words beside the field.
type RunFieldError struct {
	Field string `json:"field"`
	Code  string `json:"code"`
}

// RunConfigurationSave is a `runConfig.saveConfiguration` request. RunType and
// RunTypePlugins are set for a declared kind, whose display name is the default
// configuration name.
type RunConfigurationSave struct {
	Root            string                     `json:"root"`
	Provider        string                     `json:"provider"`
	RunType         *RunTypeKey                `json:"runType,omitempty"`
	ConfigurationID string                     `json:"configurationId,omitempty"`
	Values          map[string]json.RawMessage `json:"values"`
	Plugins         []RunInstalledPlugin       `json:"plugins,omitempty"`
	RunTypePlugins  *RunTypePlugins            `json:"runTypePlugins,omitempty"`
}

// RunConfigurationSaved is the answer of `runConfig.saveConfiguration`: Status
// "invalid" with Errors, or "saved" with the configuration's ID and the file
// changes that save it.
type RunConfigurationSaved struct {
	Status  string            `json:"status"`
	Errors  []RunFieldError   `json:"errors"`
	ID      string            `json:"id"`
	Changes []RunConfigChange `json:"changes"`
}

// SaveRunConfiguration validates an editor form's values and returns field errors or the
// file changes that save it. Core writes nothing.
func (c *Client) SaveRunConfiguration(ctx context.Context, request RunConfigurationSave) (RunConfigurationSaved, error) {
	var result RunConfigurationSaved
	err := c.Execute(ctx, "runConfig.saveConfiguration", request, &result)
	return result, err
}

// DeleteRunConfiguration returns the file changes that remove a saved `user:`
// configuration from every layer.
func (c *Client) DeleteRunConfiguration(ctx context.Context, root, configurationID string, plugins []RunInstalledPlugin) ([]RunConfigChange, error) {
	var result struct {
		Changes []RunConfigChange `json:"changes"`
	}
	err := c.Execute(ctx, "runConfig.deleteConfiguration", struct {
		Root            string               `json:"root"`
		ConfigurationID string               `json:"configurationId"`
		Plugins         []RunInstalledPlugin `json:"plugins,omitempty"`
	}{root, configurationID, plugins}, &result)
	return result.Changes, err
}

// CopyRunConfiguration returns the new `user:` ID of a copy of configuration
// configurationID named name, and the file changes that save it. Any configuration
// can be copied; copying a generated build provider run also saves the original in
// the local layer, so the copy does not take its place.
func (c *Client) CopyRunConfiguration(ctx context.Context, root, configurationID, name string, plugins []RunInstalledPlugin) (string, []RunConfigChange, error) {
	var result struct {
		ID      string            `json:"id"`
		Changes []RunConfigChange `json:"changes"`
	}
	err := c.Execute(ctx, "runConfig.copyConfiguration", struct {
		Root            string               `json:"root"`
		ConfigurationID string               `json:"configurationId"`
		Name            string               `json:"name"`
		Plugins         []RunInstalledPlugin `json:"plugins,omitempty"`
	}{root, configurationID, name, plugins}, &result)
	return result.ID, result.Changes, err
}

// RunConfigArrangement is a `runConfig.arrange` request. Folders maps configuration
// IDs to the folder each moves to, nil taking it out of its folder; Order replaces
// the saved manual order and SortAlphabetically the sort choice when set.
type RunConfigArrangement struct {
	Root               string               `json:"root"`
	Folders            map[string]*string   `json:"folders,omitempty"`
	Order              []string             `json:"order,omitempty"`
	SortAlphabetically *bool                `json:"sortAlphabetically,omitempty"`
	Plugins            []RunInstalledPlugin `json:"plugins,omitempty"`
}

// ArrangeRunConfigurations returns the file changes that move configurations between
// folders and save the list's order. A folder is saved with the configuration, the
// order on this machine only.
func (c *Client) ArrangeRunConfigurations(ctx context.Context, request RunConfigArrangement) ([]RunConfigChange, error) {
	var result struct {
		Changes []RunConfigChange `json:"changes"`
	}
	err := c.Execute(ctx, "runConfig.arrange", request, &result)
	return result.Changes, err
}

// RunPlanExecutable is the program a launch plan starts: Command, a name looked
// up on the PATH of the launch environment; Path, a native absolute path; or
// Toolchain, a runtime the host resolves from its toolchain registry.
type RunPlanExecutable struct {
	Command   string `json:"command,omitempty"`
	Path      string `json:"path,omitempty"`
	Toolchain string `json:"toolchain,omitempty"`
}

// RunInlineScript is a script saved as text: the host writes Content to Path
// before starting and removes the file once the process exits.
type RunInlineScript struct {
	Path    string `json:"path"`
	Content string `json:"content"`
}

// RunLaunchPlan is the platform-neutral process `runConfig.createLaunchPlan`
// plans. WorkingDirectory is project-relative with '/'. Environment holds
// toolchain-derived values and Env the configuration's own variables.
// CommandLine, set for batch scripts, is the exact Windows command line the
// host passes unchanged instead of quoting Arguments itself.
type RunLaunchPlan struct {
	Executable       RunPlanExecutable `json:"executable"`
	Arguments        []string          `json:"arguments"`
	WorkingDirectory string            `json:"workingDirectory"`
	Environment      map[string]string `json:"environment"`
	Env              map[string]string `json:"env"`
	InlineScript     *RunInlineScript  `json:"inlineScript,omitempty"`
	CommandLine      string            `json:"commandLine,omitempty"`
}

// CreateRunLaunchPlan plans one effective configuration for this platform.
// inlineScriptBase is an absolute path prefix in a host-owned temporary
// directory for a script saved as text; Core appends the script's suffix.
func (c *Client) CreateRunLaunchPlan(ctx context.Context, root, configurationID, inlineScriptBase string) (RunLaunchPlan, error) {
	var result RunLaunchPlan
	err := c.Execute(ctx, "runConfig.createLaunchPlan", struct {
		Root             string `json:"root"`
		ConfigurationID  string `json:"configurationId"`
		InlineScriptBase string `json:"inlineScriptBase,omitempty"`
	}{root, configurationID, inlineScriptBase}, &result)
	return result, err
}
