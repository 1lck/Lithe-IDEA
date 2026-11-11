package workbench

import (
	"os"
	"path/filepath"
	"testing"
	"time"
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
