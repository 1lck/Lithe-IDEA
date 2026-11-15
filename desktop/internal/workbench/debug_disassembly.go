package workbench

import (
	"context"
	"slices"
	"strings"

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
	// failedEdge is the direction, "before" or "after", whose last load failed. Scrolling to
	// that edge no longer loads it, so a request that keeps failing is not sent again on every
	// paint; the Retry button beside the failure asks once more.
	failedEdge string
	// opening is set while the first window is laid out for the first time. That layout
	// takes the rows at an estimated height and the window's height for the list's, so the
	// rows it reports say nothing about where the user scrolled.
	opening bool
	list    ui.ListState
	// frame is the stack frame the window belongs to.
	frame int
	// pending holds the instructions of the reply being reduced; Core answers
	// with indexes into them.
	pending []core.DebugInstruction
	// epoch counts the windows: a reply that arrives after its window was dropped (another
	// frame or thread was selected, or the debuggee moved) belongs to an older epoch and is
	// dropped too, so it cannot fill the window of the frame shown now.
	epoch int
}

func (d *debugDisassembly) reset() { *d = debugDisassembly{epoch: d.epoch + 1} }

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

// loadDisassemblyAtEdges extends the window when the last paint showed its first or last row,
// as IntelliJ IDEA's disassembly loads more code while it is scrolled. A window the list shows
// whole is not extended: nothing was scrolled, and every extension would show whole again.
func (a *App) loadDisassemblyAtEdges(p *project) {
	w := &p.debug.disassembly
	first, last := w.list.Visible()
	if w.loading || last < first {
		return
	}
	if w.opening {
		// The first layout is the one this paint reports; the next reports one at the real
		// heights, centred where the window opened.
		w.opening = false
		return
	}
	end := len(w.rows) - 1
	switch {
	case first == 0 && last < end && !w.beforeDone && w.failedEdge != "before":
		a.loadDisassemblyEdge(p, "before")
	case last >= end && first > 0 && !w.afterDone && w.failedEdge != "after":
		a.loadDisassemblyEdge(p, "after")
	}
}

// retryDisassembly asks again for what failed last: the edge whose load failed, or the first
// window when no rows arrived.
func (a *App) retryDisassembly(p *project) {
	w := &p.debug.disassembly
	edge := w.failedEdge
	w.failure, w.failedEdge = "", ""
	if edge == "" || len(w.rows) == 0 {
		a.loadDisassembly(p)
		return
	}
	a.loadDisassemblyEdge(p, edge)
}

// fail ends a load with the adapter's or Core's message. A failed edge stops loading
// by itself until the user retries it.
func (w *debugDisassembly) fail(direction, message string) {
	w.loading, w.failure = false, message
	if direction == "before" || direction == "after" {
		w.failedEdge = direction
	}
}

// planDisassembly asks Core for the first request of a window, then follows
// Core's steps until it answers with a page or a failure.
func (a *App) planDisassembly(p *project, direction, reference string, count, before uint32) {
	session, epoch := p.debug.activeSession(), p.debug.disassembly.epoch
	a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
		fetch, err := a.kernel.PlanDebugDisassemblyWindow(ctx, direction, reference, count, before)
		return func(a *App) {
			if a.project != p || !p.debug.hasSession(session) {
				return
			}
			defer p.debug.bindSession(session)()
			if p.debug.disassembly.epoch != epoch {
				return
			}
			if err != nil {
				p.debug.disassembly.fail(direction, err.Error())
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
	epoch := p.debug.disassembly.epoch
	reduce := func(a *App, reply core.DebugDisassemblyReply) {
		if p.debug.disassembly.epoch == epoch {
			a.reduceDisassembly(p, fetch, reply)
		}
	}
	a.debugOperation(p, "disassemble", func(ctx context.Context, session *debugSession, operationID string) (core.DebugUpdate, error) {
		return a.kernel.InspectDebug(ctx, core.DebugInspectRequest{
			SessionID: session.id, OperationID: operationID, Kind: "disassemble",
			MemoryReference: request.MemoryReference, InstructionOffset: &offset, InstructionCount: &count,
		})
	}, debugOperationHandlers{done: func(a *App, result core.DebugOperationResult) {
		if p.debug.disassembly.epoch != epoch {
			return
		}
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
	session, epoch := p.debug.activeSession(), p.debug.disassembly.epoch
	known := make([]string, 0, len(p.debug.disassembly.rows))
	for _, row := range p.debug.disassembly.rows {
		known = append(known, row.Address)
	}
	instructions := p.debug.disassembly.pending
	p.debug.disassembly.pending = nil
	a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
		step, err := a.kernel.ReduceDebugDisassemblyPage(ctx, fetch, reply, known)
		return func(a *App) {
			if a.project != p || !p.debug.hasSession(session) {
				return
			}
			defer p.debug.bindSession(session)()
			d := &p.debug.disassembly
			if d.epoch != epoch {
				return
			}
			if err != nil {
				d.fail(fetch.Direction, err.Error())
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
				d.loading = false
				// A page clears the failure it answers; a failure of the other edge stays
				// shown, and that edge stays paused, until it is retried.
				if d.failedEdge == "" || d.failedEdge == fetch.Direction {
					d.failure, d.failedEdge = "", ""
				}
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
					// The rows shown stay where they were as the earlier ones go in above.
					// Visible counts the rows laid out past both edges too, so the middle of
					// that range, not its first row, is what stays in place.
					first, last := d.list.Visible()
					d.rows = append(kept, d.rows...)
					d.beforeDone = step.Exhausted
					if len(kept) > 0 && last >= first {
						d.list.ScrollTo((first+last)/2+len(kept), ui.ListCenter)
					}
				case "after":
					d.rows = append(d.rows, kept...)
					d.afterDone = step.Exhausted
				default:
					// The first window opens on the current instruction.
					d.rows, d.opening = kept, true
					if index := slices.IndexFunc(kept, func(row core.DebugInstruction) bool {
						return strings.EqualFold(strings.TrimSpace(row.Address), strings.TrimSpace(d.anchor))
					}); index >= 0 {
						d.list.ScrollTo(index, ui.ListCenter)
					}
				}
			default:
				d.fail(fetch.Direction, step.Message)
			}
		}
	})
}
