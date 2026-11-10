package core

import (
	"context"
	"encoding/base64"
	"encoding/json"
)

// DebugUpdate is one deterministic debug session reduction: the state after
// the input, DAP frames the host must write, and typed events. Core owns the
// protocol state; the host owns the adapter's bytes and process.
type DebugUpdate struct {
	SessionID      string       `json:"sessionId"`
	State          string       `json:"state"`
	OutboundFrames []string     `json:"outboundFrames"`
	Events         []DebugEvent `json:"events"`
}

// DebugEvent is one ordered event projected by Core. Type selects the meaning;
// fields that do not apply to it stay empty.
type DebugEvent struct {
	Sequence uint64 `json:"sequence"`
	Type     string `json:"type"`

	State string `json:"state,omitempty"`
	// Stopped events.
	Reason         string `json:"reason,omitempty"`
	ThreadID       *int64 `json:"threadId,omitempty"`
	Description    string `json:"description,omitempty"`
	StopGeneration uint64 `json:"stopGeneration,omitempty"`
	// Output events.
	Category string `json:"category,omitempty"`
	Output   string `json:"output,omitempty"`
	// Terminated events.
	ExitCode *int64 `json:"exitCode,omitempty"`
	// Operation completion and failure.
	OperationID string                `json:"operationId,omitempty"`
	Command     string                `json:"command,omitempty"`
	Code        string                `json:"code,omitempty"`
	Message     string                `json:"message,omitempty"`
	Result      *DebugOperationResult `json:"result,omitempty"`
	Breakpoint  *DebugBreakpoint      `json:"breakpoint,omitempty"`
	// Capabilities is set on the `capabilities` event: what the adapter negotiated.
	Capabilities *DebugCapabilities `json:"capabilities,omitempty"`
	// StartDebugging is set on the `startDebuggingRequested` event.
	RequestID      string               `json:"requestId,omitempty"`
	StartDebugging *DebugStartDebugging `json:"request,omitempty"`
	ChildSessionID string               `json:"childSessionId,omitempty"`
}

// DebugOperationResult is the typed terminal data of one inspect or execute
// operation. Kind is Core's result tag; only the matching fields are set.
type DebugOperationResult struct {
	Kind        string            `json:"kind"`
	Command     string            `json:"command,omitempty"`
	Threads     []DebugThread     `json:"threads,omitempty"`
	StackFrames []DebugStackFrame `json:"stackFrames,omitempty"`
	Scopes      []DebugScope      `json:"scopes,omitempty"`
	Variables   []DebugVariable   `json:"variables,omitempty"`
	// Variable is the replacement of a setVariable or the value of an evaluate.
	Variable *DebugVariable `json:"variable,omitempty"`
	// Instructions is the result of a disassemble inspection.
	Instructions []DebugInstruction `json:"instructions,omitempty"`
}

// DebugInstruction is one disassembled machine instruction. Address stays the
// adapter's text so a 64-bit address is never rounded.
type DebugInstruction struct {
	Address          string `json:"address"`
	InstructionBytes string `json:"instructionBytes,omitempty"`
	Instruction      string `json:"instruction"`
	Symbol           string `json:"symbol,omitempty"`
	SourcePath       string `json:"sourcePath,omitempty"`
	Line             *int64 `json:"line,omitempty"`
}

// DebugThread is one debuggee thread.
type DebugThread struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// DebugStackFrame is one call-stack frame with one-based source coordinates.
type DebugStackFrame struct {
	ID         int64  `json:"id"`
	Name       string `json:"name"`
	SourcePath string `json:"sourcePath,omitempty"`
	Line       int64  `json:"line"`
	Column     int64  `json:"column"`
	IsFiltered bool   `json:"isFiltered"`
	// InstructionPointerReference anchors the disassembly view on this frame.
	InstructionPointerReference string `json:"instructionPointerReference,omitempty"`
	SourceReference             *int64 `json:"sourceReference,omitempty"`
}

// DebugScope is one variable scope of the selected frame.
type DebugScope struct {
	Name               string `json:"name"`
	VariablesReference int64  `json:"variablesReference"`
	Expensive          bool   `json:"expensive"`
	NamedVariables     int64  `json:"namedVariables"`
	IndexedVariables   int64  `json:"indexedVariables"`
	// PresentationHint is DAP's arguments, locals or registers.
	PresentationHint string `json:"presentationHint,omitempty"`
}

// DebugVariable is one debugger variable value.
type DebugVariable struct {
	Name               string `json:"name"`
	Value              string `json:"value"`
	Type               string `json:"type,omitempty"`
	EvaluateName       string `json:"evaluateName,omitempty"`
	VariablesReference int64  `json:"variablesReference"`
	// NamedVariables and IndexedVariables are the adapter-reported child counts,
	// zero when unavailable; they size the variable paging plan.
	NamedVariables   int64 `json:"namedVariables"`
	IndexedVariables int64 `json:"indexedVariables"`
}

// DebugBreakpoint is an adapter-verified breakpoint location.
type DebugBreakpoint struct {
	ID            int64  `json:"id"`
	Verified      bool   `json:"verified"`
	Message       string `json:"message,omitempty"`
	SourcePath    string `json:"sourcePath,omitempty"`
	RequestedLine *int64 `json:"requestedLine,omitempty"`
	Line          *int64 `json:"line,omitempty"`
	Column        *int64 `json:"column,omitempty"`
}

// DebugCreateSessionRequest creates a transport-neutral DAP session. The host
// starts the adapter process and feeds its bytes through ReceiveDebug.
type DebugCreateSessionRequest struct {
	SessionID                     string `json:"sessionId"`
	AdapterID                     string `json:"adapterId"`
	RootPath                      string `json:"rootPath"`
	SupportsRunInTerminalRequest  bool   `json:"supportsRunInTerminalRequest"`
	SupportsStartDebuggingRequest bool   `json:"supportsStartDebuggingRequest"`
	// DisabledCapabilities, Features and Defaults are the adapter's declaration
	// (the launch plan's debugAdapter descriptor), passed through unchanged so the
	// engine follows the declaration instead of recognizing the adapter by ID.
	DisabledCapabilities []string        `json:"disabledCapabilities,omitempty"`
	Features             json.RawMessage `json:"features,omitempty"`
	Defaults             json.RawMessage `json:"defaults,omitempty"`
}

// DebugLaunchConfiguration is the language-neutral launch Core forwards.
type DebugLaunchConfiguration struct {
	Name      string         `json:"name"`
	Request   string         `json:"request"`
	Arguments map[string]any `json:"arguments,omitempty"`
}

// DebugSourceBreakpoint is one one-based source breakpoint request.
type DebugSourceBreakpoint struct {
	Line         int64  `json:"line"`
	Column       *int64 `json:"column,omitempty"`
	Enabled      bool   `json:"enabled"`
	Condition    string `json:"condition,omitempty"`
	HitCondition string `json:"hitCondition,omitempty"`
	LogMessage   string `json:"logMessage,omitempty"`
}

// CreateDebugSession asks Core for the framed DAP initialize request.
func (c *Client) CreateDebugSession(ctx context.Context, request DebugCreateSessionRequest) (DebugUpdate, error) {
	var update DebugUpdate
	if err := c.Execute(ctx, "debug.createSession", request, &update); err != nil {
		return DebugUpdate{}, err
	}
	return update, nil
}

// LaunchDebug asks Core to send launch or attach. The host must have created
// the session first.
func (c *Client) LaunchDebug(ctx context.Context, sessionID, operationID string, configuration DebugLaunchConfiguration) (DebugUpdate, error) {
	var update DebugUpdate
	if err := c.Execute(ctx, "debug.launch", struct {
		SessionID     string                   `json:"sessionId"`
		OperationID   string                   `json:"operationId"`
		Configuration DebugLaunchConfiguration `json:"configuration"`
	}{sessionID, operationID, configuration}, &update); err != nil {
		return DebugUpdate{}, err
	}
	return update, nil
}

// SetDebugBreakpoints replaces the complete set for one absolute source path.
func (c *Client) SetDebugBreakpoints(ctx context.Context, sessionID, sourcePath string, breakpoints []DebugSourceBreakpoint) (DebugUpdate, error) {
	var update DebugUpdate
	if err := c.Execute(ctx, "debug.setBreakpoints", struct {
		SessionID   string                  `json:"sessionId"`
		SourcePath  string                  `json:"sourcePath"`
		Breakpoints []DebugSourceBreakpoint `json:"breakpoints"`
	}{sessionID, sourcePath, breakpoints}, &update); err != nil {
		return DebugUpdate{}, err
	}
	return update, nil
}

// ExecuteDebug queues continue, pause or a step. threadID is nil for commands
// that do not name a thread.
func (c *Client) ExecuteDebug(ctx context.Context, sessionID, operationID, command string, threadID *int64) (DebugUpdate, error) {
	var update DebugUpdate
	if err := c.Execute(ctx, "debug.execute", struct {
		SessionID   string `json:"sessionId"`
		OperationID string `json:"operationId"`
		Command     string `json:"command"`
		ThreadID    *int64 `json:"threadId,omitempty"`
	}{sessionID, operationID, command, threadID}, &update); err != nil {
		return DebugUpdate{}, err
	}
	return update, nil
}

// DebugInspectRequest is one typed thread, stack or scope request.
type DebugInspectRequest struct {
	SessionID          string `json:"sessionId"`
	OperationID        string `json:"operationId"`
	Kind               string `json:"kind"`
	ThreadID           *int64 `json:"threadId,omitempty"`
	FrameID            *int64 `json:"frameId,omitempty"`
	VariablesReference *int64 `json:"variablesReference,omitempty"`
	// VariableFilter is "named" or "indexed" for a paged variables request;
	// Start and Count are its zero-based window.
	VariableFilter string `json:"variableFilter,omitempty"`
	Start          *int64 `json:"start,omitempty"`
	Count          *int64 `json:"count,omitempty"`
	// Expression and Context are the evaluate inputs: the text to evaluate and its DAP
	// context (watch, hover, repl, clipboard or variables).
	Expression string `json:"expression,omitempty"`
	Context    string `json:"context,omitempty"`
	// Disassemble inputs (MemoryReference is opaque address text).
	MemoryReference   string `json:"memoryReference,omitempty"`
	Offset            *int64 `json:"offset,omitempty"`
	InstructionOffset *int64 `json:"instructionOffset,omitempty"`
	InstructionCount  *int64 `json:"instructionCount,omitempty"`
	ResolveSymbols    *bool  `json:"resolveSymbols,omitempty"`
}

// InspectDebug queues one typed debugger inspection.
func (c *Client) InspectDebug(ctx context.Context, request DebugInspectRequest) (DebugUpdate, error) {
	var update DebugUpdate
	if err := c.Execute(ctx, "debug.inspect", request, &update); err != nil {
		return DebugUpdate{}, err
	}
	return update, nil
}

// ReceiveDebug feeds one raw adapter byte chunk to Core and returns the frames
// and events it produced. Core owns DAP framing and buffering.
func (c *Client) ReceiveDebug(ctx context.Context, sessionID string, data []byte) (DebugUpdate, error) {
	var update DebugUpdate
	if err := c.Execute(ctx, "debug.receive", struct {
		SessionID  string `json:"sessionId"`
		DataBase64 string `json:"dataBase64"`
	}{sessionID, base64.StdEncoding.EncodeToString(data)}, &update); err != nil {
		return DebugUpdate{}, err
	}
	return update, nil
}

// DisconnectDebug asks Core to send the adapter's disconnect sequence.
func (c *Client) DisconnectDebug(ctx context.Context, sessionID string) (DebugUpdate, error) {
	var update DebugUpdate
	if err := c.Execute(ctx, "debug.disconnect", struct {
		SessionID string `json:"sessionId"`
	}{sessionID}, &update); err != nil {
		return DebugUpdate{}, err
	}
	return update, nil
}

// DestroyDebugSession drops the session and returns child sessions to stop.
func (c *Client) DestroyDebugSession(ctx context.Context, sessionID string) ([]string, error) {
	var destroyed struct {
		Destroyed     bool     `json:"destroyed"`
		ChildSessions []string `json:"destroyedChildSessionIds"`
	}
	if err := c.Execute(ctx, "debug.destroySession", struct {
		SessionID string `json:"sessionId"`
	}{sessionID}, &destroyed); err != nil {
		return nil, err
	}
	return destroyed.ChildSessions, nil
}
