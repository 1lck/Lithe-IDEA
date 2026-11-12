package workbench

import (
	"context"
	"sort"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// debugExceptions is the user's exception breakpoint selection. It belongs to
// the project, not the session: the filters are the adapter's, so the choice is
// kept by filter id and applied to each session that offers the same filter.
type debugExceptions struct {
	// enabled maps a filter id to the user's choice; nil until the user chose.
	enabled map[string]bool
}

// exceptionEnabled is what the checkbox of one filter shows: the user's choice,
// or the adapter's declared default until the user chose.
func (e *debugExceptions) exceptionEnabled(filter core.DebugExceptionFilter) bool {
	if choice, ok := e.enabled[filter.Filter]; ok {
		return choice
	}
	return filter.Default
}

// selection is the complete list Core replaces its selection with. Core sorts,
// de-duplicates and keeps disabled filters without sending them.
func (e *debugExceptions) selection(filters []core.DebugExceptionFilter) []core.DebugExceptionBreakpoint {
	selection := make([]core.DebugExceptionBreakpoint, 0, len(filters))
	for _, filter := range filters {
		selection = append(selection, core.DebugExceptionBreakpoint{Filter: filter.Filter, Enabled: e.exceptionEnabled(filter)})
	}
	sort.Slice(selection, func(i, j int) bool { return selection[i].Filter < selection[j].Filter })
	return selection
}

// setDebugException records one filter choice and tells the live session.
func (a *App) setDebugException(p *project, filter string, enabled bool) {
	d := &p.debug
	if d.exceptions.enabled == nil {
		d.exceptions.enabled = make(map[string]bool)
	}
	d.exceptions.enabled[filter] = enabled
	a.sendDebugExceptions(p)
}

// sendDebugExceptions replaces the session's exception filters by the user's
// selection. Before the user chose anything it sends nothing: Core adopts the
// adapter's declared defaults itself.
func (a *App) sendDebugExceptions(p *project) {
	d := &p.debug
	if p == nil || d.activeSession() == nil || d.capabilities == nil || d.exceptions.enabled == nil {
		return
	}
	session := d.activeSession()
	selection := d.exceptions.selection(d.capabilities.ExceptionBreakpointFilters)
	a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
		session.operationMu.Lock()
		defer session.operationMu.Unlock()
		if session.stopped.Load() {
			return nil
		}
		update, err := a.kernel.SetDebugExceptionBreakpoints(ctx, session.id, selection)
		if err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		if err := session.writeFrames(update.OutboundFrames); err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		a.postDebugUpdate(p, session, update)
		return nil
	})
}
