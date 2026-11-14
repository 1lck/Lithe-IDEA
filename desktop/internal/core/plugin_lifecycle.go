package core

import "context"

// PluginLifecycleAction is what the user does to an installed plugin.
type PluginLifecycleAction string

// The actions plugins.installed.lifecycle plans.
const (
	// PluginConfirmInstall is the user confirming the installation of a version now on disk.
	PluginConfirmInstall PluginLifecycleAction = "confirmInstall"
	// PluginEnable is the user turning the plugin on.
	PluginEnable PluginLifecycleAction = "enable"
	// PluginDisable is the user turning the plugin off.
	PluginDisable PluginLifecycleAction = "disable"
	// PluginUninstall is the user removing the plugin.
	PluginUninstall PluginLifecycleAction = "uninstall"
)

// PluginNotInstalled is the rejection of an action on a plugin that has no installed version.
const PluginNotInstalled = "plugin.lifecycle.notInstalled"

// The kinds of PluginLifecycleStep, all on the action's plugin.
const (
	// PluginRecordChoice records the user's choice, Enabled.
	PluginRecordChoice = "recordChoice"
	// PluginForgetChoice drops the user's choice.
	PluginForgetChoice = "forgetChoice"
	// PluginStopPrograms stops the language server and the backend, returning once they ended
	// or gave up.
	PluginStopPrograms = "stopPrograms"
	// PluginRemoveVersion removes installed version Version, then forgets its approval; the
	// approval stays when the version could not be removed.
	PluginRemoveVersion = "removeVersion"
	// PluginRemoveState removes the state directory the plugin's programs wrote.
	PluginRemoveState = "removeState"
)

// PluginInstalledVersion is one installed plugin version, by identity only.
type PluginInstalledVersion struct {
	PluginID string `json:"pluginID"`
	Version  string `json:"version"`
}

// PluginEnablement is one plugin and whether it is enabled: a choice the user made, or a
// plugin's enablement as Core reports it.
type PluginEnablement struct {
	PluginID string `json:"pluginID"`
	Enabled  bool   `json:"enabled"`
}

// PluginLifecycleRequest is every installed version and every choice the user made, and the
// action, if any, on one plugin.
type PluginLifecycleRequest struct {
	Installed []PluginInstalledVersion
	Choices   []PluginEnablement
	// Action is empty when only enablement is asked for.
	Action   PluginLifecycleAction
	PluginID string
}

// PluginLifecycleStep is one thing the host does on the action's plugin.
type PluginLifecycleStep struct {
	Kind    string `json:"kind"`
	Enabled bool   `json:"enabled,omitempty"`
	Version string `json:"version,omitempty"`
}

// PluginLifecycle is Core's answer: every installed plugin with its enablement once the steps
// ran, whether they change the plugin's choice, and the steps in order. Rejection is set, and
// there are no steps, when the action does not apply.
type PluginLifecycle struct {
	Plugins   []PluginEnablement    `json:"plugins"`
	Changed   bool                  `json:"changed"`
	Steps     []PluginLifecycleStep `json:"steps"`
	Rejection string                `json:"rejection,omitempty"`
}

// PlanPluginLifecycle has Core report installed plugins' enablement and plan request's action
// (plugins.installed.lifecycle). The host keeps the packages, approvals, choices and programs
// and carries the steps out in order, reporting every failure.
func (c *Client) PlanPluginLifecycle(ctx context.Context, request PluginLifecycleRequest) (PluginLifecycle, error) {
	const command = "plugins.installed.lifecycle"
	type action struct {
		Kind     PluginLifecycleAction `json:"kind"`
		PluginID string                `json:"pluginID"`
	}
	payload := struct {
		Installed []PluginInstalledVersion `json:"installed"`
		Choices   []PluginEnablement       `json:"choices"`
		Action    *action                  `json:"action,omitempty"`
	}{Installed: request.Installed, Choices: request.Choices}
	if payload.Installed == nil {
		payload.Installed = []PluginInstalledVersion{}
	}
	if payload.Choices == nil {
		payload.Choices = []PluginEnablement{}
	}
	if request.Action != "" {
		payload.Action = &action{Kind: request.Action, PluginID: request.PluginID}
	}
	var result PluginLifecycle
	if err := c.Execute(ctx, command, payload, &result); err != nil {
		return PluginLifecycle{}, err
	}
	for _, step := range result.Steps {
		switch step.Kind {
		case PluginRecordChoice, PluginForgetChoice, PluginStopPrograms, PluginRemoveState:
		case PluginRemoveVersion:
			if step.Version == "" {
				return PluginLifecycle{}, newParseError(command, "a removeVersion step has no version", "")
			}
		default:
			return PluginLifecycle{}, newParseError(command, "unknown lifecycle step", step.Kind)
		}
	}
	return result, nil
}
