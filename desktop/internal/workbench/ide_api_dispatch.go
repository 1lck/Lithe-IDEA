package workbench

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// This file serves the IDE API's tools. A tool call arrives on the broker's goroutine; the
// work it needs from the window (the detected build instances, the selected task, the
// bounded output) is posted to the window thread and answered over a channel, so the
// broker never reads or changes page state itself. Every action is the same function the
// Build tool window calls; this file only identifies the target and reports the execution.

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

// ideAPILaunchWait bounds how long a run start waits for its execution to leave preparation
// before it answers. A slower preparation answers with the preparing execution, whose state
// the operations list reports later. It stays well inside ideAPICallTimeout, since the loop
// serves one call at a time.
const ideAPILaunchWait = 5 * time.Second

// ideAPIToolExposure is the Core selection matching ideAPIServedTools. No argument
// narrowing is requested, so every served tool keeps its canonical schema.
func ideAPIToolExposure() []core.IDEToolExposure {
	exposure := make([]core.IDEToolExposure, 0, len(ideAPIServedTools))
	for _, name := range ideAPIServedTools {
		exposure = append(exposure, core.IDEToolExposure{Name: name})
	}
	return exposure
}

// ideAPIOperation is the IDE identity and state of one Build window execution, a task or a
// run, whether the window or a tool call started it. The project keeps only the latest one:
// a new execution expires the previous ID, as a reopened project expires all of them.
// State is preparing, running, stopping, completed, failed or cancelled; ExitCode stays nil
// unless the execution reported one. Every field belongs to the window thread except
// launched, which is created with the record and closed once.
type ideAPIOperation struct {
	ID       string
	Label    string
	State    string
	ExitCode *int
	// ConfigurationID names the run configuration a run started, so restart can reuse it.
	// Build executions leave it empty.
	ConfigurationID string
	// failure is why an execution that never launched failed; a start reports it.
	failure string
	// startSequence and endSequence bound the execution's lines in the Build output;
	// endSequence is -1 while it is active.
	startSequence, endSequence int
	// launched is closed when the execution leaves preparation, however it does.
	launched chan struct{}
}

// terminal reports whether the execution ended.
func (o *ideAPIOperation) terminal() bool {
	return o != nil && (o.State == "completed" || o.State == "failed" || o.State == "cancelled")
}

// leavePreparing releases a start waiting for the execution's launch.
func (o *ideAPIOperation) leavePreparing() {
	if o.State == "preparing" {
		close(o.launched)
	}
}

// start marks a prepared execution as running: its process or provider request exists.
func (o *ideAPIOperation) start() {
	if o == nil || o.State != "preparing" {
		return
	}
	o.leavePreparing()
	o.State = "running"
}

// stopping marks an active execution as asked to stop. Its terminal event settles it.
func (o *ideAPIOperation) stopping() {
	if o == nil || o.terminal() {
		return
	}
	o.leavePreparing()
	o.State = "stopping"
}

// settle ends the execution with its final state and exit code, end being the sequence after
// its last output line. failure is kept for a failed execution that never launched. A settled
// execution keeps its first ending.
func (o *ideAPIOperation) settle(state string, exitCode *int, end int, failure string) {
	if o == nil || o.terminal() {
		return
	}
	o.leavePreparing()
	o.State, o.ExitCode, o.endSequence = state, exitCode, end
	if state == "failed" {
		o.failure = failure
	}
}

// recordIDEOperation gives a new execution of the project its IDE identity and makes it the
// latest one. kind is "build" or "run". IDs carry the project's epoch, so an ID of a project
// that was closed and reopened is recognised as expired, never as an execution of this one.
func (p *project) recordIDEOperation(kind, label, configuration string) *ideAPIOperation {
	if p.ideAPI.epoch == "" {
		var random [6]byte
		_, _ = rand.Read(random[:])
		p.ideAPI.epoch = hex.EncodeToString(random[:])
	}
	p.ideAPI.nextOperation++
	operation := &ideAPIOperation{
		ID:              fmt.Sprintf("ide-%s-%s-%d", kind, p.ideAPI.epoch, p.ideAPI.nextOperation),
		Label:           label,
		State:           "preparing",
		ConfigurationID: configuration,
		startSequence:   p.build.outputSequence,
		endSequence:     -1,
		launched:        make(chan struct{}),
	}
	p.ideAPI.current = operation
	return operation
}

// ideAPIOperationByID finds the execution id names. Only the latest execution is retained: an
// ID this client issued earlier, in this project or before it was reopened, is expired, and
// anything else is unknown.
func (p *project) ideAPIOperationByID(id string) (*ideAPIOperation, map[string]any) {
	if current := p.ideAPI.current; current != nil && current.ID == id {
		return current, nil
	}
	if p.ideAPI.issued(id) {
		return nil, ideAPIFailure("OPERATION_EXPIRED", "The operation was replaced by a newer execution or its project was reopened")
	}
	return nil, ideAPIFailure("NOT_FOUND", "Unknown operation")
}

// issued reports whether id has the shape of an operation ID this client issues and was
// issued: in this project when it carries the project's epoch, or before a reopen otherwise.
func (s *ideAPIState) issued(id string) bool {
	rest, ok := strings.CutPrefix(id, "ide-")
	if !ok {
		return false
	}
	kind, rest, ok := strings.Cut(rest, "-")
	if !ok || kind != "build" && kind != "run" {
		return false
	}
	epoch, number, ok := strings.Cut(rest, "-")
	n, err := strconv.Atoi(number)
	if !ok || err != nil || n < 1 || strconv.Itoa(n) != number || len(epoch) != 12 {
		return false
	}
	if _, err := hex.DecodeString(epoch); err != nil {
		return false
	}
	return epoch != s.epoch || n <= s.nextOperation
}

// ideAPIOperationSnapshot describes one execution. With output it carries every line of the
// execution the bounded Build output still holds; Core pages it.
func (p *project) ideAPIOperationSnapshot(operation *ideAPIOperation, output bool) map[string]any {
	entry := map[string]any{
		"operationID": operation.ID,
		"label":       operation.Label,
		"state":       operation.State,
		"exitCode":    nil,
	}
	if operation.ExitCode != nil {
		entry["exitCode"] = *operation.ExitCode
	}
	if operation.ConfigurationID != "" {
		entry["configurationID"] = operation.ConfigurationID
	}
	if output {
		entry["output"] = p.ideAPIOperationText(operation)
	}
	return entry
}

// ideAPIOperationText joins the execution's lines the bounded output still holds. Lines that
// were trimmed are missing from the front, so a cursor into them no longer matches and Core
// reports the discontinuity.
func (p *project) ideAPIOperationText(operation *ideAPIOperation) string {
	first := p.build.outputStart
	start := max(operation.startSequence, first)
	end := p.build.outputSequence
	if operation.endSequence >= 0 {
		end = min(end, operation.endSequence)
	}
	if start >= end {
		return ""
	}
	return strings.Join(p.build.output[start-first:end-first], "")
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
			return ideAPIFailure("NOT_FOUND", "Unknown build instance")
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
		return a.ideAPIOnProjectLater(ctx, conn, func(p *project) (<-chan any, any) {
			return a.ideAPIBuildConfigure(p, args.InstanceID, args.OptionID, args.Value)
		})
	case "lithe_build_execute":
		var args ideAPIBuildExecuteArguments
		if err := ideAPIDecodeArguments(arguments, &args); err != nil {
			return ideAPIFailure("INVALID_ARGUMENTS", "The arguments are not valid")
		}
		if args.InstanceID == "" || args.TaskID == "" && args.ModelTaskID == "" {
			return ideAPIFailure("INVALID_ARGUMENTS", "instanceID and a task identity are required")
		}
		if args.ModelTaskID != "" && args.TargetID != "" {
			return ideAPIFailure("INVALID_ARGUMENTS", "A target cannot be supplied with a model task")
		}
		return a.ideAPIOnProject(ctx, conn, func(p *project) any {
			operation, failure := a.ideAPIBuildExecute(p, args)
			if failure != nil {
				return failure
			}
			return map[string]any{"operationID": operation.ID, "state": operation.State}
		})
	case "lithe_run_list":
		return a.ideAPIOnProject(ctx, conn, func(p *project) any { return ideAPIRunList(p) })
	case "lithe_run_start":
		var args struct {
			ConfigurationID string `json:"configurationID"`
		}
		if err := ideAPIDecodeArguments(arguments, &args); err != nil || args.ConfigurationID == "" {
			return ideAPIFailure("INVALID_ARGUMENTS", "configurationID is required")
		}
		return a.ideAPIAwaitLaunch(ctx, conn, func(p *project) (*ideAPIOperation, any) {
			return a.ideAPIRunStart(p, args.ConfigurationID)
		})
	case "lithe_run_restart":
		var args struct {
			OperationID string `json:"operationID"`
		}
		if err := ideAPIDecodeArguments(arguments, &args); err != nil || args.OperationID == "" {
			return ideAPIFailure("INVALID_ARGUMENTS", "operationID is required")
		}
		return a.ideAPIAwaitLaunch(ctx, conn, func(p *project) (*ideAPIOperation, any) {
			return a.ideAPIRunRestart(p, args.OperationID)
		})
	case "lithe_operations_list":
		return a.ideAPIOnProject(ctx, conn, func(p *project) any {
			operations := []map[string]any{}
			if operation := p.ideAPI.current; operation != nil {
				operations = append(operations, p.ideAPIOperationSnapshot(operation, false))
			}
			return map[string]any{"operations": operations}
		})
	case "lithe_operation_output":
		var args struct {
			OperationID string `json:"operationID"`
			Cursor      string `json:"cursor"`
		}
		if err := ideAPIDecodeArguments(arguments, &args); err != nil || args.OperationID == "" {
			return ideAPIFailure("INVALID_ARGUMENTS", "operationID is required")
		}
		return a.ideAPIOperationOutput(ctx, conn, args.OperationID, args.Cursor)
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
	return ideAPIFailure("NOT_SUPPORTED", "This client does not serve this tool")
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
			answer <- ideAPIFailure("WORKSPACE_CLOSED", "The connected project is not open")
			return
		}
		answer <- fn(p)
	})
	select {
	case result := <-answer:
		return result
	case <-ctx.Done():
		return ideAPITimeout()
	}
}

// ideAPITimeout is the failure of a call that did not finish before its deadline. A mutation
// may still take effect, so the caller inspects the operations before retrying.
func ideAPITimeout() map[string]any {
	return ideAPIFailure("TIMEOUT", "The request did not finish before its deadline")
}

// ideAPIOnProjectLater runs fn on the window thread like ideAPIOnProject and then waits for the
// answer fn's work sends later on the channel it returned. fn answers at once with a failure
// instead when it refuses the call.
func (a *App) ideAPIOnProjectLater(ctx context.Context, conn *ideAPIConnection, fn func(*project) (<-chan any, any)) any {
	answer := a.ideAPIOnProject(ctx, conn, func(p *project) any {
		later, failure := fn(p)
		if failure != nil {
			return failure
		}
		return later
	})
	later, ok := answer.(<-chan any)
	if !ok {
		return answer
	}
	select {
	case result := <-later:
		return result
	case <-ctx.Done():
		return ideAPITimeout()
	}
}

// ideAPIAwaitLaunch starts an execution with start on the window thread and answers once it
// launched, or after ideAPILaunchWait with the state it reached. An execution that failed
// before it launched is answered with LAUNCH_FAILED and the reason.
func (a *App) ideAPIAwaitLaunch(ctx context.Context, conn *ideAPIConnection, start func(*project) (*ideAPIOperation, any)) any {
	answer := a.ideAPIOnProject(ctx, conn, func(p *project) any {
		operation, failure := start(p)
		if failure != nil {
			return failure
		}
		return operation
	})
	operation, ok := answer.(*ideAPIOperation)
	if !ok {
		return answer
	}
	wait := time.NewTimer(ideAPILaunchWait)
	defer wait.Stop()
	select {
	case <-operation.launched:
	case <-wait.C:
	case <-ctx.Done():
	}
	return a.ideAPIOnProject(ctx, conn, func(*project) any {
		if operation.State == "failed" && operation.failure != "" {
			return ideAPIFailure("LAUNCH_FAILED", operation.failure)
		}
		return map[string]any{"operationID": operation.ID, "state": operation.State}
	})
}

// ideAPIOperationOutput answers one page of an execution's output. The snapshot is taken on
// the window thread; Core pages it after cursor, so a cursor into output that was trimmed or
// belongs to other text reports reset instead of skipping or repeating lines.
func (a *App) ideAPIOperationOutput(ctx context.Context, conn *ideAPIConnection, id, cursor string) any {
	answer := a.ideAPIOnProject(ctx, conn, func(p *project) any {
		operation, failure := p.ideAPIOperationByID(id)
		if failure != nil {
			return failure
		}
		return ideAPISnapshot(p.ideAPIOperationSnapshot(operation, true))
	})
	snapshot, ok := answer.(ideAPISnapshot)
	if !ok {
		return answer
	}
	page, err := a.kernel.IDEHostOutputPage(ctx, map[string]any(snapshot), cursor)
	if err != nil {
		return ideAPIFailure("OPERATION_FAILED", err.Error())
	}
	return page
}

// ideAPISnapshot marks an operation snapshot apart from a failure, which has the same map type.
type ideAPISnapshot map[string]any

// ideAPIOperationStop asks the execution id names to stop. Only the window's current execution
// can be active, so a stop never reaches another one; an execution that already ended, or is
// already stopping, is answered with its state unchanged.
func (a *App) ideAPIOperationStop(p *project, id string) any {
	operation, failure := p.ideAPIOperationByID(id)
	if failure != nil {
		return failure
	}
	if !operation.terminal() && operation.State != "stopping" {
		if p.build.operation == nil || p.build.operation.ide != operation {
			return ideAPIFailure("OPERATION_EXPIRED", "The operation is no longer the window's execution")
		}
		a.stopBuildOperation(p)
	}
	return map[string]any{"operationID": operation.ID, "state": operation.State}
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
// execution path and returns the execution it reserved.
func (a *App) ideAPIBuildExecute(p *project, args ideAPIBuildExecuteArguments) (*ideAPIOperation, any) {
	index := -1
	for i := range p.build.instances {
		if p.build.instances[i].ID == args.InstanceID {
			index = i
			break
		}
	}
	if index < 0 {
		return nil, ideAPIFailure("NOT_FOUND", "Unknown build instance")
	}
	if p.build.operation != nil {
		return nil, ideAPIRefusal(errBuildBusy)
	}
	instance := &p.build.instances[index]
	// A model task names a decoded task; the model must be loaded before it can be
	// chosen. Declared tasks need no model.
	taskID := args.TaskID
	if args.ModelTaskID != "" {
		if !instance.modelLoaded {
			return nil, ideAPIFailure("NOT_READY", "Reload the build plugin model before running a model task")
		}
		taskID = args.ModelTaskID
	}
	task, modelTask := buildTaskByID(instance, taskID)
	if task == nil && modelTask == nil {
		return nil, ideAPIFailure("NOT_FOUND", "Unknown build task")
	}
	if task != nil && task.RequiresUserArguments && len(args.UserArguments) == 0 {
		return nil, ideAPIFailure("INVALID_ARGUMENTS", "This task requires user arguments")
	}
	// Make the requested instance the Build window's selection so the shared run path
	// prepares that plugin's model and tool, not whatever the window selected before.
	a.selectBuildInstance(p, index)
	operation, err := a.runBuildTask(p, args.ProjectID, args.TargetID, taskID, args.UserArguments)
	if err != nil {
		return nil, ideAPIRefusal(err)
	}
	return operation.ide, nil
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
