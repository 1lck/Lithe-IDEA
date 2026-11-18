package workbench

import (
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// Runs of different keys run beside each other and beside the Build window's task, and each
// stops on its own. The window used to hold one execution, so a second service could not start
// while the first ran.
func TestRunsOfDifferentKeysRunTogether(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(runConfigRoot(t))
	p := h.app.project
	var first, second, task *buildOperation
	h.app.post(func(a *App) {
		first = a.beginRunOperation(p, "A", "a", configurationRunKey("a"), nil)
		second = a.beginRunOperation(p, "B", "b", configurationRunKey("b"), nil)
		task = a.beginBuildOperation(p, "build", "vet", "", nil)
	})
	h.settle()
	if !p.build.owns(first) || !p.build.owns(second) || !p.build.owns(task) {
		t.Fatal("an execution was replaced by the next")
	}
	if p.build.runOf(configurationRunKey("a")) != first || p.build.runOf(configurationRunKey("b")) != second || p.build.latest() != task {
		t.Fatalf("runOf a %p b %p latest %p", p.build.runOf(configurationRunKey("a")), p.build.runOf(configurationRunKey("b")), p.build.latest())
	}

	h.app.post(func(a *App) { a.stopOperation(p, first) })
	h.settle()
	if !first.cancelled || second.cancelled || task.cancelled {
		t.Fatalf("stopping one run stopped others: first %v second %v task %v", first.cancelled, second.cancelled, task.cancelled)
	}
	h.app.post(func(a *App) {
		a.endBuildOperation(p, first, "cancelled", nil, "", a.text.Build.Cancelled)
	})
	h.settle()
	if p.build.owns(first) || !p.build.owns(second) || !p.build.owns(task) || first.session.running || !second.session.running {
		t.Fatal("ending one run ended others")
	}
	if detail := runDetail(p, second.session); detail != h.app.text.Build.Preparing {
		t.Fatalf("the second run's line is %q, want its own state, not the first run's", detail)
	}
	h.app.post(func(a *App) {
		a.endBuildOperation(p, second, "cancelled", nil, "", a.text.Build.Cancelled)
		a.endBuildOperation(p, task, "completed", nil, "", a.text.Build.Cancelled)
	})
	h.settle()
	if p.build.active() {
		t.Fatal("executions remain after all ended")
	}
}

// Starting a run of a key that runs stops the one that runs and starts the new one only once it
// ended, as IDEA's Rerun does, so the two never hold the same port.
func TestStartRunReplacesTheRunOfItsKeyOnceItEnded(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(runConfigRoot(t))
	p := h.app.project
	key := configurationRunKey("a")
	var old, replacement *buildOperation
	starts := 0
	start := func(a *App, p *project) {
		starts++
		replacement = a.beginRunOperation(p, "A", "a", key, nil)
	}
	h.app.post(func(a *App) {
		old = a.beginRunOperation(p, "A", "a", key, nil)
		a.startRun(p, key, start)
		// Asked again while the stop is pending, the start replaces the waiting one.
		a.startRun(p, key, start)
	})
	h.settle()
	if !old.cancelled || starts != 0 {
		t.Fatalf("old run cancelled %v, %d starts before it ended", old.cancelled, starts)
	}
	h.app.post(func(a *App) { a.endBuildOperation(p, old, "cancelled", nil, "", a.text.Build.Cancelled) })
	h.settle()
	if starts != 1 || replacement == nil || p.build.runOf(key) != replacement {
		t.Fatalf("%d starts after the old run ended, run of the key %p, want the replacement %p", starts, p.build.runOf(key), replacement)
	}
	// A project that closes drops a start that waits for its run to end.
	h.app.post(func(a *App) {
		a.startRun(p, key, start)
		a.stopBuildSessions(p, false)
	})
	h.settle()
	if starts != 1 || p.build.active() {
		t.Fatalf("%d starts, active %v after the sessions were stopped", starts, p.build.active())
	}
}

// A service's session is marked running once its process starts, not only while it is
// prepared (#2071), and Run on the configuration that runs restarts it: the old process ends
// before the new one starts.
func TestServiceRunShowsRunningAndRestartsInPlace(t *testing.T) {
	h := connectionDebugHarness(t, nil)
	p, id := openServiceDebugProject(t, h)
	var first *buildOperation
	h.app.post(func(a *App) {
		a.runConfiguration(p, id)
		first = p.build.runOf(configurationRunKey(id))
	})
	h.settle()
	if first == nil {
		t.Fatal("Run started nothing")
	}
	awaitStateWithin(t, h, time.Minute, "the service process", func() bool { return first.session.processRunning || !first.session.running })
	if !first.session.running || runDetail(p, first.session) != h.app.text.Build.Running {
		t.Fatalf("the service is not running: status %q, console:\n%s", p.build.status, first.session.output.all())
	}

	h.app.post(func(a *App) { a.runConfiguration(p, id) })
	awaitStateWithin(t, h, time.Minute, "the restarted service", func() bool {
		next := p.build.runOf(configurationRunKey(id))
		return next != nil && next != first && next.session.processRunning
	})
	if first.session.running || first.session.outcome != runStopped {
		t.Fatalf("the first run still runs or did not end as stopped: running %v outcome %v", first.session.running, first.session.outcome)
	}
	if len(p.build.running) != 1 {
		t.Fatalf("%d runs after the restart, want 1", len(p.build.running))
	}
	next := p.build.runOf(configurationRunKey(id))
	h.app.post(func(a *App) { a.stopOperation(p, next) })
	awaitStateWithin(t, h, time.Minute, "the stopped service", func() bool { return !p.build.active() })
}
