package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
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
	// The evaluate field and the watches sit over the variables tree; a window as tall as a
	// laptop screen leaves the bottom panel room for them.
	if err := h.driver.Resize(1280, 900); err != nil {
		t.Fatal(err)
	}
	p.debug.section = debugSectionThreads
	h.app.invalidator.Invalidate()
	h.settle()
	evaluate := i18n.SharedFormat(h.app.language(), "desktop.debug.evaluatePlaceholder", map[string]string{
		"evaluate": shortcuts.Keycaps(debugEvaluateChord),
		"watch":    shortcuts.Keycaps(debugAddWatchChord),
	})
	if _, ok := h.findPageHit("missing"); !ok || !h.shows(evaluate) {
		t.Fatal("the Debug panel does not show the evaluate field and the watches")
	}
	// Enter evaluates the typed expression once and keeps it in the field; Primary+Shift+Enter
	// adds it as a watch.
	h.typeInto(evaluate, func() { p.debug.watch.input = "" }, "count")
	if err := h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 20*time.Second, "the evaluated expression", func() bool {
		e := p.debug.watch.evaluated
		return e != nil && e.expression == "count" && e.value == "42" && e.typeName == "int"
	})
	if p.debug.watch.input != "count" || len(p.debug.watch.entries) != 2 {
		t.Fatalf("Enter left the field %q and %d watches", p.debug.watch.input, len(p.debug.watch.entries))
	}
	if err := h.driver.Key(gfx.KeyEnter, debugAddWatchChord.Modifiers); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 20*time.Second, "the added watch", func() bool {
		entries := p.debug.watch.entries
		return len(entries) == 3 && entries[2].expression == "count" && entries[2].value == "42"
	})
	if p.debug.watch.input != "" {
		t.Fatalf("adding the watch left %q in the field", p.debug.watch.input)
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
	h.rightClickNamed(p.debug.frames[0].Name)
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
	p.debug.section = debugSectionThreads
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

// TestDebugEvaluateAndWatchShowTheirWholeReason checks that a reason the debugger gives for not
// evaluating an expression wraps to be read whole, in the evaluate field's result and in a
// watch, while a watch with a value keeps its row one line tall.
func TestDebugEvaluateAndWatchShowTheirWholeReason(t *testing.T) {
	h, p := pausedDebugSession(t)
	defer releaseLaunchedDebug(h, p)
	if err := h.driver.Resize(1280, 900); err != nil {
		t.Fatal(err)
	}
	reason := func(marker string) string {
		return "Expression evaluation in pure C not supported. Ran expression as 'ISO C++'. " +
			strings.Repeat("error: use of undeclared identifier in the selected frame of the stopped thread; ", 4) + marker
	}
	w := &p.debug.watch
	w.evaluated = &debugWatchEntry{expression: "evaluated", failure: reason("EVALUATED_END")}
	w.entries = []debugWatchEntry{
		{expression: "refused", failure: reason("WATCH_END")},
		{expression: "kept", value: "42", typeName: "int"},
	}
	p.debug.section = debugSectionThreads
	h.app.invalidator.Invalidate()
	h.settle()

	for _, entry := range []debugWatchEntry{*w.evaluated, w.entries[0]} {
		if !h.showsWrapped(entry.failure) {
			t.Fatalf("the reason for %q is not shown whole", entry.expression)
		}
	}
	line := func(part string) gfx.Rect {
		t.Helper()
		for _, label := range h.driver.Snapshot().Labels {
			if strings.Contains(label.Value, part) {
				if strings.Contains(label.Value, "…") {
					t.Fatalf("the reason was cut: %q", label.Value)
				}
				return label.Bounds
			}
		}
		t.Fatalf("no line shows %q", part)
		return gfx.Rect{}
	}
	expression := line("evaluated")
	first, last := line("pure C"), line("EVALUATED_END")
	if last.Y <= first.Y {
		t.Fatalf("the evaluated reason did not wrap: first line %v, last line %v", first, last)
	}
	// The reason's first line sits beside the expression, as a one-line row places both.
	if first.Y != expression.Y {
		t.Fatalf("the reason starts at %v beside the expression at %v", first, expression)
	}
	refused, ok := h.findPageHit("refused")
	if !ok || refused.Bounds.Height <= debugRowHeight {
		t.Fatalf("the refused watch row did not grow for its reason: %+v", refused.Bounds)
	}
	if end := line("WATCH_END"); end.Y+end.Height > refused.Bounds.Y+refused.Bounds.Height {
		t.Fatalf("the watch reason ends at %v below its row %v", end, refused.Bounds)
	}
	kept, ok := h.findPageHit("kept")
	if !ok || kept.Bounds.Height != debugRowHeight {
		t.Fatalf("the watch with a value is not one row tall: %+v", kept.Bounds)
	}
}
