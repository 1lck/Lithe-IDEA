package workbench

import "context"

// Muting is the Debug window's switch that keeps every breakpoint the user set but stops the
// adapters from stopping on any of them. The breakpoints stay stored and shown, faded, and the
// host keeps sending every change as usual; Core keeps each session's sets and, while the
// session is muted, sends every kind empty: source, exception, function, instruction and data
// breakpoints alike. Unmuting has Core send the stored sets again.
//
// The switch belongs to the project, so every running session follows it, and a session that
// starts while it is on starts muted (see startDebugSession). A child session started through
// startDebugging inherits its parent's state in Core.

// toggleMuteBreakpoints mutes or unmutes every breakpoint of every running session.
func (a *App) toggleMuteBreakpoints(p *project) {
	if p == nil {
		return
	}
	d := &p.debug
	d.muted = !d.muted
	a.performed("debug.muteBreakpoints", surfaceButton)
	for _, session := range d.sessions {
		session.muted.Store(d.muted)
		a.sendSessionMuted(p, session)
	}
}

// sendSessionMuted tells Core the session's current mute state. Each send reads the state when
// it runs, under the session's operation lock, so the last send carries the last toggle however
// the sends are scheduled; Core sends nothing for a state it already has.
func (a *App) sendSessionMuted(p *project, session *debugSession) {
	if session == nil || session.stopped.Load() {
		return
	}
	a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
		// A session still starting applies the state itself once Core has it; one that never
		// got that far has nothing to mute.
		select {
		case <-session.startupDone:
		case <-ctx.Done():
			return nil
		}
		if !session.created {
			return nil
		}
		session.operationMu.Lock()
		defer session.operationMu.Unlock()
		if session.stopped.Load() {
			return nil
		}
		update, err := a.kernel.SetDebugBreakpointsMuted(ctx, session.id, session.muted.Load())
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
