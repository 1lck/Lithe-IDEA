package workbench

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

const (
	// debugDisassemblyFirstWindow is the instruction count of the first window
	// and debugDisassemblyBefore how many of them lie above the instruction
	// pointer; debugDisassemblyEdge is the size of a "load more" page.
	debugDisassemblyFirstWindow = 96
	debugDisassemblyBefore      = 24
	debugDisassemblyEdge        = 64
)

// debugDisassembly is the instruction window of the selected frame. The paging
// rules (window, recovery after a refused request, edge probing, padding and
// duplicate removal) are Core's; the host keeps the rows and the scroll.
type debugDisassembly struct {
	rows []core.DebugInstruction
	// anchor is the instruction pointer the window is built around; addresses are
	// the adapter's text and are only ever compared, never parsed.
	anchor  string
	loading bool
	failure string
	// beforeDone and afterDone record that Core found the end of the code in
	// that direction.
	beforeDone, afterDone bool
	list                  ui.ListState
	// frame is the stack frame the window belongs to.
	frame int
	// pending holds the instructions of the reply being reduced; Core answers
	// with indexes into them.
	pending []core.DebugInstruction
}

func (d *debugDisassembly) reset() { *d = debugDisassembly{} }

// canDisassemble reports whether the selected frame can be shown as code: the
// adapter advertised disassemble, the session is paused and the frame carries
// an instruction pointer.
func canDisassemble(d *debugState) bool {
	return d.activeSession() != nil && d.state == "paused" && d.capabilities != nil && d.capabilities.SupportsDisassembleRequest &&
		d.vars.frame < len(d.frames) && d.frames[d.vars.frame].InstructionPointerReference != ""
}

// loadDisassembly builds the first window around the selected frame's
// instruction pointer.
func (a *App) loadDisassembly(p *project) {
	d := &p.debug
	if !canDisassemble(d) || d.disassembly.loading {
		return
	}
	frame := d.vars.frame
	reference := d.frames[frame].InstructionPointerReference
	d.disassembly.reset()
	d.disassembly.loading, d.disassembly.anchor, d.disassembly.frame = true, reference, frame
	a.planDisassembly(p, "around", reference, debugDisassemblyFirstWindow, debugDisassemblyBefore)
}

// loadDisassemblyEdge extends the window above its first or below its last row.
func (a *App) loadDisassemblyEdge(p *project, direction string) {
	d := &p.debug.disassembly
	if d.loading || len(d.rows) == 0 || !canDisassemble(&p.debug) {
		return
	}
	reference := d.rows[len(d.rows)-1].Address
	if direction == "before" {
		reference = d.rows[0].Address
	}
	d.loading = true
	a.planDisassembly(p, direction, reference, debugDisassemblyEdge, 0)
}

// planDisassembly asks Core for the first request of a window, then follows
// Core's steps until it answers with a page or a failure.
func (a *App) planDisassembly(p *project, direction, reference string, count, before uint32) {
	session := p.debug.activeSession()
	a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
		fetch, err := a.kernel.PlanDebugDisassemblyWindow(ctx, direction, reference, count, before)
		return func(a *App) {
			if a.project != p || p.debug.activeSession() != session {
				return
			}
			if err != nil {
				p.debug.disassembly.loading, p.debug.disassembly.failure = false, err.Error()
				return
			}
			a.fetchDisassembly(p, fetch)
		}
	})
}

// fetchDisassembly sends one planned request and reduces whatever answers it.
func (a *App) fetchDisassembly(p *project, fetch core.DebugDisassemblyFetch) {
	request := fetch.Request
	offset, count := request.InstructionOffset, int64(request.InstructionCount)
	reduce := func(a *App, reply core.DebugDisassemblyReply) { a.reduceDisassembly(p, fetch, reply) }
	a.debugOperation(p, "disassemble", func(ctx context.Context, session *debugSession, operationID string) (core.DebugUpdate, error) {
		return a.kernel.InspectDebug(ctx, core.DebugInspectRequest{
			SessionID: session.id, OperationID: operationID, Kind: "disassemble",
			MemoryReference: request.MemoryReference, InstructionOffset: &offset, InstructionCount: &count,
		})
	}, debugOperationHandlers{done: func(a *App, result core.DebugOperationResult) {
		reply := core.DebugDisassemblyReply{Kind: "instructions"}
		for _, instruction := range result.Instructions {
			reply.Instructions = append(reply.Instructions, core.DebugDisassemblyReplyInstruction{
				Address: instruction.Address, Instruction: instruction.Instruction, InstructionBytes: instruction.InstructionBytes,
			})
		}
		// Keep the full instructions beside the reply: Core returns indexes into it.
		p.debug.disassembly.pending = result.Instructions
		reduce(a, reply)
	}, failed: func(a *App, message string, transport bool) {
		// An adapter that answered success=false is "rejected"; a request that
		// never got an answer (timeout, cancellation) is "failed" and is never
		// taken as the end of the code.
		kind := "rejected"
		if transport {
			kind = "failed"
		}
		reduce(a, core.DebugDisassemblyReply{Kind: kind, Message: message})
	}})
}

// reduceDisassembly applies Core's decision for one reply.
func (a *App) reduceDisassembly(p *project, fetch core.DebugDisassemblyFetch, reply core.DebugDisassemblyReply) {
	session := p.debug.activeSession()
	known := make([]string, 0, len(p.debug.disassembly.rows))
	for _, row := range p.debug.disassembly.rows {
		known = append(known, row.Address)
	}
	instructions := p.debug.disassembly.pending
	p.debug.disassembly.pending = nil
	a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
		step, err := a.kernel.ReduceDebugDisassemblyPage(ctx, fetch, reply, known)
		return func(a *App) {
			d := &p.debug.disassembly
			if a.project != p || p.debug.activeSession() != session {
				return
			}
			if err != nil {
				d.loading, d.failure = false, err.Error()
				return
			}
			switch step.Kind {
			case "request":
				if step.Fetch != nil {
					a.fetchDisassembly(p, *step.Fetch)
					return
				}
				d.loading = false
			case "page":
				d.loading, d.failure = false, ""
				kept := make([]core.DebugInstruction, 0, len(step.Keep))
				// keep indexes the reply as sent: padding stays in the array, and Core
				// only leaves its indexes out of keep.
				for _, index := range step.Keep {
					if index >= 0 && index < len(instructions) {
						kept = append(kept, instructions[index])
					}
				}
				switch fetch.Direction {
				case "before":
					d.rows = append(kept, d.rows...)
					d.beforeDone = step.Exhausted
				case "after":
					d.rows = append(d.rows, kept...)
					d.afterDone = step.Exhausted
				default:
					d.rows = kept
				}
			default:
				d.loading, d.failure = false, step.Message
			}
		}
	})
}
