package workbench

import (
	"context"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// A debug adapter is a declarative contribution: no plugin process reports its start, so the
// host records each one as a debugAdapter/start operation on the plugin's channel, under the
// debug session ID. The start runs from launch resolution until the adapter answers initialize:
//
//   - resolve: the adapter's settings, plan, program or state directories cannot be resolved;
//   - launch: the adapter is not reached, meaning its process does not run or its language
//     server's socket does not connect;
//   - timeout: the hosted adapter's discovery deadline, the initialize window, or a write's
//     deadline ran out;
//   - exit: a reached adapter's process or stream ended, or a stdio adapter stopped reading
//     its input, before it answered initialize;
//   - initialize: any other failure of a reached adapter before it answered initialize, a
//     refused initialize included;
//   - finished: the adapter answered initialize.
//
// A start the user stops, or one Core refuses (the debug session itself, a breakpoint), records
// nothing: the session's release abandons a start that has no result yet.

// errDebugAdapterExited stands for an adapter whose process or stream ended before it answered
// initialize. The exit is the failure whatever its status, so it is never a nil error.
var errDebugAdapterExited = errors.New("debug adapter exited before initialize")

// errDebugInitializeRefused stands for an adapter that answered initialize with a failure.
var errDebugInitializeRefused = errors.New("debug adapter refused initialize")

// recordDebugStart records the session's adapter start once it has a result, ending at stage
// with err (nil for finished). The first result wins and later ones do nothing. ctx is the
// start's: a cancelled ctx is a stop, which records nothing and leaves the start open. It
// calls Core, so it never runs on the window thread.
func (a *App) recordDebugStart(ctx context.Context, session *debugSession, stage core.PluginStage, err error) {
	a.plugins.EndAttempt(ctx, session.adapterStart, stage, err)
}

// debugAdapterAnswered ends the adapter start once Core has read the adapter's answer to
// initialize: the session leaves initializing for a state that runs, or for one that ended.
func (a *App) debugAdapterAnswered(session *debugSession, state string) {
	switch state {
	case "", "idle", "initializing":
	case "failed", "terminating", "terminated":
		a.recordDebugStart(session.ctx, session, core.StageInitialize, errDebugInitializeRefused)
	default:
		a.recordDebugStart(session.ctx, session, "", nil)
	}
}

// debugWriteFailed ends a session that could not write to its adapter, or returns nil when
// the write failed only because the hosted stream no longer runs: the user stopped it, or Core
// failed it, and that failure's own report and termination end the start and the session with
// its reason. Before the adapter answered initialize, any other failed write also ends its
// start (a write past the deadline is a timeout):
//
//   - a stdio adapter's input refuses a write only once the adapter stopped reading it, so
//     the adapter left, as its process exit says too, whichever of the two comes first;
//   - a hosted adapter's queue refuses one over its budget before its socket connected,
//     which is a launch that did not reach it, or after, when the adapter takes no handshake.
func (a *App) debugWriteFailed(p *project, session *debugSession, err error) func(*App) {
	if errors.Is(err, errDebugTransportNotRunning) {
		return nil
	}
	stage := debugWriteFailureStage(session.hosted == nil, session.reached.Load())
	a.recordDebugStart(session.ctx, session, stage, err)
	return func(a *App) { a.finishDebugError(p, session, err) }
}

// debugWriteFailureStage is the stage a failed write ends the adapter start at, for a stdio
// adapter whose process runs, or one reached over TCP (tcpLanguageServer or tcpAnnounced)
// whose socket connected or not.
func debugWriteFailureStage(stdio, reached bool) core.PluginStage {
	switch {
	case stdio:
		return core.StageExit
	case reached:
		return core.StageInitialize
	default:
		return core.StageLaunch
	}
}

// hostedFailureStage is the stage at which Core's failure of a TCP-reached adapter's stream ends
// its start: its startup deadline is a timeout; any other failure is a launch until the socket
// connected and an initialize failure after.
func hostedFailureStage(reached bool, reason string) core.PluginStage {
	switch {
	case reason == "startupTimedOut":
		return core.StageTimeout
	case !reached:
		return core.StageLaunch
	default:
		return core.StageInitialize
	}
}
