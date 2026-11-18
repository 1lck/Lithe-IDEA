package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
)

// RunBeforeLaunch is what `runConfig.beforeLaunch` answers: Status "ok" with the
// steps to run in order and, when a project file names them, the Confirmation to
// ask for; or "rejected" with the Refusal of the step that cannot run.
type RunBeforeLaunch struct {
	Status       string                       `json:"status"`
	Steps        []RunBeforeLaunchItem        `json:"steps"`
	Confirmation *RunBeforeLaunchConfirmation `json:"confirmation"`
	Refusal      *RunBeforeLaunchRefusal      `json:"refusal"`
}

// RunBeforeLaunchItem is one step to start before the configuration: a run (its
// ConfigurationID) or a plugin Task with the WorkingDirectory it runs in, with the
// step's name and a line naming what it starts, shown in the confirmation.
type RunBeforeLaunchItem struct {
	ConfigurationID  string            `json:"configurationId,omitempty"`
	Task             *RunTaskReference `json:"task,omitempty"`
	WorkingDirectory string            `json:"workingDirectory,omitempty"`
	Name             string            `json:"name"`
	Summary          string            `json:"summary"`
}

// RunBeforeLaunchConfirmation identifies a list of steps a project file names; the
// host asks once per Fingerprint before running it.
type RunBeforeLaunchConfirmation struct {
	Fingerprint string `json:"fingerprint"`
}

// RunBeforeLaunchRefusal is why the steps cannot run: Code is notFound,
// notAllowed, unavailable, cycle, tooLong, taskNotDeclared or invalidTaskValues,
// about step ConfigurationID, or for a task the configuration whose list names it
// with the Task set.
type RunBeforeLaunchRefusal struct {
	Code            string      `json:"code"`
	ConfigurationID string      `json:"configurationId"`
	Task            *RunTypeKey `json:"task,omitempty"`
}

// RunTaskReference is a plugin task step as a configuration saves it: the kind a
// plugin declares and the values of its fields by declared field ID, kept raw so
// the host sends them back unchanged.
type RunTaskReference struct {
	RunTypeKey
	Values json.RawMessage `json:"values,omitempty"`
}

// RunTaskStep is a task step of a `beforeLaunch` editor value: the saved Task, its
// Name and Summary, and the form Values of its fields by `field:<id>`. Missing says
// no installed plugin declares it; the editor shows and keeps it, without values.
type RunTaskStep struct {
	Task    RunTaskReference           `json:"task"`
	Name    string                     `json:"name"`
	Summary string                     `json:"summary"`
	Values  map[string]json.RawMessage `json:"values,omitempty"`
	Missing bool                       `json:"missing,omitempty"`
}

// RunBeforeLaunchEntry is one item of a `beforeLaunch` editor value: the ID of a
// configuration to run, or a plugin Task. Its JSON is the ID string or the task
// object, as Core sends and takes them.
type RunBeforeLaunchEntry struct {
	ConfigurationID string
	Task            *RunTaskStep
}

// MarshalJSON writes the configuration ID, or the task object.
func (e RunBeforeLaunchEntry) MarshalJSON() ([]byte, error) {
	if e.Task != nil {
		return json.Marshal(e.Task)
	}
	return json.Marshal(e.ConfigurationID)
}

// UnmarshalJSON reads a configuration ID string or a task object.
func (e *RunBeforeLaunchEntry) UnmarshalJSON(data []byte) error {
	data = bytes.TrimSpace(data)
	switch {
	case len(data) > 0 && data[0] == '"':
		*e = RunBeforeLaunchEntry{}
		return json.Unmarshal(data, &e.ConfigurationID)
	case len(data) > 0 && data[0] == '{':
		var task RunTaskStep
		if err := json.Unmarshal(data, &task); err != nil {
			return err
		}
		*e = RunBeforeLaunchEntry{Task: &task}
		return nil
	}
	return errors.New("a beforeLaunch item is a configuration ID or a task")
}

// RunTaskKind is a kind of task step installed plugins declare, as a `beforeLaunch`
// editor field offers it: its RunType, translated DisplayName, Description and
// Icon, and the Fields and default Values of its own form, keyed `field:<id>`.
type RunTaskKind struct {
	RunType     RunTypeKey                 `json:"runType"`
	DisplayName string                     `json:"displayName"`
	Description string                     `json:"description,omitempty"`
	Icon        *RunTypeIcon               `json:"icon,omitempty"`
	Fields      []RunEditorField           `json:"fields"`
	Values      map[string]json.RawMessage `json:"values"`
}

// RunBeforeLaunch expands the built-in process runs and plugin tasks
// configurationID starts first. Plugins are the enabled plugins that declare
// tasks; without them every task step is refused as taskNotDeclared.
func (c *Client) RunBeforeLaunch(ctx context.Context, root, configurationID string, plugins *RunTypePlugins) (RunBeforeLaunch, error) {
	var result RunBeforeLaunch
	err := c.Execute(ctx, "runConfig.beforeLaunch", struct {
		Root            string          `json:"root"`
		ConfigurationID string          `json:"configurationId"`
		RunTypePlugins  *RunTypePlugins `json:"runTypePlugins,omitempty"`
	}{root, configurationID, plugins}, &result)
	return result, err
}

// RunTaskCheck is what `runConfig.checkBeforeLaunchTask` answers: Status "ok" with
// the Step to put in the editor value, or "invalid" with field Errors.
type RunTaskCheck struct {
	Status string          `json:"status"`
	Step   *RunTaskStep    `json:"step"`
	Errors []RunFieldError `json:"errors"`
}

// CheckBeforeLaunchTask checks the form values of a task step being added or
// edited. Nothing is written; the step is saved with the configuration.
func (c *Client) CheckBeforeLaunchTask(ctx context.Context, root string, runType RunTypeKey, values map[string]json.RawMessage, plugins *RunTypePlugins) (RunTaskCheck, error) {
	var result RunTaskCheck
	err := c.Execute(ctx, "runConfig.checkBeforeLaunchTask", struct {
		Root           string                     `json:"root"`
		RunType        RunTypeKey                 `json:"runType"`
		Values         map[string]json.RawMessage `json:"values,omitempty"`
		RunTypePlugins *RunTypePlugins            `json:"runTypePlugins,omitempty"`
	}{root, runType, values, plugins}, &result)
	return result, err
}

// RunBeforeLaunchField is the `beforeLaunch` editor field of a saved configuration:
// the runs a step may name, the task kinds plugins declare and the effective list.
type RunBeforeLaunchField struct {
	Candidates []RunConfigurationName `json:"candidates"`
	Tasks      []RunTaskKind          `json:"tasks"`
	Value      []RunBeforeLaunchEntry `json:"value"`
}

// BeforeLaunchField reads the `beforeLaunch` field of the saved configurationID for
// an editor that does not use `runConfig.editorForm`, such as that of a build run.
func (c *Client) BeforeLaunchField(ctx context.Context, root, configurationID string, plugins *RunTypePlugins) (RunBeforeLaunchField, error) {
	var result RunBeforeLaunchField
	err := c.Execute(ctx, "runConfig.beforeLaunchField", struct {
		Root            string          `json:"root"`
		ConfigurationID string          `json:"configurationId"`
		RunTypePlugins  *RunTypePlugins `json:"runTypePlugins,omitempty"`
	}{root, configurationID, plugins}, &result)
	return result, err
}
