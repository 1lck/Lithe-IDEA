package workbench

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// debugStateKernel is the part of Core the Debug tool window's variables,
// exception filters, disassembly and start/continue decision use. It is its own
// interface so those files add to Kernel by one embedded line.
type debugStateKernel interface {
	SetDebugExceptionBreakpoints(ctx context.Context, sessionID string, breakpoints []core.DebugExceptionBreakpoint) (core.DebugUpdate, error)
	RelocateDebugBreakpoints(ctx context.Context, source string, edit core.DebugTextEdit, breakpoints []core.DebugSourceBreakpoint) ([]core.DebugSourceBreakpoint, error)
	SetDebugInstructionBreakpoints(ctx context.Context, sessionID string, breakpoints []core.DebugInstructionBreakpoint) (core.DebugUpdate, error)
	SetDebugFunctionBreakpoints(ctx context.Context, sessionID string, breakpoints []core.DebugFunctionBreakpoint) (core.DebugUpdate, error)
	SetDebugVariable(ctx context.Context, sessionID, operationID string, variablesReference int64, name, value string) (core.DebugUpdate, error)
	DebugStartDebuggingResponse(ctx context.Context, sessionID, requestID string, success bool, message string) (core.DebugUpdate, error)
	DebugStartOrContinue(ctx context.Context, active, paused, requestPending bool) (core.DebugStartAction, error)
	PlanDebugVariablePage(ctx context.Context, variablesReference, namedVariables, indexedVariables int64, pageSize uint32) (core.DebugVariablePageState, error)
	ReduceDebugVariablePage(ctx context.Context, state core.DebugVariablePageState, requested core.DebugVariablePageRequest, page []core.DebugVariablePageItem, newItemCount uint64) (bool, core.DebugVariablePageState, error)
	PlanDebugDisassemblyWindow(ctx context.Context, direction, reference string, count, instructionsBefore uint32) (core.DebugDisassemblyFetch, error)
	ReduceDebugDisassemblyPage(ctx context.Context, fetch core.DebugDisassemblyFetch, reply core.DebugDisassemblyReply, knownAddresses []string) (core.DebugDisassemblyStep, error)
}
