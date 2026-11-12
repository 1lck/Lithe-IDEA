package workbench

import (
	"context"
	"fmt"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Debug tool window can show one of the adapter's threads. Core owns the DAP request and
// the thread list; this file only asks for it when the debuggee stops and lets the user pick
// which thread's stack the Frames section shows.

// inspectDebugThreads asks Core for the adapter's threads for the current stop. It does not
// use the variables operation table: that table is cleared when a stack frame is selected,
// and the thread answer can arrive after it.
func (a *App) inspectDebugThreads(p *project, session *debugSession) {
	if p == nil || session == nil {
		return
	}
	p.debug.threadSequence++
	operationID := fmt.Sprintf("%s-threads-%d", session.id, p.debug.threadSequence)
	a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
		session.operationMu.Lock()
		defer session.operationMu.Unlock()
		if session.stopped.Load() {
			return nil
		}
		update, err := a.kernel.InspectDebug(ctx, core.DebugInspectRequest{
			SessionID: session.id, OperationID: operationID, Kind: "threads",
		})
		if err != nil {
			return func(a *App) {
				if a.project == p && p.debug.hasSession(session) {
					defer p.debug.bindSession(session)()
					p.debug.threadsFailure = err.Error()
				}
			}
		}
		if err := session.writeFrames(update.OutboundFrames); err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		a.postDebugUpdate(p, session, update)
		return nil
	})
}

// applyDebugThreads publishes one thread list and keeps the paused thread selected. The
// caller has checked the session and generation.
func (a *App) applyDebugThreads(p *project, session *debugSession, threads []core.DebugThread) {
	d := &p.debug
	d.threads = threads
	d.threadsFailure = ""
	found := false
	for _, thread := range threads {
		if thread.ID == d.selectedThread {
			found = true
			break
		}
	}
	if found {
		return
	}
	d.selectedThread = 0
	if len(threads) > 0 {
		d.selectedThread = threads[0].ID
		if d.pausedThread == nil || d.selectedThread != *d.pausedThread {
			a.inspectDebugStack(p, session, d.selectedThread)
		}
	}
}

// selectDebugThread shows one thread's stack. A thread the adapter no longer lists is ignored.
func (a *App) selectDebugThread(p *project, threadID int64) {
	d := &p.debug
	if d.activeSession() == nil || threadID == d.selectedThread {
		return
	}
	found := false
	for _, thread := range d.threads {
		if thread.ID == threadID {
			found = true
			break
		}
	}
	if !found {
		return
	}
	d.selectedThread = threadID
	d.pausedThread = &threadID
	d.vars.reset()
	d.frames = nil
	d.memory.reset()
	d.watch.valuesCleared()
	// A thread resumed alone has no stack to show until it stops again.
	if d.resumedThreads[threadID] {
		return
	}
	a.inspectDebugStack(p, d.activeSession(), threadID)
}

// canExecuteDebugThread reports which single-thread command the thread menu offers for one
// thread and whether Core would accept it now. Core takes continue only while the session is
// paused and pause only while it runs, and both need the adapter's single-thread support; a
// thread resumed alone while the others stay stopped can therefore not be paused alone.
func canExecuteDebugThread(d *debugState, threadID int64) (command string, enabled bool) {
	if d.activeSession() == nil || d.capabilities == nil || !d.capabilities.SupportsSingleThreadExecutionRequests {
		return "", false
	}
	switch {
	case d.state == "paused" && !d.resumedThreads[threadID]:
		return "continue", true
	case d.state == "paused":
		return "pause", false
	case d.state == "running":
		return "pause", true
	}
	return "", false
}

// executeDebugThread resumes or pauses one thread alone. A request Core refuses is shown as
// a notice and leaves the session as it was: it is about one thread, not the connection.
func (a *App) executeDebugThread(p *project, threadID int64) {
	d := &p.debug
	command, enabled := canExecuteDebugThread(d, threadID)
	if !enabled {
		return
	}
	session := d.activeSession()
	operationID := fmt.Sprintf("%s-%s-thread-%d", session.id, command, threadID)
	a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
		session.operationMu.Lock()
		defer session.operationMu.Unlock()
		if session.stopped.Load() {
			return nil
		}
		update, err := a.kernel.ExecuteDebugThread(ctx, session.id, operationID, command, threadID)
		if err != nil {
			return func(a *App) { a.notify(err.Error()) }
		}
		if err := session.writeFrames(update.OutboundFrames); err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		a.postDebugUpdate(p, session, update)
		return nil
	})
}

// debugThreadResumed records that the adapter resumed one thread while the session stays
// paused. Core keeps the other threads' frames and variables valid, so only what the
// resumed thread showed is dropped.
func (a *App) debugThreadResumed(p *project, threadID int64) {
	d := &p.debug
	if d.resumedThreads == nil {
		d.resumedThreads = make(map[int64]bool)
	}
	d.resumedThreads[threadID] = true
	if threadID != d.selectedThread {
		return
	}
	d.vars.reset()
	d.disassembly.reset()
	d.memory.reset()
	d.frames = nil
	d.exception = nil
	d.watch.valuesCleared()
}

// debugThreadPicker is the thread selector above the call stack. One thread needs no picker.
func (a *App) debugThreadPicker(c ui.C, p *project) {
	d := &p.debug
	if len(d.threads) <= 1 {
		return
	}
	t := a.text.Debug
	indexes := make([]int, len(d.threads))
	selected := 0
	for index, thread := range d.threads {
		indexes[index] = index
		if thread.ID == d.selectedThread {
			selected = index
		}
	}
	k := c.Key("debugThreads")
	row := ui.Row(k).FillWidth().Height(panelHeaderHeight).Shrink(0).PadX(8).Items(ui.Center).
		HitWith(ui.ID(k), t.Threads, gfx.HitOptions{SkipFocus: true})
	row.Children(func() {
		ui.Select(c.Key("debugThread"), &selected, indexes, func(index int) string {
			name := d.threads[index].Name
			if name == "" {
				name = t.ThreadFallback(int(d.threads[index].ID))
			}
			if d.resumedThreads[d.threads[index].ID] {
				name = t.ThreadRunning(name)
			}
			return name
		}).Label(t.Threads).Width(240).Height(24)
		if selected != threadIndexOf(d.threads, d.selectedThread) {
			id := d.threads[selected].ID
			c.After(func() { a.selectDebugThread(p, id) })
		}
	})
	a.debugThreadMenu(k, row, p)
}

// threadIndexOf reports the position of one thread in the list, or 0 when it is absent.
func threadIndexOf(threads []core.DebugThread, id int64) int {
	for index, thread := range threads {
		if thread.ID == id {
			return index
		}
	}
	return 0
}
