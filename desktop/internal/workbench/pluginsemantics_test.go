package workbench

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginlsp"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/gfx"
)

// semanticTestKernel records semantic submissions and answers them with stable
// operation IDs, so a test controls exactly when an answer arrives.
type semanticTestKernel struct {
	*testKernel
	mu       sync.Mutex
	requests []core.PluginSemanticRequest
	next     int
}

func (k *semanticTestKernel) RequestPluginSemantics(_ context.Context, request core.PluginSemanticRequest) (string, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.next++
	k.requests = append(k.requests, request)
	return fmt.Sprintf("op-%d", k.next), nil
}

func (k *semanticTestKernel) requestCount() int {
	k.mu.Lock()
	defer k.mu.Unlock()
	return len(k.requests)
}

func (k *semanticTestKernel) request(index int) core.PluginSemanticRequest {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.requests[index]
}

type semanticFixture struct {
	h      *harness
	kernel *semanticTestKernel
	p      *project
	d      *document
	server *pluginServer
}

// newSemanticFixture opens one document with an already-synchronized fake
// session. Request submission is real, but answers are injected by the test.
func newSemanticFixture(t *testing.T) *semanticFixture {
	t.Helper()
	kernel := &semanticTestKernel{testKernel: &testKernel{Client: core.NewClient()}}
	h := newHarness(t, kernel)
	h.open(t.TempDir())
	service, err := pluginservice.Open(kernel, h.store, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h.app.plugins = service
	p, d := openSyncDocument(t, h, h.app.project.root, "A.java")
	d.languageID = "java"
	uri := "file://" + filepath.ToSlash(d.path)
	tracker := pluginlsp.New(&closeRecordKernel{}, "fake")
	if _, err := tracker.Open(context.Background(), pluginlsp.Document{URI: uri, LanguageID: "java", Text: "one\n"}); err != nil {
		t.Fatal(err)
	}
	server := &pluginServer{
		session: &pluginservice.LanguageSession{
			PluginID:  "test",
			Session:   pluginbackend.Session{ID: "fake"},
			Documents: tracker,
		},
		project:    p,
		cancel:     func() {},
		done:       make(chan struct{}),
		buildReady: true,
	}
	h.app.pluginServerMu.Lock()
	h.app.pluginServers = map[string]*pluginServer{"test": server}
	h.app.pluginServerLanguages = map[string]string{"java": "test"}
	h.app.pluginServerMu.Unlock()
	d.sync.opened, d.sync.pluginID, d.sync.uri = true, "test", uri
	d.sync.running, d.sync.full, d.sync.pending = false, false, nil
	h.app.focusDocument(d.id)
	h.settle()
	return &semanticFixture{h: h, kernel: kernel, p: p, d: d, server: server}
}

func (f *semanticFixture) waitForRequests(t *testing.T, count int) {
	t.Helper()
	awaitDocumentState(t, f.h, func() bool { return f.kernel.requestCount() >= count })
}

func (f *semanticFixture) deliver(t *testing.T, operation, method string, result json.RawMessage) {
	t.Helper()
	f.h.app.applyPluginSemanticEvent(f.server, core.BackendEvent{
		Type:        pluginSemanticCompleted,
		OperationID: operation,
		Method:      method,
		Result:      result,
	})
	// Directly injected events bypass App.post, which normally requests a frame.
	f.h.app.invalidator.Invalidate()
	if err := f.h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
}

func locationsResult(t *testing.T, locations ...core.PluginSemanticLocation) json.RawMessage {
	t.Helper()
	value, err := json.Marshal(map[string]any{"locations": locations})
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func hoverResult(t *testing.T, contents string) json.RawMessage {
	t.Helper()
	value, err := json.Marshal(map[string]any{"hover": map[string]any{
		"contents":   contents,
		"isMarkdown": false,
		"range":      nil,
	}})
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func completionResult(t *testing.T, items ...core.PluginSemanticCompletionItem) json.RawMessage {
	t.Helper()
	value, err := json.Marshal(map[string]any{"items": items, "isIncomplete": false})
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func locationAt(path string, line, column int) core.PluginSemanticLocation {
	return core.PluginSemanticLocation{
		URI:      "file://" + filepath.ToSlash(path),
		FilePath: path,
		Range: core.PluginDocumentRange{
			Start: core.PluginDocumentPosition{Line: line, UTF16Column: column},
			End:   core.PluginDocumentPosition{Line: line, UTF16Column: column + 3},
		},
	}
}

func TestDefinitionMultiTargetSelectionJumpsToChosenTarget(t *testing.T) {
	f := newSemanticFixture(t)
	root := f.p.root
	first := filepath.Join(root, "B.java")
	second := filepath.Join(root, "C.java")
	for _, path := range []string{first, second} {
		if err := os.WriteFile(path, []byte("zero\none\ntwo\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	f.d.view.GoToNavigation(0, 0, false)
	if err := f.h.driver.Key(gfx.KeyF12, 0); err != nil {
		t.Fatal(err)
	}
	f.waitForRequests(t, 1)
	request := f.kernel.request(0)
	if request.Operation != pluginSemanticDefinition || request.URI == "" {
		t.Fatalf("definition request = %+v", request)
	}
	f.deliver(t, "op-1", pluginMethodDefinition, locationsResult(t,
		locationAt(first, 0, 0),
		locationAt(second, 1, 2),
	))
	if !f.h.app.semantics.definition.open || len(f.h.app.semantics.definition.targets) != 2 {
		t.Fatalf("definition popup = %+v", f.h.app.semantics.definition)
	}
	if !f.h.shows("C.java:2:3") || !f.h.shows("B.java:1:1") {
		t.Fatalf("definition labels are missing: %v", f.h.driver.Snapshot().Labels)
	}
	if err := f.h.driver.Key(gfx.KeyDown, 0); err != nil {
		t.Fatal(err)
	}
	if err := f.h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, f.h, func() bool { return f.p.docs.byPath(second) != nil })
	f.h.settle()
	opened := f.p.docs.byPath(second)
	if opened == nil {
		t.Fatal("the chosen target did not open")
	}
	line, column := opened.view.CaretUTF16()
	if line != 1 || column != 2 {
		t.Fatalf("caret = %d:%d, want 1:2", line, column)
	}
	if f.h.app.semantics.definition.open {
		t.Fatal("the definition list stayed open after the jump")
	}
}

func TestDefinitionDropsStaleAnswerAfterCaretMove(t *testing.T) {
	f := newSemanticFixture(t)
	target := filepath.Join(f.p.root, "B.java")
	if err := os.WriteFile(target, []byte("zero\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	f.d.view.GoToNavigation(0, 0, false)
	if err := f.h.driver.Key(gfx.KeyF12, 0); err != nil {
		t.Fatal(err)
	}
	f.waitForRequests(t, 1)
	// Moving the caret makes the request stale; the host cancels it and must
	// ignore the answer that still arrives.
	if err := f.h.driver.Key(gfx.KeyDown, 0); err != nil {
		t.Fatal(err)
	}
	if len(f.h.app.semantics.pending) != 0 {
		t.Fatalf("stale request stayed pending: %+v", f.h.app.semantics.pending)
	}
	f.deliver(t, "op-1", pluginMethodDefinition, locationsResult(t, locationAt(target, 0, 0)))
	if f.h.app.semantics.definition.open {
		t.Fatal("a late definition reopened the popup")
	}
	if f.p.docs.byPath(target) != nil {
		t.Fatal("a late definition opened a file")
	}
}

func TestHoverShowsNormalisedContentsAndEscapeDismisses(t *testing.T) {
	f := newSemanticFixture(t)
	f.d.view.GoToNavigation(0, 1, false)
	if err := f.h.driver.Key(gfx.KeyF1, 0); err != nil {
		t.Fatal(err)
	}
	f.waitForRequests(t, 1)
	if got := f.kernel.request(0).Operation; got != pluginSemanticHover {
		t.Fatalf("operation = %q", got)
	}
	f.deliver(t, "op-1", pluginMethodHover, hoverResult(t, "int add(int left, int right)"))
	if !f.h.app.semantics.hover.open {
		t.Fatal("the hover popup did not open")
	}
	if !f.h.shows("int add(int left, int right)") {
		t.Fatalf("hover contents are not painted: %v", f.h.driver.Snapshot().Labels)
	}
	if err := f.h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	if f.h.app.semantics.hover.open {
		t.Fatal("Escape did not close the hover popup")
	}
}

func TestPointerHoverUsesTheRestingSymbol(t *testing.T) {
	f := newSemanticFixture(t)
	f.h.app.semantics.hoverDelay = -1
	f.d.view.GoToNavigation(0, 1, false)
	f.h.settle()
	rect, ok := f.d.view.CaretRect()
	if !ok {
		t.Fatal("the view has no caret rect")
	}
	if err := f.h.driver.Move(rect.X+2, rect.Y+2); err != nil {
		t.Fatal(err)
	}
	f.waitForRequests(t, 1)
	if got := f.kernel.request(0).Operation; got != pluginSemanticHover {
		t.Fatalf("operation = %q", got)
	}
	f.deliver(t, "op-1", pluginMethodHover, hoverResult(t, "resting symbol"))
	if !f.h.shows("resting symbol") {
		t.Fatalf("pointer hover was not painted: %v", f.h.driver.Snapshot().Labels)
	}
	if err := f.h.driver.Leave(); err != nil {
		t.Fatal(err)
	}
	if f.h.app.semantics.hover.open {
		t.Fatal("leaving the window kept the hover popup")
	}
}

func TestExplicitCompletionAcceptsThroughCoreEdits(t *testing.T) {
	f := newSemanticFixture(t)
	f.d.view.GoToNavigation(0, 0, false)
	if err := f.h.driver.Key(gfx.KeySpace, gfx.ModifierControl); err != nil {
		t.Fatal(err)
	}
	f.waitForRequests(t, 1)
	request := f.kernel.request(0)
	if request.Operation != pluginSemanticCompletion || len(request.CompletionContext) == 0 {
		t.Fatalf("completion request = %+v", request)
	}
	primary := &core.PluginTextEdit{
		Range:   core.PluginDocumentRange{Start: core.PluginDocumentPosition{Line: 0, UTF16Column: 0}, End: core.PluginDocumentPosition{Line: 0, UTF16Column: 3}},
		NewText: "add",
	}
	additional := core.PluginTextEdit{
		Range:   core.PluginDocumentRange{Start: core.PluginDocumentPosition{Line: 0, UTF16Column: 0}, End: core.PluginDocumentPosition{Line: 0, UTF16Column: 0}},
		NewText: "import\n",
	}
	f.deliver(t, "op-1", pluginMethodCompletion, completionResult(t,
		core.PluginSemanticCompletionItem{Label: "add", InsertText: "add", InsertTextFormat: 1, TextEdit: primary, AdditionalTextEdits: []core.PluginTextEdit{additional}},
		core.PluginSemanticCompletionItem{Label: "addAll", InsertText: "addAll", InsertTextFormat: 1},
	))
	if !f.h.app.semantics.completion.open || len(f.h.app.semantics.completion.items) != 2 {
		t.Fatalf("completion popup = %+v", f.h.app.semantics.completion)
	}
	if !f.h.shows("add") || !f.h.shows("addAll") {
		t.Fatalf("completion labels are missing: %v", f.h.driver.Snapshot().Labels)
	}
	if err := f.h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	f.h.settle()
	data, _ := f.d.view.Text()
	if string(data) != "import\nadd\n" {
		t.Fatalf("text = %q, want the Core-applied import and replacement", string(data))
	}
	line, column := f.d.view.CaretUTF16()
	if line != 1 || column != 3 {
		t.Fatalf("caret = %d:%d, want 1:3", line, column)
	}
	if f.h.app.semantics.completion.open {
		t.Fatal("the completion list stayed open after acceptance")
	}
}

func TestCompletionSnippetIsConvertedByCore(t *testing.T) {
	f := newSemanticFixture(t)
	f.d.view.GoToNavigation(0, 0, false)
	if err := f.h.driver.Key(gfx.KeySpace, gfx.ModifierControl); err != nil {
		t.Fatal(err)
	}
	f.waitForRequests(t, 1)
	item := core.PluginSemanticCompletionItem{
		Label:            "call",
		InsertText:       "call",
		InsertTextFormat: 2,
		TextEdit: &core.PluginTextEdit{
			Range:   core.PluginDocumentRange{Start: core.PluginDocumentPosition{Line: 0, UTF16Column: 0}, End: core.PluginDocumentPosition{Line: 0, UTF16Column: 3}},
			NewText: "call(${1:arg})",
		},
	}
	f.deliver(t, "op-1", pluginMethodCompletion, completionResult(t, item))
	if !f.h.app.semantics.completion.open {
		t.Fatal("the completion popup did not open")
	}
	if err := f.h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	f.h.settle()
	data, _ := f.d.view.Text()
	if string(data) != "call(arg)\n" {
		t.Fatalf("text = %q, want Core's plain snippet", string(data))
	}
}

func TestTypingIdentifierStartsDebouncedCompletion(t *testing.T) {
	f := newSemanticFixture(t)
	f.h.app.semantics.autoDelay = -1
	f.d.view.GoToNavigation(0, 3, false)
	if err := f.h.driver.Type("x"); err != nil {
		t.Fatal(err)
	}
	f.waitForRequests(t, 1)
	request := f.kernel.request(0)
	if request.Operation != pluginSemanticCompletion || string(request.CompletionContext) != `{"triggerKind":1}` {
		t.Fatalf("auto completion request = %+v", request)
	}
	f.deliver(t, "op-1", pluginMethodCompletion, completionResult(t, core.PluginSemanticCompletionItem{Label: "onex"}))
	if !f.h.app.semantics.completion.open {
		t.Fatal("the automatic completion list did not open")
	}
}

func TestTypingMemberAccessSendsTriggerCharacter(t *testing.T) {
	f := newSemanticFixture(t)
	f.h.app.semantics.autoDelay = -1
	f.d.view.GoToNavigation(0, 3, false)
	if err := f.h.driver.Type("."); err != nil {
		t.Fatal(err)
	}
	f.waitForRequests(t, 1)
	if got := string(f.kernel.request(0).CompletionContext); got != `{"triggerKind":2,"triggerCharacter":"."}` {
		t.Fatalf("trigger context = %s", got)
	}
}

func TestAutoCompletionIgnoresPasteAndStaleCaret(t *testing.T) {
	f := newSemanticFixture(t)
	f.h.app.semantics.autoDelay = -1
	f.d.view.GoToNavigation(0, 3, false)
	if err := f.h.driver.Type("abc"); err != nil {
		t.Fatal(err)
	}
	f.h.settle()
	if got := f.kernel.requestCount(); got != 0 {
		t.Fatalf("multi-character input requested completion %d times", got)
	}
	if _, ok := autoCompletionContext(editorview.Edit{Text: " "}); ok {
		t.Fatal("a space must not trigger completion")
	}
}
