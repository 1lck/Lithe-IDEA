package workbench

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// This file serves the IDE API's tools. A tool call arrives on the broker's goroutine; the
// work it needs from the window (the detected build instances, the selected task, the
// bounded output) is posted to the window thread and answered over a channel, so the
// broker never reads or changes page state itself. Every action is the same function the
// Build tool window calls; this file only identifies the target and records the execution.

// ideAPIServedTools are the tools this client serves. A tool that is not listed is not
// advertised to the helper's clients and is refused by Core's validate: the list is the
// capability claim, not a documentation hint.
var ideAPIServedTools = []string{
	"lithe_project_inspect",
	"lithe_build_inspect",
	"lithe_build_reload",
	"lithe_build_configure",
	"lithe_build_execute",
	"lithe_operations_list",
	"lithe_operation_output",
	"lithe_operation_stop",
	"lithe_run_list",
	"lithe_run_start",
	"lithe_run_restart",
}

// ideAPIToolExposure is the Core selection matching ideAPIServedTools. No argument
// narrowing is requested, so every served tool keeps its canonical schema.
func ideAPIToolExposure() []core.IDEToolExposure {
	exposure := make([]core.IDEToolExposure, 0, len(ideAPIServedTools))
	for _, name := range ideAPIServedTools {
		exposure = append(exposure, core.IDEToolExposure{Name: name})
	}
	return exposure
}

// ideAPIOperation is one Build execution a connection started, kept so its output and
// result can be read after the Build window moved on. State is running, succeeded,
// failed or cancelled; ExitCode is nil until a process reported one.
type ideAPIOperation struct {
	ID            string
	Label         string
	State         string
	ExitCode      *int
	startSequence int
	// ConfigurationID names the run configuration a run started, so restart can reuse it.
	// Build executions leave it empty.
	ConfigurationID string
}

// operation returns one recorded execution.
func (s *ideAPIState) operation(id string) *ideAPIOperation {
	for _, operation := range s.operations {
		if operation.ID == id {
			return operation
		}
	}
	return nil
}

// settleIDEOperations marks the running executions with how their build ended. Only
// running ones change, so a cancelled execution stays cancelled when the terminal event
// arrives later.
func (p *project) settleIDEOperations(state string, exitCode *int) {
	for _, operation := range p.ideAPI.operations {
		if operation.State == "running" {
			operation.State, operation.ExitCode = state, exitCode
		}
	}
}

// ideAPIDispatch runs one admitted tool and returns its result. The result is either the
// tool's value or the shared failure shape.
func (a *App) ideAPIDispatch(ctx context.Context, conn *ideAPIConnection, name string, arguments json.RawMessage) any {
	switch name {
	case "lithe_project_inspect":
		return map[string]any{
			"workspaceKey": conn.workspaceKey,
			"permissions":  conn.permissions,
			"tools":        ideAPIServedTools,
		}
	case "lithe_build_inspect":
		return a.ideAPIOnProject(ctx, conn, func(p *project) any { return ideAPIBuildInspect(p) })
	case "lithe_build_reload":
		var args struct {
			InstanceID string `json:"instanceID"`
		}
		if err := ideAPIDecodeArguments(arguments, &args); err != nil || args.InstanceID == "" {
			return ideAPIFailure("INVALID_ARGUMENTS", "instanceID is required")
		}
		return a.ideAPIOnProject(ctx, conn, func(p *project) any {
			for index := range p.build.instances {
				if p.build.instances[index].ID != args.InstanceID {
					continue
				}
				a.reloadBuildModel(p, index)
				return map[string]any{"instanceID": args.InstanceID, "reloading": true}
			}
			return ideAPIFailure("INVALID_ARGUMENTS", "Unknown build instance")
		})
	case "lithe_build_configure":
		var args struct {
			InstanceID string          `json:"instanceID"`
			OptionID   string          `json:"optionID"`
			Value      json.RawMessage `json:"value"`
		}
		if err := ideAPIDecodeArguments(arguments, &args); err != nil || args.InstanceID == "" || args.OptionID == "" {
			return ideAPIFailure("INVALID_ARGUMENTS", "instanceID and optionID are required")
		}
		return a.ideAPIOnProject(ctx, conn, func(p *project) any { return a.ideAPIBuildConfigure(p, args.InstanceID, args.OptionID, args.Value) })
	case "lithe_build_execute":
		var args ideAPIBuildExecuteArguments
		if err := ideAPIDecodeArguments(arguments, &args); err != nil {
			return ideAPIFailure("INVALID_ARGUMENTS", "The arguments are not valid")
		}
		if args.InstanceID == "" || args.TaskID == "" && args.ModelTaskID == "" {
			return ideAPIFailure("INVALID_ARGUMENTS", "instanceID and a task identity are required")
		}
		return a.ideAPIOnProject(ctx, conn, func(p *project) any { return a.ideAPIBuildExecute(p, args) })
	case "lithe_run_list":
		return a.ideAPIOnProject(ctx, conn, func(p *project) any { return ideAPIRunList(p) })
	case "lithe_run_start":
		var args struct {
			ConfigurationID string `json:"configurationID"`
		}
		if err := ideAPIDecodeArguments(arguments, &args); err != nil || args.ConfigurationID == "" {
			return ideAPIFailure("INVALID_ARGUMENTS", "configurationID is required")
		}
		return a.ideAPIOnProject(ctx, conn, func(p *project) any { return a.ideAPIRunStart(p, args.ConfigurationID) })
	case "lithe_run_restart":
		var args struct {
			OperationID string `json:"operationID"`
		}
		if err := ideAPIDecodeArguments(arguments, &args); err != nil || args.OperationID == "" {
			return ideAPIFailure("INVALID_ARGUMENTS", "operationID is required")
		}
		return a.ideAPIOnProject(ctx, conn, func(p *project) any { return a.ideAPIRunRestart(p, args.OperationID) })
	case "lithe_operations_list":
		return a.ideAPIOnProject(ctx, conn, func(p *project) any { return ideAPIOperationsList(p) })
	case "lithe_operation_output":
		var args struct {
			OperationID string `json:"operationID"`
			Cursor      string `json:"cursor"`
		}
		if err := ideAPIDecodeArguments(arguments, &args); err != nil || args.OperationID == "" {
			return ideAPIFailure("INVALID_ARGUMENTS", "operationID is required")
		}
		return a.ideAPIOnProject(ctx, conn, func(p *project) any {
			return ideAPIOperationOutput(p, args.OperationID, args.Cursor)
		})
	case "lithe_operation_stop":
		var args struct {
			OperationID string `json:"operationID"`
		}
		if err := ideAPIDecodeArguments(arguments, &args); err != nil || args.OperationID == "" {
			return ideAPIFailure("INVALID_ARGUMENTS", "operationID is required")
		}
		return a.ideAPIOnProject(ctx, conn, func(p *project) any {
			return a.ideAPIOperationStop(p, args.OperationID)
		})
	}
	return ideAPIFailure("NOT_AVAILABLE", "This tool is not available in this client yet")
}

// ideAPIDecodeArguments decodes a tool's arguments; empty or null is an empty object.
func ideAPIDecodeArguments(arguments json.RawMessage, target any) error {
	if len(arguments) == 0 || string(arguments) == "null" {
		return nil
	}
	return json.Unmarshal(arguments, target)
}

// ideAPIOnProject runs fn on the window thread for the project the connection belongs to
// and waits for its answer. A closed or replaced project is refused instead of acting on
// whatever is open now.
func (a *App) ideAPIOnProject(ctx context.Context, conn *ideAPIConnection, fn func(*project) any) any {
	answer := make(chan any, 1)
	a.post(func(a *App) {
		p := a.project
		if p == nil || filepath.Clean(p.root) != filepath.Clean(conn.workspaceKey) {
			answer <- ideAPIFailure("NO_PROJECT", "The connected project is not open")
			return
		}
		answer <- fn(p)
	})
	select {
	case result := <-answer:
		return result
	case <-ctx.Done():
		return ideAPIFailure("CANCELLED", "The request did not finish before its deadline")
	}
}

// ideAPIBuildExecuteArguments is the lithe_build_execute input.
type ideAPIBuildExecuteArguments struct {
	InstanceID    string   `json:"instanceID"`
	TaskID        string   `json:"taskID"`
	ProjectID     string   `json:"projectID"`
	TargetID      string   `json:"targetID"`
	ModelTaskID   string   `json:"modelTaskID"`
	UserArguments []string `json:"userArguments"`
}

// ideAPIBuildInspect reports the detected build plugins and their identities without
// running any tooling. Only the selected instance carries the current selection; every
// instance carries the decoded model it has.
func ideAPIBuildInspect(p *project) any {
	instances := make([]map[string]any, 0, len(p.build.instances))
	for index := range p.build.instances {
		instance := &p.build.instances[index]
		declared := make([]map[string]any, 0, len(instance.System.Tasks))
		for _, task := range instance.System.Tasks {
			if task.FromModel {
				continue
			}
			declared = append(declared, map[string]any{
				"taskID":                task.ID,
				"displayName":           task.DisplayName,
				"group":                 task.Group,
				"scopes":                task.Scopes,
				"execution":             task.Source,
				"requiresUserArguments": task.RequiresUserArguments,
			})
		}
		projects, targets, modelTasks := ideAPIBuildModelLists(instance)
		entry := map[string]any{
			"instanceID":     instance.ID,
			"pluginID":       instance.PluginID,
			"buildSystemID":  instance.BuildSystemID,
			"displayName":    instance.DisplayName,
			"root":           instance.Root,
			"selected":       index == p.build.selected,
			"modelSource":    instance.ModelSource,
			"modelLoaded":    instance.modelLoaded,
			"modelLoading":   instance.modelLoading,
			"modelError":     instance.modelError,
			"declaredTasks":  declared,
			"projects":       projects,
			"targets":        targets,
			"modelTasks":     modelTasks,
			"options":        instance.Options,
			"droppedOptions": instance.DroppedOptions,
		}
		instances = append(instances, entry)
	}
	selected := map[string]any{
		"projectID":  p.build.projectID,
		"targetID":   p.build.targetID,
		"taskID":     p.build.taskID,
		"instanceID": "",
	}
	if instance := p.selectedBuildInstance(); instance != nil {
		selected["instanceID"] = instance.ID
	}
	running := false
	if p.build.operation != nil {
		running = true
	}
	return map[string]any{
		"instances": instances,
		"selected":  selected,
		"loaded":    p.build.loaded,
		"loading":   p.build.loading,
		"failed":    p.build.failed,
		"running":   running,
	}
}

// ideAPIBuildModelLists decodes the identity lists of one instance's model.
func ideAPIBuildModelLists(instance *buildInstance) (projects, targets, tasks []map[string]any) {
	projects, targets, tasks = []map[string]any{}, []map[string]any{}, []map[string]any{}
	if !instance.modelLoaded {
		return projects, targets, tasks
	}
	for _, project := range instance.Model.Projects {
		projects = append(projects, map[string]any{
			"projectID": project.ID, "name": project.Name, "path": project.Path, "displayName": project.DisplayName,
		})
	}
	for _, target := range instance.Model.Targets {
		targets = append(targets, map[string]any{
			"targetID": target.ID, "projectID": target.ProjectID, "name": target.Name, "path": target.Path, "tags": target.Tags,
		})
	}
	for _, task := range instance.Model.Tasks {
		tasks = append(tasks, map[string]any{
			"taskID": task.ID, "projectID": task.ProjectID, "name": task.Name, "path": task.Path,
			"displayName": task.DisplayName, "execution": task.Execution,
		})
	}
	return projects, targets, tasks
}

// ideAPIBuildExecute starts one declared or model task through the Build window's own
// execution path and records it as an IDE operation.
func (a *App) ideAPIBuildExecute(p *project, args ideAPIBuildExecuteArguments) any {
	index := -1
	for i := range p.build.instances {
		if p.build.instances[i].ID == args.InstanceID {
			index = i
			break
		}
	}
	if index < 0 {
		return ideAPIFailure("INVALID_ARGUMENTS", "Unknown build instance")
	}
	if p.build.operation != nil {
		return ideAPIFailure("OPERATION_BUSY", "The Build window is already running an operation")
	}
	instance := &p.build.instances[index]
	// A model task names a decoded task; the model must be loaded before it can be
	// chosen. Declared tasks need no model.
	taskID := args.TaskID
	if args.ModelTaskID != "" {
		if !instance.modelLoaded {
			return ideAPIFailure("BUILD_MODEL_NOT_LOADED", "Reload the build plugin model before running a model task")
		}
		taskID = args.ModelTaskID
	}
	task, modelTask := buildTaskByID(instance, taskID)
	if task == nil && modelTask == nil {
		return ideAPIFailure("INVALID_ARGUMENTS", "Unknown build task")
	}
	if task != nil && task.RequiresUserArguments && len(args.UserArguments) == 0 {
		return ideAPIFailure("INVALID_ARGUMENTS", "This task requires user arguments")
	}
	// Make the requested instance the Build window's selection so the shared run path
	// prepares that plugin's model and tool, not whatever the window selected before.
	a.selectBuildInstance(p, index)
	if err := a.runBuildTask(p, args.ProjectID, args.TargetID, taskID, args.UserArguments); err != nil {
		return ideAPIFailure("INVALID_ARGUMENTS", err.Error())
	}
	p.ideAPI.nextOperation++
	operation := &ideAPIOperation{
		ID:            fmt.Sprintf("ide-build-%d", p.ideAPI.nextOperation),
		Label:         ideAPIBuildLabel(instance, taskID),
		State:         "running",
		startSequence: p.build.outputSequence,
	}
	p.ideAPI.operations = append(p.ideAPI.operations, operation)
	return map[string]any{"operationID": operation.ID, "state": operation.State}
}

// ideAPIBuildLabel names one execution in the operations list.
func ideAPIBuildLabel(instance *buildInstance, taskID string) string {
	if instance == nil {
		return taskID
	}
	if instance.DisplayName != "" {
		return instance.DisplayName + ": " + taskID
	}
	return instance.BuildSystemID + ": " + taskID
}

// ideAPIOperationsList reports every execution this connection started.
func ideAPIOperationsList(p *project) any {
	operations := make([]map[string]any, 0, len(p.ideAPI.operations))
	for _, operation := range p.ideAPI.operations {
		entry := map[string]any{
			"operationID": operation.ID,
			"label":       operation.Label,
			"state":       operation.State,
		}
		if operation.ExitCode != nil {
			entry["exitCode"] = *operation.ExitCode
		}
		operations = append(operations, entry)
	}
	return map[string]any{"operations": operations}
}

// ideAPIOperationOutput reads one execution's output from the bounded Build console.
// cursor is the last sequence number returned; text before it is never repeated and a
// trimmed console reports reset instead of pretending the output is complete.
func ideAPIOperationOutput(p *project, id, cursor string) any {
	operation := p.ideAPI.operation(id)
	if operation == nil {
		return ideAPIFailure("INVALID_ARGUMENTS", "Unknown operation")
	}
	start := operation.startSequence
	if cursor != "" {
		parsed, err := strconv.Atoi(cursor)
		if err != nil || parsed < 0 {
			return ideAPIFailure("INVALID_ARGUMENTS", "The cursor is not a sequence number")
		}
		start = parsed + 1
	}
	first := p.build.outputStart
	reset := false
	if start < first {
		start, reset = first, true
	}
	end := p.build.outputStart + len(p.build.output)
	if start > end {
		start = end
	}
	text := strings.Join(p.build.output[start-first:], "")
	next := start - 1
	if end > p.build.outputStart {
		next = end - 1
	}
	entry := map[string]any{
		"operationID": id,
		"state":       operation.State,
		"text":        text,
		"cursor":      strconv.Itoa(next),
		"reset":       reset,
	}
	if operation.ExitCode != nil {
		entry["exitCode"] = *operation.ExitCode
	}
	return entry
}

// ideAPIOperationStop stops the execution if it is still the one running.
func (a *App) ideAPIOperationStop(p *project, id string) any {
	operation := p.ideAPI.operation(id)
	if operation == nil {
		return ideAPIFailure("INVALID_ARGUMENTS", "Unknown operation")
	}
	if operation.State != "running" {
		return ideAPIFailure("OPERATION_NOT_RUNNING", "The operation already finished")
	}
	if p.build.operation == nil {
		// The console moved on (the process ended while the answer was in flight); never
		// apply the stop to a newer execution.
		p.settleIDEOperations("failed", nil)
		return ideAPIFailure("OPERATION_NOT_RUNNING", "The operation already finished")
	}
	a.stopBuildOperation(p)
	p.settleIDEOperations("cancelled", nil)
	return map[string]any{"operationID": id, "state": "cancelled"}
}
