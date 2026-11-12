package workbench

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/vivaui/viva/gfx"
)

// pauseDebugFixture starts the fixture adapter on a stop and waits for its first stack.
func pauseDebugFixture(t *testing.T, h *harness, p *project) {
	t.Helper()
	h.clickNamed(h.app.text.Debug.Start)
	awaitStateWithin(t, h, 30*time.Second, "the paused debuggee and its stack", func() bool {
		if p.debug.failure != "" {
			t.Fatalf("debug start failed: %s", p.debug.failure)
		}
		return p.debug.state == "paused" && len(p.debug.frames) == 2
	})
}

func TestDebugThreadsSelectAndRestartWatchesOnEachStop(t *testing.T) {
	h := debugHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "debug.marker"), []byte("debug\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "tests"), 0o700); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(root, "tests", "debug_source.go")
	if err := os.WriteFile(source, []byte("package tests\n\nfunc main() {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openDebugPanel(t, h, root)
	h.app.openFileAtPosition(p, source, 2, 0)
	h.settle()
	pauseDebugFixture(t, h, p)

	// The fixture lists two threads; the stopped thread is selected.
	awaitStateWithin(t, h, 20*time.Second, "the adapter's threads", func() bool {
		return len(p.debug.threads) == 2 && p.debug.selectedThread == 7
	})
	h.app.selectDebugThread(p, 8)
	awaitStateWithin(t, h, 20*time.Second, "the selected worker thread", func() bool {
		return p.debug.selectedThread == 8 && len(p.debug.frames) == 2
	})

	// A watch evaluates through Core at the selected frame.
	p.debug.watch.input = "count"
	h.app.addDebugWatch(p)
	awaitStateWithin(t, h, 20*time.Second, "the watch value", func() bool {
		return len(p.debug.watch.entries) == 1 && p.debug.watch.entries[0].value == "42"
	})
	if p.debug.watch.entries[0].typeName != "int" {
		t.Fatalf("watch type = %q", p.debug.watch.entries[0].typeName)
	}
	// A refused expression is shown against its own row and does not stay loading.
	p.debug.watch.input = "missing"
	h.app.addDebugWatch(p)
	awaitStateWithin(t, h, 20*time.Second, "the refused watch", func() bool {
		return len(p.debug.watch.entries) == 2 && p.debug.watch.entries[1].failure != ""
	})

	h.clickNamed(h.app.text.Debug.Continue)
	awaitStateWithin(t, h, 20*time.Second, "the continued session", func() bool {
		return p.debug.state == "running" && len(p.debug.frames) == 0 && len(p.debug.threads) == 0
	})
	if p.debug.watch.entries[0].value != "" {
		t.Fatalf("a continued session kept the watch value %q", p.debug.watch.entries[0].value)
	}
	// Waiting stops re-evaluate the kept expressions at the new stop.
	h.clickNamed(h.app.text.Debug.Pause)
	awaitStateWithin(t, h, 20*time.Second, "the watch after the second stop", func() bool {
		return p.debug.state == "paused" && len(p.debug.threads) == 2 &&
			len(p.debug.watch.entries) == 2 && p.debug.watch.entries[0].value == "42"
	})
	// The watch editor sits over the variables tree; a window as tall as a laptop screen leaves
	// the bottom panel room for both under the breakpoints.
	if err := h.driver.Resize(1280, 900); err != nil {
		t.Fatal(err)
	}
	p.debug.section = debugSectionVariables
	h.settle()
	p.debug.section = debugSectionVariables
	h.app.invalidator.Invalidate()
	h.settle()
	if !h.shows("监视") || !h.shows("求值表达式") {
		t.Fatal("the Debug panel does not show the watch editor")
	}

	h.clickNamed(h.app.text.Debug.Stop)
	awaitStateWithin(t, h, 20*time.Second, "the stopped session", func() bool {
		return p.debug.activeSession() == nil
	})
}

func TestDebugThreadResumesAloneAndWatchEditsInPlace(t *testing.T) {
	h, p := pausedDebugSession(t)
	defer releaseLaunchedDebug(h, p)
	// The watch editor needs a laptop-tall window to fit under the breakpoints.
	if err := h.driver.Resize(1280, 900); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 20*time.Second, "the adapter's threads", func() bool {
		return len(p.debug.threads) == 2 && p.debug.selectedThread == 7
	})
	h.app.selectDebugThread(p, 8)
	awaitStateWithin(t, h, 20*time.Second, "the worker thread's stack", func() bool {
		return p.debug.selectedThread == 8 && len(p.debug.frames) == 2
	})
	p.debug.watch.input = "count"
	h.app.addDebugWatch(p)
	awaitStateWithin(t, h, 20*time.Second, "the watch value", func() bool {
		return len(p.debug.watch.entries) == 1 && p.debug.watch.entries[0].value == "42"
	})

	// The adapter supports single-thread requests, so a paused thread can be resumed alone.
	if command, enabled := canExecuteDebugThread(&p.debug, 8); command != "continue" || !enabled {
		t.Fatalf("thread 8 offers %q enabled=%v; want continue", command, enabled)
	}
	h.settle()
	var picker gfx.Rect
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == h.app.text.Debug.Threads && !hit.IsLabel && hit.Bounds.Width > picker.Width {
			picker = hit.Bounds
		}
	}
	h.rightClickAt(gfx.Rect{X: picker.X + picker.Width - 40, Y: picker.Y, Width: 20, Height: picker.Height})
	h.click(center(h.popupHit(h.shared("native.resumeThread"))))
	awaitStateWithin(t, h, 20*time.Second, "the worker resumed alone", func() bool {
		return p.debug.resumedThreads[8] && len(p.debug.frames) == 0
	})
	if p.debug.state != "paused" || len(p.debug.threads) != 2 {
		t.Fatalf("resuming one thread changed the session: state %q threads %d", p.debug.state, len(p.debug.threads))
	}
	if p.debug.watch.entries[0].value != "" {
		t.Fatalf("the resumed thread kept the watch value %q", p.debug.watch.entries[0].value)
	}
	// Core pauses only a running session, so the resumed thread cannot be paused alone yet.
	if command, enabled := canExecuteDebugThread(&p.debug, 8); command != "pause" || enabled {
		t.Fatalf("resumed thread 8 offers %q enabled=%v; want a disabled pause", command, enabled)
	}
	// The thread that is still stopped keeps its stack and watches.
	h.app.selectDebugThread(p, 7)
	awaitStateWithin(t, h, 20*time.Second, "the stopped thread's stack", func() bool {
		return p.debug.selectedThread == 7 && len(p.debug.frames) == 2
	})
	h.app.refreshDebugWatches(p)
	awaitStateWithin(t, h, 20*time.Second, "the watch on the stopped thread", func() bool {
		return p.debug.watch.entries[0].value == "42"
	})

	// Double-clicking a watch turns it into a field; Enter keeps the new expression and
	// evaluates it.
	p.debug.section = debugSectionVariables
	h.app.invalidator.Invalidate()
	h.settle()
	editWatch := func(expression string) {
		t.Helper()
		row, ok := h.findPageHit(p.debug.watch.entries[0].expression)
		if !ok {
			t.Fatalf("the watch %q is not shown", p.debug.watch.entries[0].expression)
		}
		at := center(row.Bounds)
		if err := h.driver.DoubleClick(at.X, at.Y); err != nil {
			t.Fatal(err)
		}
		h.settle()
		h.settle()
		if !p.debug.watch.editOpen {
			t.Fatal("double-clicking the watch did not open it for editing")
		}
		p.debug.watch.edit.SetText(expression)
	}
	editWatch("missing")
	if err := h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 20*time.Second, "the edited watch", func() bool {
		e := p.debug.watch.entries[0]
		return !p.debug.watch.editOpen && e.expression == "missing" && e.failure != ""
	})
	// Escape keeps the old expression.
	editWatch("count")
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if p.debug.watch.editOpen || p.debug.watch.entries[0].expression != "missing" {
		t.Fatalf("Escape left the edit open=%v expression %q", p.debug.watch.editOpen, p.debug.watch.entries[0].expression)
	}
	// The watch menu opens the same field.
	row, ok := h.findPageHit("missing")
	if !ok {
		t.Fatal("the edited watch is not shown")
	}
	h.rightClickAt(row.Bounds)
	h.click(center(h.popupHit(h.shared("native.editWatch"))))
	h.settle()
	if !p.debug.watch.editOpen {
		t.Fatal("the watch menu did not open the watch for editing")
	}
	p.debug.watch.edit.SetText("count")
	if err := h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 20*time.Second, "the watch edited back", func() bool {
		e := p.debug.watch.entries[0]
		return e.expression == "count" && e.value == "42"
	})

	// Continuing the whole session clears the single-thread state.
	h.clickNamed(h.app.text.Debug.Continue)
	awaitStateWithin(t, h, 20*time.Second, "the continued session", func() bool {
		return p.debug.state == "running" && p.debug.resumedThreads == nil
	})
}
