package workbench

import (
	"context"
	"errors"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// startChildDebug opens the child session an adapter asked for with a DAP
// startDebugging reverse request. The child runs on the parent's adapter with the
// configuration the adapter sent, so its launch or attach takes the same start path
// as a root session; an attach reaches the host and port that configuration names.
// Core has already checked the request kind, and the parent answers it once the
// child is created or fails.
func (a *App) startChildDebug(p *project, parent *debugSession, event core.DebugEvent) {
	if !p.debug.hasSession(parent) {
		return
	}
	if event.StartDebugging == nil {
		a.respondStartDebugging(p, parent, event.RequestID, false, a.text.Debug.Child.Unavailable)
		return
	}
	a.beginDebug(p, debugStart{
		adapter:        parent.adapter,
		request:        event.StartDebugging.Request,
		configuration:  event.StartDebugging.Configuration,
		parent:         parent,
		startRequestID: event.RequestID,
	})
}

// answerChildStart completes the parent's startDebugging request exactly once with
// the child's outcome. Root sessions have no parent and are never answered.
func (a *App) answerChildStart(p *project, child *debugSession, success bool, message string) {
	if child.parent == nil || child.startAnswered.Swap(true) {
		return
	}
	a.respondStartDebugging(p, child.parent, child.startRequestID, success, message)
}

// respondStartDebugging sends the reply to the parent adapter through Core. Core
// writes the DAP response; the frames go out before the update is applied.
func (a *App) respondStartDebugging(p *project, parent *debugSession, requestID string, success bool, message string) {
	a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
		parent.operationMu.Lock()
		defer parent.operationMu.Unlock()
		if parent.stopped.Load() {
			return nil
		}
		update, err := a.kernel.DebugStartDebuggingResponse(ctx, parent.id, requestID, success, message)
		if err != nil {
			return func(a *App) { a.finishDebugError(p, parent, err) }
		}
		if err := parent.writeFrames(update.OutboundFrames); err != nil {
			return func(a *App) { a.finishDebugError(p, parent, err) }
		}
		a.postDebugUpdate(p, parent, update)
		return nil
	})
}

// failChildDebug records a child session that could not start and ends it. A remote
// endpoint is not asked about for a child: the child fails with a message the parent
// adapter receives, and the user starts the attach from the panel.
func (a *App) failChildDebug(p *project, child *debugSession, err error) {
	if errors.Is(err, context.Canceled) {
		return
	}
	message := err.Error()
	var remote *debugRemoteError
	if errors.As(err, &remote) {
		message = a.text.Debug.Child.NeedsConfirmation
	}
	a.answerChildStart(p, child, false, message)
	if a.project != p || !p.debug.hasSession(child) {
		return
	}
	a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("debug", err))
	a.endDebugSession(p, child)
	p.debug.failure = message
	if p.debug.activeSession() != nil {
		p.debug.status = a.text.Debug.Failed
	}
}

// releaseChildSessions closes the transports of the children a released parent took
// with it. Core removed the children named in destroyed together with the parent, so
// their release does not destroy them again; a child Core never created has nothing to
// destroy and is released here all the same.
func (a *App) releaseChildSessions(p *project, children []*debugSession, destroyed []string) {
	for _, child := range children {
		child.coreGone = slices.Contains(destroyed, child.id)
		a.releaseDebugSession(p, child)
	}
}
