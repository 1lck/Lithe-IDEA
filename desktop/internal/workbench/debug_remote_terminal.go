package workbench

import (
	"context"
	"errors"
	"path"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// openRemoteDebugTerminal runs the already validated DAP command on the same
// attachment as its adapter. The session owns the terminal until it stops.
func (a *App) openRemoteDebugTerminal(p *project, session *debugSession, event core.DebugEvent) {
	if a.project != p || !p.debug.hasSession(session) {
		return
	}
	unavailable := i18n.Shared(a.language(), "desktop.debug.terminalUnavailable")
	reply := func(pid int64, err error) {
		if session.stopped.Load() || !p.debug.hasSession(session) {
			return
		}
		var message string
		if err != nil {
			pid = 0
			message = err.Error()
			if errors.Is(err, context.Canceled) {
				message = unavailable
			}
		}
		a.replyDebugReverseRequest(p, session, func(ctx context.Context) (core.DebugUpdate, error) {
			return a.kernel.DebugRunInTerminalResponse(ctx, session.id, event.RequestID, pid, message)
		})
	}
	request := event.RunInTerminal
	switch {
	case p.remote == nil || request == nil || request.RemoteDirectory == nil || len(request.Args) == 0:
		err := errors.New(unavailable)
		a.operationFailed("debug_terminal", p.logError(err))
		reply(0, err)
		return
	case !session.connection.IsCurrent():
		a.operationFailed("debug_terminal", remoteLogError(errRemoteSessionClosed))
		reply(0, errors.New(a.text.Debug.ConnectionClosed))
		return
	case !p.trust.allowed():
		err := remoteDebugUntrusted()
		a.operationFailed("debug_terminal", remoteLogError(err))
		reply(0, errors.New(a.launchFailureText(err)))
		return
	}
	overrides := make(map[string]*string, len(request.Environment))
	for _, entry := range request.Environment {
		overrides[entry.Name] = entry.Value
	}
	env, unset := terminalEnvironment(overrides)
	title := request.Title
	if title == "" {
		title = path.Base(request.Args[0])
	}
	t := a.newTerminalWith(p, terminalOptions{
		shell: request.Args[0], args: request.Args[1:], env: env, unset: unset,
		title: title, activate: true,
		remoteDirectory:    &core.RemoteScopedDirectory{Root: p.remote.binding.RemoteRoot(), Path: *request.RemoteDirectory},
		remoteConnection:   session.connection,
		remoteStartContext: session.ctx,
		remoteStarted:      reply,
	})
	if t == nil {
		// The failed terminal layout reduction has already been logged.
		reply(0, errors.New(unavailable))
		return
	}
	session.remoteTerminals = append(session.remoteTerminals, t.id)
	a.reduceChrome(core.SetChromeOpen(itemTerminal, true))
}
