package workbench

import "github.com/1lck/Lithe-IDEA/desktop/internal/core"

// Muting is the Debug window's switch that keeps every breakpoint the user set but stops the
// adapters from stopping on any of them. The breakpoints stay stored and shown, faded; what
// changes is what each session is sent: every source line goes as disabled, which Core leaves
// out, and the function, instruction and data breakpoints go as empty lists. Unmuting sends
// the stored breakpoints again.

// sessionSourceBreakpoints is what a session is sent for one file's breakpoints: the lines as
// stored, or all of them disabled while the breakpoints are muted.
func sessionSourceBreakpoints(lines []debugBreakpoint, muted bool) []core.DebugSourceBreakpoint {
	points := sourceBreakpoints(lines)
	if muted {
		for index := range points {
			points[index].Enabled = false
		}
	}
	return points
}

// unlessMuted is list, or nothing while the breakpoints are muted.
func unlessMuted[T any](list []T, muted bool) []T {
	if muted {
		return nil
	}
	return list
}

// toggleMuteBreakpoints mutes or unmutes every breakpoint and sends what the sessions should
// now stop on. A kind of breakpoint the user never set is not sent, so an adapter that serves
// no such kind is never asked to.
func (a *App) toggleMuteBreakpoints(p *project) {
	if p == nil {
		return
	}
	d := &p.debug
	d.muted = !d.muted
	a.performed("debug.muteBreakpoints", surfaceButton)
	if len(d.sessions) == 0 {
		return
	}
	for path := range d.breakpoints {
		a.sendDebugBreakpoints(p, path)
	}
	if len(d.functionBreakpoints) > 0 {
		a.sendFunctionBreakpoints(p)
	}
	if len(d.instructionBreakpoints) > 0 {
		a.sendInstructionBreakpoints(p)
	}
	if len(d.dataBreakpoints) > 0 {
		a.sendDataBreakpoints(p)
	}
}
