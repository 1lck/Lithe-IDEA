package pluginbackend

import (
	"context"
	"sync"
)

// traceSwitch keeps the upstream trace of every session a runner started on the value the host
// last chose, as Core's logging README asks: detailed diagnostics reach the sessions already
// running and every session started while they are on, and turning them off, by hand or when
// they expire, reaches the same sessions.
type traceSwitch struct {
	// mu guards everything below except send.
	mu sync.Mutex
	// sessions are the sessions started and not yet stopped or ended.
	sessions map[string]bool
	// enabled is the value the host chose last; generation counts its changes.
	enabled    bool
	generation uint64
	// reported is the generation whose failure was already reported: a broken session or
	// kernel reports one failure per choice, not one per session or per attempt.
	reported uint64
	failed   func(error)
	// send orders the switches the sessions receive, so the last one each gets is the value
	// read last, whichever goroutine sends it.
	send sync.Mutex
}

// SetDetailedDiagnostics turns the upstream trace of every running session this runner started,
// and of every one it starts from now on, on or off. It returns at once: the sessions are told
// on a goroutine of their own, so a caller on the log writer's goroutine is never held up by a
// session. Asking for the value already chosen does nothing.
func (r *Runner) SetDetailedDiagnostics(enabled bool) {
	t := &r.trace
	t.mu.Lock()
	if t.enabled == enabled {
		t.mu.Unlock()
		return
	}
	t.enabled = enabled
	t.generation++
	idle := len(t.sessions) == 0
	t.mu.Unlock()
	if !idle {
		go r.sendTraces()
	}
}

// SetTraceFailed installs the report of a trace switch a running session refused. It is told
// once per choice; a session that ended in the meantime is not a failure. It must be called
// before the first Start.
func (r *Runner) SetTraceFailed(report func(error)) {
	r.trace.mu.Lock()
	r.trace.failed = report
	r.trace.mu.Unlock()
}

// sendTraces tells every tracked session the value chosen last.
func (r *Runner) sendTraces() {
	t := &r.trace
	t.send.Lock()
	defer t.send.Unlock()
	t.mu.Lock()
	enabled, generation := t.enabled, t.generation
	sessions := make([]string, 0, len(t.sessions))
	for id := range t.sessions {
		sessions = append(sessions, id)
	}
	t.mu.Unlock()
	for _, id := range sessions {
		r.sendTrace(id, enabled, generation)
	}
}

// trackTrace starts following a session that just started, and switches its trace on when
// detailed diagnostics are on. Core keeps the value until the handshake ends, so this does not
// wait for the session to be ready.
func (r *Runner) trackTrace(id string) {
	t := &r.trace
	t.send.Lock()
	defer t.send.Unlock()
	t.mu.Lock()
	if t.sessions == nil {
		t.sessions = map[string]bool{}
	}
	t.sessions[id] = true
	enabled, generation := t.enabled, t.generation
	t.mu.Unlock()
	if enabled {
		r.sendTrace(id, true, generation)
	}
}

// untrackTrace stops following a session that is stopping or ended; Core refuses the switch
// for it from then on.
func (r *Runner) untrackTrace(id string) {
	r.trace.mu.Lock()
	delete(r.trace.sessions, id)
	r.trace.mu.Unlock()
}

// sendTrace tells one session. A refusal from a session that is no longer tracked is the
// session ending while it was told, which Core reports as invalid_request like any request to
// an ended session; any other refusal is reported once for the choice.
func (r *Runner) sendTrace(id string, enabled bool, generation uint64) {
	err := r.kernel.SetDetailedDiagnostics(context.Background(), id, enabled)
	if err == nil {
		return
	}
	t := &r.trace
	t.mu.Lock()
	report := t.failed
	if !t.sessions[id] || t.reported == generation {
		report = nil
	}
	if report != nil {
		t.reported = generation
	}
	t.mu.Unlock()
	if report != nil {
		report(err)
	}
}
