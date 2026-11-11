package core

import (
	"context"
)

// DebugCapabilities is what the adapter negotiated at initialize. A native UI
// treats it as unknown until the `capabilities` event arrives.
type DebugCapabilities struct {
	SupportsSetVariable            bool                   `json:"supportsSetVariable"`
	SupportsDisassembleRequest     bool                   `json:"supportsDisassembleRequest"`
	SupportsSteppingGranularity    bool                   `json:"supportsSteppingGranularity"`
	SupportsInstructionBreakpoints bool                   `json:"supportsInstructionBreakpoints"`
	SupportsDataBreakpoints        bool                   `json:"supportsDataBreakpoints"`
	SupportsReadMemoryRequest      bool                   `json:"supportsReadMemoryRequest"`
	SupportsRestartRequest         bool                   `json:"supportsRestartRequest"`
	SupportsTerminateRequest       bool                   `json:"supportsTerminateRequest"`
	SupportsExceptionFilterOptions bool                   `json:"supportsExceptionFilterOptions"`
	ExceptionBreakpointFilters     []DebugExceptionFilter `json:"exceptionBreakpointFilters"`
}

// DebugExceptionFilter is one adapter-defined exception category.
type DebugExceptionFilter struct {
	Filter               string `json:"filter"`
	Label                string `json:"label"`
	Description          string `json:"description,omitempty"`
	Default              bool   `json:"default"`
	SupportsCondition    bool   `json:"supportsCondition"`
	ConditionDescription string `json:"conditionDescription,omitempty"`
}

// DebugExceptionBreakpoint is one exception filter selection.
type DebugExceptionBreakpoint struct {
	Filter    string `json:"filter"`
	Enabled   bool   `json:"enabled"`
	Condition string `json:"condition,omitempty"`
}

// SetDebugExceptionBreakpoints replaces the complete exception selection.
func (c *Client) SetDebugExceptionBreakpoints(ctx context.Context, sessionID string, breakpoints []DebugExceptionBreakpoint) (DebugUpdate, error) {
	var update DebugUpdate
	if breakpoints == nil {
		breakpoints = []DebugExceptionBreakpoint{}
	}
	if err := c.Execute(ctx, "debug.setExceptionBreakpoints", struct {
		SessionID   string                     `json:"sessionId"`
		Breakpoints []DebugExceptionBreakpoint `json:"breakpoints"`
	}{sessionID, breakpoints}, &update); err != nil {
		return DebugUpdate{}, err
	}
	return update, nil
}

// SetDebugVariable asks the adapter to replace one variable's value inside its
// parent container. Core allows it only while paused with supportsSetVariable.
func (c *Client) SetDebugVariable(ctx context.Context, sessionID, operationID string, variablesReference int64, name, value string) (DebugUpdate, error) {
	var update DebugUpdate
	if err := c.Execute(ctx, "debug.setVariable", struct {
		SessionID          string `json:"sessionId"`
		OperationID        string `json:"operationId"`
		VariablesReference int64  `json:"variablesReference"`
		Name               string `json:"name"`
		Value              string `json:"value"`
	}{sessionID, operationID, variablesReference, name, value}, &update); err != nil {
		return DebugUpdate{}, err
	}
	return update, nil
}

// DebugStartDebugging is the adapter's request to open a child session.
type DebugStartDebugging struct {
	Request       string         `json:"request"`
	Configuration map[string]any `json:"configuration"`
}

// DebugStartDebuggingResponse answers one startDebuggingRequested event: the
// host reports whether it opened the child session, and Core replies to the
// adapter with the original request sequence.
func (c *Client) DebugStartDebuggingResponse(ctx context.Context, sessionID, requestID string, success bool, message string) (DebugUpdate, error) {
	var update DebugUpdate
	payload := struct {
		SessionID string `json:"sessionId"`
		RequestID string `json:"requestId"`
		Success   bool   `json:"success"`
		Message   string `json:"message,omitempty"`
	}{sessionID, requestID, success, message}
	if err := c.Execute(ctx, "debug.startDebuggingResponse", payload, &update); err != nil {
		return DebugUpdate{}, err
	}
	return update, nil
}

// DebugStartAction is what the toolbar's start/continue action should do.
type DebugStartAction string

const (
	DebugActionStart    DebugStartAction = "start"
	DebugActionContinue DebugStartAction = "continue"
	DebugActionNone     DebugStartAction = "none"
)

// DebugStartOrContinue asks Core whether the one start/continue action starts a
// session, resumes a paused one or does nothing.
func (c *Client) DebugStartOrContinue(ctx context.Context, active, paused, requestPending bool) (DebugStartAction, error) {
	var result struct {
		Action DebugStartAction `json:"action"`
	}
	if err := c.Execute(ctx, "debug.startOrContinue", struct {
		Active         bool `json:"active"`
		Paused         bool `json:"paused"`
		RequestPending bool `json:"requestPending"`
	}{active, paused, requestPending}, &result); err != nil {
		return DebugActionNone, err
	}
	return result.Action, nil
}

// DebugVariablePageSegment is one named or indexed run of a container.
type DebugVariablePageSegment struct {
	Filter     string `json:"filter,omitempty"`
	NextStart  uint64 `json:"nextStart"`
	TotalCount *int64 `json:"totalCount,omitempty"`
}

// DebugVariablePageRequest is the window to send as a variables inspection.
type DebugVariablePageRequest struct {
	Filter         string `json:"filter,omitempty"`
	Start          uint64 `json:"start"`
	Count          uint32 `json:"count"`
	RemainingCount *int64 `json:"remainingCount,omitempty"`
}

// DebugVariablePageState is Core's cursor over one variable container. The host
// keeps it between pages and hands it back unchanged.
type DebugVariablePageState struct {
	VariablesReference int64                      `json:"variablesReference"`
	PageSize           uint32                     `json:"pageSize"`
	Segments           []DebugVariablePageSegment `json:"segments"`
	LoadedPages        []string                   `json:"loadedPages"`
	Next               *DebugVariablePageRequest  `json:"next,omitempty"`
}

// DebugVariablePageItem is the identity of one returned child.
type DebugVariablePageItem struct {
	Name               string `json:"name"`
	Value              string `json:"value"`
	Type               string `json:"type,omitempty"`
	EvaluateName       string `json:"evaluateName,omitempty"`
	VariablesReference int64  `json:"variablesReference"`
}

// PlanDebugVariablePage plans the first bounded page of one container.
func (c *Client) PlanDebugVariablePage(ctx context.Context, variablesReference, namedVariables, indexedVariables int64, pageSize uint32) (DebugVariablePageState, error) {
	var state DebugVariablePageState
	if err := c.Execute(ctx, "debug.planVariablePage", struct {
		VariablesReference int64  `json:"variablesReference"`
		NamedVariables     int64  `json:"namedVariables"`
		IndexedVariables   int64  `json:"indexedVariables"`
		PageSize           uint32 `json:"pageSize"`
	}{variablesReference, namedVariables, indexedVariables, pageSize}, &state); err != nil {
		return DebugVariablePageState{}, err
	}
	return state, nil
}

// ReduceDebugVariablePage merges one returned page into the cursor. When accept
// is false the host drops the page.
func (c *Client) ReduceDebugVariablePage(ctx context.Context, state DebugVariablePageState, requested DebugVariablePageRequest, page []DebugVariablePageItem, newItemCount uint64) (bool, DebugVariablePageState, error) {
	if page == nil {
		page = []DebugVariablePageItem{}
	}
	var result struct {
		Accept bool                   `json:"accept"`
		State  DebugVariablePageState `json:"state"`
	}
	if err := c.Execute(ctx, "debug.reduceVariablePage", struct {
		State        DebugVariablePageState   `json:"state"`
		Requested    DebugVariablePageRequest `json:"requested"`
		Page         []DebugVariablePageItem  `json:"page"`
		NewItemCount uint64                   `json:"newItemCount"`
	}{state, requested, page, newItemCount}, &result); err != nil {
		return false, DebugVariablePageState{}, err
	}
	return result.Accept, result.State, nil
}

// DebugDisassemblyArguments are the exact DAP disassemble arguments of a fetch.
type DebugDisassemblyArguments struct {
	MemoryReference   string `json:"memoryReference"`
	InstructionOffset int64  `json:"instructionOffset"`
	InstructionCount  uint32 `json:"instructionCount"`
}

// DebugDisassemblyFetch is one planned disassemble request. The host keeps it
// and passes it back with the adapter's reply.
type DebugDisassemblyFetch struct {
	Direction          string                    `json:"direction"`
	Reference          string                    `json:"reference"`
	Phase              string                    `json:"phase"`
	Count              uint32                    `json:"count"`
	InstructionsBefore uint32                    `json:"instructionsBefore"`
	WindowFailure      string                    `json:"windowFailure,omitempty"`
	Request            DebugDisassemblyArguments `json:"request"`
}

// DebugDisassemblyReplyInstruction is one instruction of an adapter reply.
type DebugDisassemblyReplyInstruction struct {
	Address          string `json:"address"`
	Instruction      string `json:"instruction"`
	InstructionBytes string `json:"instructionBytes,omitempty"`
}

// DebugDisassemblyReply is the adapter's answer: Kind is "instructions",
// "rejected" (success false) or "failed" (transport, timeout, cancel).
type DebugDisassemblyReply struct {
	Kind         string                             `json:"kind"`
	Instructions []DebugDisassemblyReplyInstruction `json:"instructions,omitempty"`
	Message      string                             `json:"message,omitempty"`
}

// DebugDisassemblyStep is Core's decision after one reply.
type DebugDisassemblyStep struct {
	// Kind is "request" (send Fetch), "page" (show Keep) or "failed".
	Kind      string                 `json:"kind"`
	Fetch     *DebugDisassemblyFetch `json:"fetch,omitempty"`
	Keep      []int                  `json:"keep,omitempty"`
	Exhausted bool                   `json:"exhausted,omitempty"`
	Message   string                 `json:"message,omitempty"`
}

// PlanDebugDisassemblyWindow plans the first disassemble request of a window.
// direction is "around", "before" or "after".
func (c *Client) PlanDebugDisassemblyWindow(ctx context.Context, direction, reference string, count, instructionsBefore uint32) (DebugDisassemblyFetch, error) {
	var fetch DebugDisassemblyFetch
	if err := c.Execute(ctx, "debug.planDisassemblyWindow", struct {
		Direction          string `json:"direction"`
		Reference          string `json:"reference"`
		Count              uint32 `json:"count"`
		InstructionsBefore uint32 `json:"instructionsBefore,omitempty"`
	}{direction, reference, count, instructionsBefore}, &fetch); err != nil {
		return DebugDisassemblyFetch{}, err
	}
	return fetch, nil
}

// ReduceDebugDisassemblyPage reduces one reply to the next request, a
// deduplicated page or the adapter's failure.
func (c *Client) ReduceDebugDisassemblyPage(ctx context.Context, fetch DebugDisassemblyFetch, reply DebugDisassemblyReply, knownAddresses []string) (DebugDisassemblyStep, error) {
	if knownAddresses == nil {
		knownAddresses = []string{}
	}
	var step DebugDisassemblyStep
	if err := c.Execute(ctx, "debug.reduceDisassemblyPage", struct {
		Fetch          DebugDisassemblyFetch `json:"fetch"`
		Reply          DebugDisassemblyReply `json:"reply"`
		KnownAddresses []string              `json:"knownAddresses"`
	}{fetch, reply, knownAddresses}, &step); err != nil {
		return DebugDisassemblyStep{}, err
	}
	return step, nil
}

// DebugFunctionBreakpoint is one breakpoint on a named method or function. Core keeps the
// complete sorted set and sends it only when the adapter negotiated function breakpoints.
type DebugFunctionBreakpoint struct {
	Name         string `json:"name"`
	Enabled      bool   `json:"enabled"`
	Condition    string `json:"condition,omitempty"`
	HitCondition string `json:"hitCondition,omitempty"`
}

// SetDebugFunctionBreakpoints replaces the complete function breakpoint set of a session.
func (c *Client) SetDebugFunctionBreakpoints(ctx context.Context, sessionID string, breakpoints []DebugFunctionBreakpoint) (DebugUpdate, error) {
	var update DebugUpdate
	if breakpoints == nil {
		breakpoints = []DebugFunctionBreakpoint{}
	}
	if err := c.Execute(ctx, "debug.setFunctionBreakpoints", struct {
		SessionID           string                    `json:"sessionId"`
		FunctionBreakpoints []DebugFunctionBreakpoint `json:"functionBreakpoints"`
	}{sessionID, breakpoints}, &update); err != nil {
		return DebugUpdate{}, err
	}
	return update, nil
}

// DebugInstructionBreakpoint is one machine-instruction breakpoint. The reference is the address
// text the adapter reported, kept as text because a 64-bit address does not fit a JSON number.
type DebugInstructionBreakpoint struct {
	InstructionReference string `json:"instructionReference"`
	Offset               *int64 `json:"offset,omitempty"`
	Enabled              bool   `json:"enabled"`
	Condition            string `json:"condition,omitempty"`
	HitCondition         string `json:"hitCondition,omitempty"`
}

// SetDebugInstructionBreakpoints replaces the complete instruction breakpoint set of a session.
// Core sends it only when the adapter advertised instruction breakpoints.
func (c *Client) SetDebugInstructionBreakpoints(ctx context.Context, sessionID string, breakpoints []DebugInstructionBreakpoint) (DebugUpdate, error) {
	var update DebugUpdate
	if breakpoints == nil {
		breakpoints = []DebugInstructionBreakpoint{}
	}
	if err := c.Execute(ctx, "debug.setInstructionBreakpoints", struct {
		SessionID              string                       `json:"sessionId"`
		InstructionBreakpoints []DebugInstructionBreakpoint `json:"instructionBreakpoints"`
	}{sessionID, breakpoints}, &update); err != nil {
		return DebugUpdate{}, err
	}
	return update, nil
}

// DebugDataBreakpoint is one resolved data breakpoint: the adapter's identity from
// dataBreakpointInfo plus how it fires. CanPersist-false identities end with their session.
type DebugDataBreakpoint struct {
	DataID       string `json:"dataId"`
	Label        string `json:"label,omitempty"`
	Enabled      bool   `json:"enabled"`
	AccessType   string `json:"accessType,omitempty"`
	Condition    string `json:"condition,omitempty"`
	HitCondition string `json:"hitCondition,omitempty"`
}

// DebugDataBreakpointInfo asks the adapter to identify a paused variable for a data breakpoint.
// The answer arrives as an operationCompleted event with the dataBreakpointInfo result.
func (c *Client) DebugDataBreakpointInfo(ctx context.Context, sessionID, operationID, name string, variablesReference int64) (DebugUpdate, error) {
	var update DebugUpdate
	if err := c.Execute(ctx, "debug.dataBreakpointInfo", struct {
		SessionID          string `json:"sessionId"`
		OperationID        string `json:"operationId"`
		Name               string `json:"name"`
		VariablesReference int64  `json:"variablesReference"`
	}{sessionID, operationID, name, variablesReference}, &update); err != nil {
		return DebugUpdate{}, err
	}
	return update, nil
}

// SetDebugDataBreakpoints replaces the complete data breakpoint set of a session.
func (c *Client) SetDebugDataBreakpoints(ctx context.Context, sessionID string, breakpoints []DebugDataBreakpoint) (DebugUpdate, error) {
	var update DebugUpdate
	if breakpoints == nil {
		breakpoints = []DebugDataBreakpoint{}
	}
	if err := c.Execute(ctx, "debug.setDataBreakpoints", struct {
		SessionID   string                `json:"sessionId"`
		Breakpoints []DebugDataBreakpoint `json:"breakpoints"`
	}{sessionID, breakpoints}, &update); err != nil {
		return DebugUpdate{}, err
	}
	return update, nil
}
