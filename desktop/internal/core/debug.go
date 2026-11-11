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
	// DataID, Description, AccessTypes and CanPersist are the result of dataBreakpointInfo.
	DataID      string   `json:"dataId,omitempty"`
	Description string   `json:"description,omitempty"`
	AccessTypes []string `json:"accessTypes,omitempty"`
	CanPersist  bool     `json:"canPersist,omitempty"`
	// ExceptionInfo is the result of an exceptionInfo inspection.
	ExceptionInfo *DebugExceptionInfo `json:"exceptionInfo,omitempty"`
	// Variable is the replacement of a setVariable or the value of an evaluate.
	Variable *DebugVariable `json:"variable,omitempty"`
	// Instructions is the result of a disassemble inspection.
	Instructions []DebugInstruction `json:"instructions,omitempty"`
	// Address, UnreadableBytes and DataBase64 are the result of a readMemory
	// inspection; the bytes are base64 like DAP's readMemory response.
	Address         string `json:"address,omitempty"`
	UnreadableBytes int64  `json:"unreadableBytes,omitempty"`
	DataBase64      string `json:"dataBase64,omitempty"`
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
	// ParentSessionID names the session whose adapter asked for this child through startDebugging.
	ParentSessionID string `json:"parentSessionId,omitempty"`
	// DisabledCapabilities, Features and Defaults are the adapter's declaration
	// (the launch plan's debugAdapter descriptor), passed through unchanged so the
	// engine follows the declaration instead of recognizing the adapter by ID.
	DisabledCapabilities []string        `json:"disabledCapabilities,omitempty"`
	Features             json.RawMessage `json:"features,omitempty"`
	Defaults             json.RawMessage `json:"defaults,omitempty"`
}

// DebugLaunchConfiguration is the language-neutral launch Core forwards.
// SteppingFilters, when set, is the user's stepping policy for the adapter; Core
// projects it into the launch argument the adapter declared, and uses the
// adapter's declared defaults when it is nil.
type DebugLaunchConfiguration struct {
	Name            string                `json:"name"`
	Request         string                `json:"request"`
	Arguments       map[string]any        `json:"arguments,omitempty"`
	SteppingFilters *DebugSteppingFilters `json:"steppingFilters,omitempty"`
}

// DebugSteppingFilters is the portable stepping policy of one adapter: class-name
// patterns the adapter does not step into (passed to it unchanged, so it may use
// its own wildcard syntax), the kinds of methods it steps over, and whether the
// call stack collapses the frames the patterns match.
type DebugSteppingFilters struct {
	ClassNameFilters        []string `json:"classNameFilters"`
	SkipSynthetics          bool     `json:"skipSynthetics"`
	SkipStaticInitializers  bool     `json:"skipStaticInitializers"`
	SkipConstructors        bool     `json:"skipConstructors"`
	HideFilteredStackFrames bool     `json:"hideFilteredStackFrames"`
}

// NormalizeSteppingFilters asks Core to trim, sort, de-duplicate and validate a
// stepping policy before it is stored (`debug.steppingFilters`).
func (c *Client) NormalizeSteppingFilters(ctx context.Context, adapterID string, filters DebugSteppingFilters) (DebugSteppingFilters, error) {
	if filters.ClassNameFilters == nil {
		filters.ClassNameFilters = []string{}
	}
	var normalized DebugSteppingFilters
	err := c.Execute(ctx, "debug.steppingFilters", struct {
		AdapterID string               `json:"adapterId"`
		Filters   DebugSteppingFilters `json:"filters"`
	}{adapterID, filters}, &normalized)
	return normalized, err
}

// DeclaredSteppingFilters reads a `debugAdapters` 3 declaration: whether the adapter
// takes stepping filters (features.stepFilters) and the defaults it declared
// (defaults.stepFilters), which Core applies when a launch names none.
func DeclaredSteppingFilters(features, defaults json.RawMessage) (DebugSteppingFilters, bool) {
	var declared struct {
		StepFilters *struct {
			Argument string `json:"argument"`
		} `json:"stepFilters"`
	}
	if len(features) == 0 || json.Unmarshal(features, &declared) != nil || declared.StepFilters == nil || declared.StepFilters.Argument == "" {
		return DebugSteppingFilters{}, false
	}
	var values struct {
		StepFilters DebugSteppingFilters `json:"stepFilters"`
	}
	if len(defaults) > 0 {
		_ = json.Unmarshal(defaults, &values)
	}
	return values.StepFilters, true
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
// that do not name a thread. granularity is "statement", "line" or "instruction"
// for a step, and empty keeps the adapter's default; Core forwards it only when
// the adapter advertised supportsSteppingGranularity.
func (c *Client) ExecuteDebug(ctx context.Context, sessionID, operationID, command string, threadID *int64, granularity string) (DebugUpdate, error) {
	var update DebugUpdate
	if err := c.Execute(ctx, "debug.execute", struct {
		SessionID   string `json:"sessionId"`
		OperationID string `json:"operationId"`
		Command     string `json:"command"`
		ThreadID    *int64 `json:"threadId,omitempty"`
		Granularity string `json:"granularity,omitempty"`
	}{sessionID, operationID, command, threadID, granularity}, &update); err != nil {
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

// DebugTextEdit is one replacement of the source, in UTF-16 offsets of the text before it.
type DebugTextEdit struct {
	StartUTF16Offset int64  `json:"startUtf16Offset"`
	EndUTF16Offset   int64  `json:"endUtf16Offset"`
	Replacement      string `json:"replacement"`
}

// RelocateDebugBreakpoints moves the breakpoints of one source across an edit of it. Core
// projects each line, merges duplicates and drops the breakpoints the edit removed.
func (c *Client) RelocateDebugBreakpoints(ctx context.Context, source string, edit DebugTextEdit, breakpoints []DebugSourceBreakpoint) ([]DebugSourceBreakpoint, error) {
	var result struct {
		Breakpoints []DebugSourceBreakpoint `json:"breakpoints"`
	}
	if breakpoints == nil {
		breakpoints = []DebugSourceBreakpoint{}
	}
	if err := c.Execute(ctx, "debug.relocateBreakpoints", struct {
		Source      string                  `json:"source"`
		Edit        DebugTextEdit           `json:"edit"`
		Breakpoints []DebugSourceBreakpoint `json:"breakpoints"`
	}{source, edit, breakpoints}, &result); err != nil {
		return nil, err
	}
	return result.Breakpoints, nil
}

// DebugExceptionInfo is the adapter's account of the exception a thread stopped on.
type DebugExceptionInfo struct {
	ExceptionID string                `json:"exceptionId"`
	Description string                `json:"description"`
	BreakMode   string                `json:"breakMode"`
	Details     DebugExceptionDetails `json:"details"`
}

// DebugExceptionDetails are the adapter's details of an exception, its inner exceptions included.
type DebugExceptionDetails struct {
	Message         string                    `json:"message,omitempty"`
	TypeName        string                    `json:"typeName,omitempty"`
	FullTypeName    string                    `json:"fullTypeName,omitempty"`
	EvaluateName    string                    `json:"evaluateName,omitempty"`
	StackTrace      string                    `json:"stackTrace,omitempty"`
	InnerExceptions []DebugInnerExceptionInfo `json:"innerExceptions,omitempty"`
}

// DebugInnerExceptionInfo is one inner exception of an exception.
type DebugInnerExceptionInfo struct {
	Message      string `json:"message,omitempty"`
	TypeName     string `json:"typeName,omitempty"`
	FullTypeName string `json:"fullTypeName,omitempty"`
}
