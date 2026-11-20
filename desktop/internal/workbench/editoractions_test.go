package workbench

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/gfx"
)

func TestEditorActionBindingRefreshDropsEarlierCollectionAtSameTextVersion(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	writeFixture(t, root, map[string]string{"source.txt": "content\n"})
	h.open(root)
	p := h.app.project
	h.app.openFile(p, filepath.Join(root, "source.txt"))
	h.settle()
	d := documentNamed(p, "source.txt")
	if d == nil {
		t.Fatal("source document unavailable")
	}
	logger := &treeRecordingLog{}
	h.app.logSink = logger

	// The model, rather than the text, changed while an earlier collection
	// was in flight. Deliver the latest result first and the earlier empty
	// result/error last, with no clock or subprocess race in this regression.
	h.app.clearEditorActions(d)
	old := editorActionSnapshot{documentID: d.id, version: d.view.Revision(), collection: d.actionCollection}
	h.app.clearEditorActions(d)
	current := editorActionSnapshot{documentID: d.id, version: d.view.Revision(), collection: d.actionCollection}
	want := []pluginservice.EditorAction{{ID: "latest", Title: "Latest", Range: pluginservice.EditorActionRange{StartLine: 1, StartColumn: 1, EndLine: 1, EndColumn: 1}}}
	h.app.presentEditorActions(p, current, want, nil, nil)
	h.app.presentEditorActions(p, old, nil, nil, errors.New("earlier collection failed"))
	if len(d.actions) != 1 || d.actions[0].ID != "latest" {
		t.Fatalf("earlier collection replaced current actions: %+v", d.actions)
	}
	logger.mu.Lock()
	defer logger.mu.Unlock()
	for _, event := range logger.events {
		if event.Event == operationFailedEvent && event.Fields["operation"] == "editor_actions" {
			t.Fatal("earlier collection replaced current failure presentation")
		}
	}
}

// writeFixture writes files (relative path to content) below root.
func writeFixture(t *testing.T, root string, files map[string]string) {
	t.Helper()
	for name, content := range files {
		path := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func TestEditorActionRetryDelayDoublesUpToTheCap(t *testing.T) {
	want := []time.Duration{2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second, 30 * time.Second, 30 * time.Second}
	for i, delay := range want {
		if got := editorActionRetryDelay(i + 1); got != delay {
			t.Fatalf("retry %d waits %v, want %v", i+1, got, delay)
		}
	}
}

func TestEditorActionCollectionTimeoutIsRetriedWithinItsBudget(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	writeFixture(t, root, map[string]string{"Main.java": "class Main {}\n"})
	h.open(root)
	p := h.app.project
	h.app.openFile(p, filepath.Join(root, "Main.java"))
	h.settle()
	d := documentNamed(p, "Main.java")
	if d == nil {
		t.Fatal("source document unavailable")
	}
	t.Cleanup(func() {
		if d.actionTimer != nil {
			d.actionTimer.Stop()
		}
	})
	present := func(actions []pluginservice.EditorAction, err error) {
		h.app.clearEditorActions(d)
		snapshot := editorActionSnapshot{documentID: d.id, version: d.view.Revision(), collection: d.actionCollection}
		h.app.presentEditorActions(p, snapshot, actions, nil, err)
	}
	busy := fmt.Errorf("collect: %w", context.DeadlineExceeded)

	// A server still importing answers late: every timeout schedules one more attempt, until the
	// budget is spent.
	for attempt := 1; attempt <= editorActionRetryLimit; attempt++ {
		present(nil, busy)
		if d.actionRetries != attempt || d.actionTimer == nil {
			t.Fatalf("timeout %d: retries=%d timer=%v", attempt, d.actionRetries, d.actionTimer != nil)
		}
	}
	d.actionTimer.Stop()
	d.actionTimer = nil
	present(nil, busy)
	if d.actionRetries != editorActionRetryLimit || d.actionTimer != nil {
		t.Fatalf("a spent budget must not retry: retries=%d timer=%v", d.actionRetries, d.actionTimer != nil)
	}

	// An answer resets the budget and is shown.
	found := []pluginservice.EditorAction{{ID: "run-main", Title: "Run", Range: pluginservice.EditorActionRange{StartLine: 1, StartColumn: 1, EndLine: 1, EndColumn: 1}}}
	present(found, nil)
	if d.actionRetries != 0 || len(d.actions) != 1 {
		t.Fatalf("success must reset retries and show actions: retries=%d actions=%+v", d.actionRetries, d.actions)
	}

	// A failure that is not a timeout would fail the same way again, so it is not retried.
	present(nil, errors.New("malformed answer"))
	if d.actionRetries != 0 || d.actionTimer != nil {
		t.Fatalf("a non-timeout failure must not retry: retries=%d timer=%v", d.actionRetries, d.actionTimer != nil)
	}

	// A document behind another tab is not retried, so a busy server is not asked once per open
	// file; selecting it collects it again with a fresh budget.
	writeFixture(t, root, map[string]string{"Other.java": "class Other {}\n"})
	h.app.openFile(p, filepath.Join(root, "Other.java"))
	h.settle()
	if other := documentNamed(p, "Other.java"); other == nil || p.documentShown(d) {
		t.Fatal("the second file must hide the first behind its tab")
	} else {
		t.Cleanup(func() {
			if other.actionTimer != nil {
				other.actionTimer.Stop()
			}
		})
	}
	present(nil, busy)
	if d.actionRetries != 0 || d.actionTimer != nil || !d.actionsTimedOut {
		t.Fatalf("a hidden document must wait for selection: retries=%d timer=%v timedOut=%v", d.actionRetries, d.actionTimer != nil, d.actionsTimedOut)
	}
	h.app.selectDocument(p, d.id)
	if !p.documentShown(d) || d.actionsTimedOut || d.actionTimer == nil {
		t.Fatalf("selecting a timed-out document must collect it again: shown=%v timedOut=%v timer=%v", p.documentShown(d), d.actionsTimedOut, d.actionTimer != nil)
	}
}

func TestEditorGutterClickOpensActionMenuAndShowsStartingFeedback(t *testing.T) {
	storeDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(storeDir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarnessWithOptions(t, Options{
		Kernel:       &testKernel{Client: core.NewClient()},
		PluginKernel: &testKernel{Client: core.NewClient()},
		PluginRoot:   t.TempDir(),
		Store:        store.At(storeDir),
		Languages:    []string{"en-US"},
	})
	root := t.TempDir()
	writeFixture(t, root, map[string]string{"sample.txt": "line one\nline two\nline three\n"})
	h.open(root)
	p := h.app.project
	h.app.openFile(p, filepath.Join(root, "sample.txt"))
	h.settle()
	d := documentNamed(p, "sample.txt")
	if d == nil {
		t.Fatal("sample document unavailable")
	}

	logger := &treeRecordingLog{}
	h.app.logSink = logger

	h.app.post(func(a *App) {
		a.clearEditorActions(d)
		snapshot := editorActionSnapshot{documentID: d.id, version: d.view.Revision(), collection: d.actionCollection}
		actions := []pluginservice.EditorAction{{
			ID:    "run-sample",
			Title: "Run Sample",
			Icon:  "run",
			Range: pluginservice.EditorActionRange{StartLine: 1, StartColumn: 1, EndLine: 1, EndColumn: 10},
			Alternatives: []pluginservice.EditorActionChoice{{
				ID:    "run-sample-alt",
				Title: "Run Sample Alt",
				Icon:  "run",
			}},
		}}
		a.presentEditorActions(p, snapshot, actions, nil, nil)
	})
	h.settle()

	caret, ok := d.view.CaretRect()
	if !ok {
		t.Fatal("caret rect unavailable for first line")
	}
	y := caret.Y + caret.Height/2
	for x := caret.X - 4; x >= d.lastArea.X+2; x -= 4 {
		h.click(gfx.Point{X: x, Y: y})
		h.settle()
		if d.actionPanel.menuOpen {
			break
		}
	}
	if !d.actionPanel.menuOpen {
		t.Fatalf("clicking across editor gutter [X=%.1f..%.1f, Y=%.1f] did not open action lane menu", d.lastArea.X, caret.X, y)
	}
	if !h.shows("Run Sample") || !h.shows("Run Sample Alt") {
		t.Fatal("action lane menu did not render action and alternative")
	}

	h.clickNamed("Run Sample")
	h.settle()

	wantToast := i18n.SharedFormat(h.app.language(), "desktop.editorActions.starting", map[string]string{"label": "Run Sample"})
	sawToast := false
	for _, entry := range h.app.notifications.list {
		if entry.text == wantToast {
			sawToast = true
			break
		}
	}
	if !sawToast {
		t.Fatalf("expected immediate starting toast %q in %+v", wantToast, h.app.notifications.list)
	}

	sawPerformed := false
	logger.mu.Lock()
	for _, ev := range logger.events {
		if ev.Event == "app.action.performed" && ev.Fields["action"] == "editor.action.invoke" {
			sawPerformed = true
			break
		}
	}
	logger.mu.Unlock()
	if !sawPerformed {
		t.Fatal("expected app.action.performed log event with action=editor.action.invoke")
	}
}
