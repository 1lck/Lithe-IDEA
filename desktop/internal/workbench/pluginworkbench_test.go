package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/app"
)

func hostErrorCode(err error) string {
	var hostErr *pluginservice.HostError
	if errors.As(err, &hostErr) {
		return hostErr.Code
	}
	return ""
}

// callOnWindow runs a Workbench call on its own goroutine while the test pumps the
// window, as the plugin host does.
func callOnWindow[T any](h *harness, what string, call func(ctx context.Context) (T, error)) (T, error) {
	h.t.Helper()
	type outcome struct {
		value T
		err   error
	}
	done := make(chan outcome, 1)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	go func() {
		value, err := call(ctx)
		done <- outcome{value, err}
		// A call that finishes without touching the window would otherwise leave
		// the pump waiting for a wake that never comes.
		h.app.post(func(*App) {})
	}()
	var result outcome
	finished := false
	h.await(what, func() bool {
		select {
		case result = <-done:
			finished = true
		default:
		}
		return finished
	})
	return result.value, result.err
}

func openNote(t *testing.T, h *harness, text string) (string, *document) {
	t.Helper()
	root := t.TempDir()
	path := filepath.Join(root, "note.txt")
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.openFile(h.app.project, path)
	h.settle()
	d := h.app.project.docs.byPath(path)
	if d == nil {
		t.Fatal("the file did not open")
	}
	return root, d
}

func TestPluginEditsGoThroughTheUndoStackAndAreVersioned(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root, d := openNote(t, h, "alpha\nbeta\n")
	w := pluginWorkbench{app: h.app}

	documents, err := callOnWindow(h, "list", func(ctx context.Context) ([]pluginservice.DocumentSummary, error) { return w.Documents(ctx, root) })
	if err != nil || len(documents) != 1 || documents[0].DocumentID != documentPublicID(d) || documents[0].IsDirty || documents[0].IsReadOnly || documents[0].LineEnding != "lf" {
		t.Fatalf("documents = %+v, %v", documents, err)
	}
	if documents[0].Path == nil || *documents[0].Path != "note.txt" {
		t.Fatalf("path = %v", documents[0].Path)
	}
	id, version := documents[0].DocumentID, documents[0].Version

	// A stale version is refused with the current one, and changes nothing.
	_, err = callOnWindow(h, "stale edit", func(ctx context.Context) (pluginservice.EditResult, error) {
		return w.Edit(ctx, root, pluginservice.EditRequest{DocumentID: id, ExpectedVersion: version + 5, Edits: []pluginservice.RangeEdit{{
			Range: pluginservice.Range{Start: pluginservice.Position{Line: 1, Column: 1}, End: pluginservice.Position{Line: 1, Column: 1}}, Text: "x"}}})
	})
	if hostErrorCode(err) != pluginservice.CodeVersionConflict {
		t.Fatalf("stale edit = %v", err)
	}
	if text, _ := d.view.Text(); string(text) != "alpha\nbeta\n" {
		t.Fatalf("a refused edit changed the text: %q", text)
	}

	// Two edits in one batch are one undo step and one version bump.
	result, err := callOnWindow(h, "edit", func(ctx context.Context) (pluginservice.EditResult, error) {
		return w.Edit(ctx, root, pluginservice.EditRequest{DocumentID: id, ExpectedVersion: version, Edits: []pluginservice.RangeEdit{
			{Range: pluginservice.Range{Start: pluginservice.Position{Line: 2, Column: 1}, End: pluginservice.Position{Line: 2, Column: 5}}, Text: "BETA"},
			{Range: pluginservice.Range{Start: pluginservice.Position{Line: 1, Column: 1}, End: pluginservice.Position{Line: 1, Column: 6}}, Text: "ALPHA"},
		}})
	})
	if err != nil || !result.Applied || result.Version == version {
		t.Fatalf("edit = %+v, %v", result, err)
	}
	if text, _ := d.view.Text(); string(text) != "ALPHA\nBETA\n" {
		t.Fatalf("text = %q", text)
	}
	if !d.dirty() {
		t.Fatal("an edit left the document clean")
	}
	if !d.view.Undo() {
		t.Fatal("the batch did not reach the undo stack")
	}
	if text, _ := d.view.Text(); string(text) != "alpha\nbeta\n" {
		t.Fatalf("one undo did not take back the whole batch: %q", text)
	}

	snapshotDocument, text, err := callOnWindow2(h, "snapshot", func(ctx context.Context) (pluginservice.DocumentSummary, string, error) {
		return w.Snapshot(ctx, root, id, 1024)
	})
	if err != nil || text != "alpha\nbeta\n" || snapshotDocument.Version != d.view.Revision() {
		t.Fatalf("snapshot = %+v %q %v", snapshotDocument, text, err)
	}
	if _, _, err = callOnWindow2(h, "small snapshot", func(ctx context.Context) (pluginservice.DocumentSummary, string, error) {
		return w.Snapshot(ctx, root, id, 3)
	}); hostErrorCode(err) != pluginservice.CodeLimitExceeded {
		t.Fatalf("oversize snapshot = %v", err)
	}
	// A context of another workspace is expired.
	if _, err = callOnWindow(h, "other root", func(ctx context.Context) ([]pluginservice.DocumentSummary, error) {
		return w.Documents(ctx, filepath.Join(root, "elsewhere"))
	}); hostErrorCode(err) != pluginservice.CodeContextExpired {
		t.Fatalf("other workspace = %v", err)
	}
}

func callOnWindow2[A, B any](h *harness, what string, call func(ctx context.Context) (A, B, error)) (A, B, error) {
	type pair struct {
		a A
		b B
	}
	result, err := callOnWindow(h, what, func(ctx context.Context) (pair, error) {
		a, b, err := call(ctx)
		return pair{a, b}, err
	})
	return result.a, result.b, err
}

func TestPluginOpenWaitsForTheFileAndSelectsItsCaret(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "a.txt")
	if err := os.WriteFile(path, []byte("one\ntwo three\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	w := pluginWorkbench{app: h.app}
	result, err := callOnWindow(h, "open", func(ctx context.Context) (pluginservice.OpenResult, error) {
		return w.Open(ctx, root, pluginservice.OpenRequest{Path: path, Caret: &pluginservice.Position{Line: 2, Column: 5}})
	})
	if err != nil || result.WasAlreadyOpen || result.AppliedSelection == nil || result.AppliedSelection.Line != 2 || result.AppliedSelection.Column != 5 {
		t.Fatalf("open = %+v, %v", result, err)
	}
	if h.app.project.docs.byPath(path) == nil {
		t.Fatal("the document is not open")
	}
	again, err := callOnWindow(h, "reopen", func(ctx context.Context) (pluginservice.OpenResult, error) {
		return w.Open(ctx, root, pluginservice.OpenRequest{Path: path})
	})
	if err != nil || !again.WasAlreadyOpen {
		t.Fatalf("second open = %+v, %v", again, err)
	}
	_, err = callOnWindow(h, "missing", func(ctx context.Context) (pluginservice.OpenResult, error) {
		return w.Open(ctx, root, pluginservice.OpenRequest{Path: filepath.Join(root, "missing.txt")})
	})
	if hostErrorCode(err) != pluginservice.CodeNotFound {
		t.Fatalf("missing file = %v", err)
	}
}

func TestBackgroundOpenKeepsTheForegroundTab(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root, first := openNote(t, h, "first")
	second := filepath.Join(root, "second.txt")
	if err := os.WriteFile(second, []byte("second"), 0o600); err != nil {
		t.Fatal(err)
	}
	w := pluginWorkbench{app: h.app}
	if _, err := callOnWindow(h, "background open", func(ctx context.Context) (pluginservice.OpenResult, error) {
		return w.Open(ctx, root, pluginservice.OpenRequest{Path: second, Background: true})
	}); err != nil {
		t.Fatal(err)
	}
	if h.app.project.docs.byPath(second) == nil {
		t.Fatal("the background document did not open")
	}
	if selected := h.app.project.selectedDocument(h.app.project.docs.group); selected != first {
		t.Fatal("a background open took the foreground tab")
	}
}

// A document a plugin provides for a URI is read-only, never dirty, never watched,
// and an edit through the host is refused.
func TestVirtualDocumentIsReadOnlyAndHasNoFile(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root, _ := openNote(t, h, "x")
	w := pluginWorkbench{app: h.app}
	uri := "jdt://contents/java.base/java/lang/String.class"
	if _, err := callOnWindow(h, "virtual open", func(ctx context.Context) (struct{}, error) {
		return struct{}{}, w.OpenVirtualDocument(ctx, root, pluginservice.VirtualDocument{URI: uri, Name: "String.class", Text: "class String {}\n", Line: 0, Column: 6})
	}); err != nil {
		t.Fatal(err)
	}
	d := h.app.project.docs.byPath(uri)
	if d == nil || !d.virtual || !d.view.ReadOnly() {
		t.Fatalf("virtual document = %+v", d)
	}
	_, err := callOnWindow(h, "virtual edit", func(ctx context.Context) (pluginservice.EditResult, error) {
		return w.Edit(ctx, root, pluginservice.EditRequest{DocumentID: documentPublicID(d), ExpectedVersion: d.view.Revision(), Edits: []pluginservice.RangeEdit{{
			Range: pluginservice.Range{Start: pluginservice.Position{Line: 1, Column: 1}, End: pluginservice.Position{Line: 1, Column: 1}}, Text: "x"}}})
	})
	if hostErrorCode(err) != pluginservice.CodeReadOnly {
		t.Fatalf("editing a virtual document = %v", err)
	}
	if d.dirty() || len(h.app.project.docs.watches) > 1 {
		t.Fatal("a virtual document is dirty or watched")
	}
	h.app.saveDocument(h.app.project, d.id) // does nothing, writes no file
	if _, statErr := os.Stat(filepath.Join(root, uri)); statErr == nil {
		t.Fatal("saving wrote a file")
	}
	// The same URI selects the open tab instead of making a second one.
	callOnWindow(h, "virtual again", func(ctx context.Context) (struct{}, error) {
		return struct{}{}, w.OpenVirtualDocument(ctx, root, pluginservice.VirtualDocument{URI: uri, Name: "String.class", Text: "changed"})
	})
	count := 0
	for _, doc := range h.app.project.docs.list {
		if doc.path == uri {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("%d tabs for one URI", count)
	}
}

func TestPromptWaitsForTheUserAndCancellationRemovesIt(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	w := pluginWorkbench{app: h.app}
	type result struct {
		choice *int
		err    error
	}
	done := make(chan result, 1)
	go func() {
		choice, err := w.Prompt(context.Background(), pluginservice.PromptRequest{PluginID: "p", Level: "warning", Text: "go?", Actions: []string{"No", "Yes"}})
		done <- result{choice, err}
	}()
	h.await("prompt queued", func() bool { return len(h.app.prompts.queue) == 1 })
	h.settle() // paints the sheet
	one := 1
	h.app.answerPrompt(&one)
	got := <-done
	if got.err != nil || got.choice == nil || *got.choice != 1 {
		t.Fatalf("answer = %+v", got)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancelled := make(chan error, 1)
	go func() {
		_, err := w.Prompt(ctx, pluginservice.PromptRequest{PluginID: "p", Text: "later", Actions: []string{"A"}})
		cancelled <- err
	}()
	h.await("second prompt queued", func() bool { return len(h.app.prompts.queue) == 1 })
	cancel()
	if err := <-cancelled; !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled prompt = %v", err)
	}
	h.await("the cancelled prompt is removed", func() bool { return len(h.app.prompts.queue) == 0 })
}

// A plugin terminal runs a program in the shared Terminal tool window, and its
// natural end is recorded with the status and a snapshot of the output.
func TestPluginTerminalReportsItsExit(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("uses /bin/sh")
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	h.open(root)
	p := h.app.project
	plugin := &pluginTerminal{budget: 1024, done: make(chan pluginservice.TerminalExit, 1)}
	before := len(p.terms.list)
	term := h.app.newTerminalWith(p, terminalOptions{
		shell: "/bin/sh", args: []string{"-c", "echo from-plugin; exit 3"}, dir: root, title: "tool", prefill: "earlier output",
		activate: false, plugin: plugin,
	})
	if term == nil || len(p.terms.list) != before+1 {
		t.Fatal("the terminal was not added next to the user's")
	}
	if h.app.terminalTitle(term) != "tool" {
		t.Fatalf("title = %q", h.app.terminalTitle(term))
	}
	var exit pluginservice.TerminalExit
	got := false
	h.await("the program to end", func() bool {
		select {
		case exit = <-plugin.done:
			got = true
		default:
		}
		return got
	})
	if exit.Reason != "exited" || exit.Code == nil || *exit.Code != 3 {
		t.Fatalf("exit = %+v", exit)
	}
	if !strings.Contains(exit.Retained, "from-plugin") || !strings.Contains(exit.Retained, "earlier output") {
		t.Fatalf("retained = %q", exit.Retained)
	}
	// The tab goes away after the outcome is recorded, and exactly one outcome is sent.
	h.await("the tab to close", func() bool { return p.terms.find(term.id) == nil })
	select {
	case again := <-plugin.done:
		t.Fatalf("a second outcome: %+v", again)
	default:
	}
}

func TestClosingAPluginTerminalRecordsClosedWithTheBudget(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("uses /bin/sh")
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	h.open(root)
	p := h.app.project
	plugin := &pluginTerminal{budget: 0, done: make(chan pluginservice.TerminalExit, 1)}
	term := h.app.newTerminalWith(p, terminalOptions{shell: "/bin/sh", args: []string{"-c", "echo hi; sleep 30"}, dir: root, prefill: "history", plugin: plugin})
	h.settle()
	session := &pluginTerminalSession{app: h.app, project: p, terminal: term.id, plugin: plugin}
	if err := callOnWindowErr(h, "close", func(ctx context.Context) error { return session.Close(ctx, 0) }); err != nil {
		t.Fatal(err)
	}
	exit := <-plugin.done
	if exit.Reason != "closed" || exit.Retained != "" || p.terms.find(term.id) != nil {
		t.Fatalf("exit = %+v, still listed: %v", exit, p.terms.find(term.id) != nil)
	}
}

func callOnWindowErr(h *harness, what string, call func(ctx context.Context) error) error {
	_, err := callOnWindow(h, what, func(ctx context.Context) (struct{}, error) { return struct{}{}, call(ctx) })
	return err
}

func TestBrowserOpenUsesTheSystemOpener(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	var opened []string
	previous := openURL
	openURL = func(address string) error { opened = append(opened, address); return nil }
	t.Cleanup(func() { openURL = previous })
	w := pluginWorkbench{app: h.app}
	if err := callOnWindowErr(h, "open url", func(ctx context.Context) error { return w.OpenExternal(ctx, "https://example.com/") }); err != nil || len(opened) != 1 {
		t.Fatalf("opened %v, %v", opened, err)
	}
	var _ = app.OpenURL
}
