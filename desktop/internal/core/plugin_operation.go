package core

import (
	"context"
	"errors"
	"sync/atomic"
	"time"
)

// PluginOperationName is one row of Core's table of declarative plugin contributions: work a
// plugin declares in its manifest that the host or a Core engine runs, so no plugin process can
// report it through lithe/log. The set is closed; Core refuses any other token.
type PluginOperationName string

// The contributions the host runs, written as Core's tokens. A command contribution reuses the
// SDK method name, so a declarative plugin logs the same work the way an SDK-backed one does.
const (
	// OperationLanguageServerStart is a languageServers[] start, from resolving the launch to
	// the initialize result. The host records what fails before it hands the start to Core.
	OperationLanguageServerStart PluginOperationName = "languageServer/start"
	// OperationDebugAdapterStart is a debugAdapters[] start, up to the adapter being reachable.
	OperationDebugAdapterStart PluginOperationName = "debugAdapter/start"
	// OperationBuildModel is one model load of a buildSystems[].model command source.
	OperationBuildModel PluginOperationName = "lithe/build/model"
	// OperationBuildTestDiscovery is one test discovery command.
	OperationBuildTestDiscovery PluginOperationName = "lithe/build/discoverTests"
	// OperationBuildDependencies is one dependency tree load of a command source.
	OperationBuildDependencies PluginOperationName = "lithe/build/dependencies"
	// OperationCommandInstallerInstall is one commandInstallers[] installation the user
	// confirmed, from planning it to finding its commands. A cancelled one is not recorded.
	OperationCommandInstallerInstall PluginOperationName = "commandInstaller/install"
)

// PluginStage is where an attempt failed. Core turns it into a code through the contribution's
// lifecycle, and refuses a stage the lifecycle cannot reach: a process start has no plan or
// decode stage, and a command run has no initialize stage.
type PluginStage string

// The stages, written as Core's tokens.
const (
	// StagePlan: the declared command plan could not be prepared.
	StagePlan PluginStage = "plan"
	// StageResolve: the declared executable or launch input could not be resolved.
	StageResolve PluginStage = "resolve"
	// StageLaunch: the resolved process could not be started.
	StageLaunch PluginStage = "launch"
	// StageInitialize: the protocol handshake failed after the process started.
	StageInitialize PluginStage = "initialize"
	// StageTimeout: the attempt ran past its deadline.
	StageTimeout PluginStage = "timeout"
	// StageExit: the process exited before it was ready, or a command exited nonzero.
	StageExit PluginStage = "exit"
	// StageDecode: the command output was not a valid document for the contract.
	StageDecode PluginStage = "decode"
)

// PluginOperation is the payload of diagnostics.recordPluginOperation: one terminal result of a
// declarative contribution the host ran. It carries no plugin output, path or error text.
type PluginOperation struct {
	PluginID  string              `json:"pluginId"`
	Operation PluginOperationName `json:"operation"`
	// Outcome is "finished" or "failed".
	Outcome string `json:"outcome"`
	// Stage is set exactly when the attempt failed; Core refuses it on a finished one.
	Stage PluginStage `json:"stage,omitempty"`
	// DurationMs is the attempt's monotonic duration.
	DurationMs int64 `json:"durationMs"`
	// OperationID is the op that correlates the attempt's other records. An absent one is
	// left out, since Core refuses an explicit null.
	OperationID string `json:"operationId,omitempty"`
}

// StartupOperation hands a language-server start the host began to Core, which then records
// its single result. It is the startupOperation of lsp.startServer.
type StartupOperation struct {
	PluginID    string `json:"pluginId"`
	OperationID string `json:"operationId"`
	// ElapsedMs is the time the host spent on the attempt before the handoff; Core adds its own.
	ElapsedMs int64 `json:"elapsedMs"`
}

// PluginAttempt times one attempt of a declarative contribution and makes sure it yields one
// result at most: the host's own, or Core's after a handoff. It is safe from any goroutine.
type PluginAttempt struct {
	pluginID    string
	operation   PluginOperationName
	operationID string
	started     time.Time
	// ended is set by the first result or handoff; every later one is ignored.
	ended atomic.Bool
	// handedOff tells that Core owns the result.
	handedOff atomic.Bool
}

// StartPluginAttempt starts timing an attempt of plugin's operation. operationID is the op of
// the action the attempt runs for; an empty one, or one outside the grammar Core accepts for an
// operation ID, gets a fresh op, since a handoff needs one.
func StartPluginAttempt(pluginID string, operation PluginOperationName, operationID string) *PluginAttempt {
	if !validAttemptID(operationID) {
		operationID = NewOperation()
	}
	return &PluginAttempt{pluginID: pluginID, operation: operation, operationID: operationID, started: time.Now()}
}

// OperationID is the op the attempt's result is recorded under.
func (a *PluginAttempt) OperationID() string {
	if a == nil {
		return ""
	}
	return a.operationID
}

// HandOff gives the attempt to Core and returns the startupOperation that does so. Nothing the
// host reports afterwards is recorded. It returns nil for a nil attempt or one already ended.
func (a *PluginAttempt) HandOff() *StartupOperation {
	if a == nil || !a.ended.CompareAndSwap(false, true) {
		return nil
	}
	a.handedOff.Store(true)
	return &StartupOperation{PluginID: a.pluginID, OperationID: a.operationID, ElapsedMs: a.elapsed()}
}

// HandedOff reports whether Core owns the attempt's result.
func (a *PluginAttempt) HandedOff() bool {
	return a != nil && a.handedOff.Load()
}

// Ended returns the result of an attempt that stopped with err, failing at stage, and whether
// it may be recorded. A nil err finishes the attempt. The attempt yields nothing when it was
// already ended or handed off, and when the user cancelled it: Core never records a
// cancellation. A deadline that ended it is a timeout, whatever stage it was at.
func (a *PluginAttempt) Ended(ctx context.Context, stage PluginStage, err error) (PluginOperation, bool) {
	if a == nil {
		return PluginOperation{}, false
	}
	if err != nil && (errors.Is(err, context.Canceled) || errors.Is(ctx.Err(), context.Canceled)) {
		return PluginOperation{}, false
	}
	if !a.ended.CompareAndSwap(false, true) {
		return PluginOperation{}, false
	}
	result := PluginOperation{
		PluginID:    a.pluginID,
		Operation:   a.operation,
		Outcome:     "finished",
		DurationMs:  a.elapsed(),
		OperationID: a.operationID,
	}
	if err == nil {
		return result, true
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded) {
		stage = StageTimeout
	}
	result.Outcome, result.Stage = "failed", stage
	return result, true
}

// Abandon ends the attempt without a result, for one the user stopped or a newer one replaced.
func (a *PluginAttempt) Abandon() {
	if a != nil {
		a.ended.Store(true)
	}
}

func (a *PluginAttempt) elapsed() int64 {
	return time.Since(a.started).Milliseconds()
}

// validAttemptID reports whether Core takes id as an operation ID: it must be in the SDK
// operationId grammar (1-128 ASCII letters, digits and ._:/-$) and also a bare record identity
// (letters, digits and ._:/@+-), so only letters, digits and ._:/- are left.
func validAttemptID(id string) bool {
	if id == "" || len(id) > 128 {
		return false
	}
	for i := 0; i < len(id); i++ {
		switch b := id[i]; {
		case 'a' <= b && b <= 'z', 'A' <= b && b <= 'Z', '0' <= b && b <= '9':
		case b == '.' || b == '_' || b == ':' || b == '/' || b == '-':
		default:
			return false
		}
	}
	return true
}

// RecordPluginOperation records one terminal result of a declarative plugin contribution the
// host ran. Core puts it on the plugin's plugins/<id>/host channel as plugins.operation.finished
// or plugins.operation.failed, next to what SDK-backed plugins report.
func (c *Client) RecordPluginOperation(ctx context.Context, operation PluginOperation) error {
	_, err := executeLog[struct{}](ctx, c, "diagnostics.recordPluginOperation", operation)
	return err
}
