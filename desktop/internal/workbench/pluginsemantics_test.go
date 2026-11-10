package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
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
	f.h.app.applyServerFeatures(f.server, core.BackendEvent{
		Type:              pluginFeaturesChanged,
		CompletionOptions: &core.CompletionOptions{TriggerCharacters: []string{".", ":"}},
	})
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
	if _, ok := autoCompletionContext(editorview.Edit{Text: " "}, nil); ok {
		t.Fatal("a space must not trigger completion")
	}
}

func TestAutoCompletionUsesDeclaredTriggerCharacters(t *testing.T) {
	// Without declared triggers, punctuation never opens completion.
	if _, ok := autoCompletionContext(editorview.Edit{Text: "."}, nil); ok {
		t.Fatal("an undeclared trigger character opened completion")
	}
	if got, ok := autoCompletionContext(editorview.Edit{Text: "a"}, nil); !ok || string(got) != `{"triggerKind":1}` {
		t.Fatalf("identifier context = %s, %v", got, ok)
	}
	if got, ok := autoCompletionContext(editorview.Edit{Text: "@"}, []string{"@"}); !ok || string(got) != `{"triggerKind":2,"triggerCharacter":"@"}` {
		t.Fatalf("declared trigger context = %s, %v", got, ok)
	}
	if _, ok := autoCompletionContext(editorview.Edit{Text: ">"}, []string{"."}); ok {
		t.Fatal("a character the server did not declare opened completion")
	}
}

func TestFeaturesChangedReplacesTriggerCharacters(t *testing.T) {
	f := newSemanticFixture(t)
	apply := func(options *core.CompletionOptions) {
		f.h.app.applyServerFeatures(f.server, core.BackendEvent{Type: pluginFeaturesChanged, CompletionOptions: options})
	}
	apply(&core.CompletionOptions{TriggerCharacters: []string{"."}})
	if got := f.server.completionTriggers; len(got) != 1 || got[0] != "." {
		t.Fatalf("triggers = %v", got)
	}
	apply(nil)
	if f.server.completionTriggers != nil {
		t.Fatalf("triggers after completion withdrawn = %v", f.server.completionTriggers)
	}
}

func TestFindReferencesListsEvenOneResultAndOpensChosen(t *testing.T) {
	f := newSemanticFixture(t)
	target := filepath.Join(f.p.root, "B.java")
	if err := os.WriteFile(target, []byte("zero\none\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	f.d.view.GoToNavigation(0, 0, false)
	if err := f.h.driver.Key(gfx.KeyF12, gfx.ModifierShift); err != nil {
		t.Fatal(err)
	}
	f.waitForRequests(t, 1)
	if got := f.kernel.request(0).Operation; got != pluginSemanticReferences {
		t.Fatalf("operation = %q", got)
	}
	f.deliver(t, "op-1", pluginMethodReferences, locationsResult(t, locationAt(target, 1, 1)))
	state := f.h.app.semantics.definition
	if !state.open || !state.references || len(state.targets) != 1 {
		t.Fatalf("references popup = %+v", state)
	}
	if err := f.h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, f.h, func() bool { return f.p.docs.byPath(target) != nil })
}

func TestReferencesListIsBoundedAndWindowed(t *testing.T) {
	f := newSemanticFixture(t)
	locations := make([]core.PluginSemanticLocation, 0, maxReferenceTargets+20)
	for i := 0; i < maxReferenceTargets+20; i++ {
		locations = append(locations, locationAt(filepath.Join(f.p.root, "B.java"), i, 0))
	}
	f.d.view.GoToNavigation(0, 0, false)
	if err := f.h.driver.Key(gfx.KeyF12, gfx.ModifierShift); err != nil {
		t.Fatal(err)
	}
	f.waitForRequests(t, 1)
	f.deliver(t, "op-1", pluginMethodReferences, locationsResult(t, locations...))
	if got := len(f.h.app.semantics.definition.targets); got != maxReferenceTargets {
		t.Fatalf("targets = %d, want %d", got, maxReferenceTargets)
	}
	for i := 0; i < 30; i++ {
		if err := f.h.driver.Key(gfx.KeyDown, 0); err != nil {
			t.Fatal(err)
		}
	}
	if !f.h.shows("B.java:31:1") {
		t.Fatalf("the selected row is outside the window: %v", f.h.driver.Snapshot().Labels)
	}
}

func TestNonFileDefinitionTargetIsReportedNotCrashed(t *testing.T) {
	f := newSemanticFixture(t)
	f.d.view.GoToNavigation(0, 0, false)
	if err := f.h.driver.Key(gfx.KeyF12, 0); err != nil {
		t.Fatal(err)
	}
	f.waitForRequests(t, 1)
	readOnly := true
	f.deliver(t, "op-1", pluginMethodDefinition, locationsResult(t, core.PluginSemanticLocation{
		URI: "jdt://contents/java.base/java.lang/String.class", IsReadOnly: readOnly,
	}))
	if f.h.app.semantics.definition.open {
		t.Fatal("a non-file target opened a list")
	}
	if !f.h.shows("目标不是本地文件，暂时无法打开。") {
		t.Fatalf("no unavailable notice: %v", f.h.driver.Snapshot().Labels)
	}
}

func formatEditsResult(t *testing.T, edits ...core.PluginTextEdit) json.RawMessage {
	t.Helper()
	value, err := json.Marshal(map[string]any{"edits": edits})
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func formatShortcut(f *semanticFixture) gfx.KeyEvent {
	mods := gfx.ModifierControl | gfx.ModifierAlt
	if runtime.GOOS == "darwin" {
		mods = gfx.ModifierMeta | gfx.ModifierAlt
	}
	return gfx.KeyEvent{Text: "l", Modifiers: mods, Target: docViews.At(f.d.id)}
}

func TestFormatDocumentAppliesLocalEditsOnUndoStack(t *testing.T) {
	f := newSemanticFixture(t)
	f.d.view.GoToNavigation(0, 3, false)
	if !f.h.app.pluginEditShortcut(formatShortcut(f)).Handled {
		t.Fatal("the format shortcut was not handled")
	}
	f.waitForRequests(t, 1)
	if got := f.kernel.request(0); got.Operation != pluginSemanticFormatting || got.Position != nil {
		t.Fatalf("format request = %+v", got)
	}
	f.deliver(t, "op-1", pluginMethodFormatting, formatEditsResult(t, core.PluginTextEdit{
		Range:   core.PluginDocumentRange{Start: core.PluginDocumentPosition{Line: 0, UTF16Column: 0}, End: core.PluginDocumentPosition{Line: 0, UTF16Column: 3}},
		NewText: "ONE",
	}))
	f.h.settle()
	data, _ := f.d.view.Text()
	if string(data) != "ONE\n" {
		t.Fatalf("text = %q", data)
	}
	if !f.d.view.Undo() {
		t.Fatal("formatting is not on the undo stack")
	}
	data, _ = f.d.view.Text()
	if string(data) != "one\n" {
		t.Fatalf("undo text = %q", data)
	}
}

func TestFormatDocumentSendsEditorIndentation(t *testing.T) {
	f := newSemanticFixture(t)
	f.h.app.pluginEditShortcut(formatShortcut(f))
	f.waitForRequests(t, 1)
	got := f.kernel.request(0)
	if got.FormattingOptions == nil || got.FormattingOptions.TabSize != 4 || !got.FormattingOptions.InsertSpaces || got.Range != nil {
		t.Fatalf("format request = %+v options %+v", got, got.FormattingOptions)
	}
}

func TestFormatSelectionSendsRangeAndAppliesOnUndoStack(t *testing.T) {
	f := newSemanticFixture(t)
	f.d.view.GoToNavigation(0, 0, false)
	f.d.view.SelectAll()
	f.h.app.pluginEditShortcut(formatShortcut(f))
	f.waitForRequests(t, 1)
	got := f.kernel.request(0)
	want := core.PluginDocumentRange{Start: core.PluginDocumentPosition{Line: 0, UTF16Column: 0}, End: core.PluginDocumentPosition{Line: 1, UTF16Column: 0}}
	if got.Operation != pluginSemanticRangeFormatting || got.Range == nil || *got.Range != want || got.FormattingOptions == nil {
		t.Fatalf("range format request = %+v", got)
	}
	f.deliver(t, "op-1", pluginMethodRangeFormatting, formatEditsResult(t, core.PluginTextEdit{
		Range:   core.PluginDocumentRange{Start: core.PluginDocumentPosition{Line: 0, UTF16Column: 0}, End: core.PluginDocumentPosition{Line: 0, UTF16Column: 3}},
		NewText: "ONE",
	}))
	f.h.settle()
	if data, _ := f.d.view.Text(); string(data) != "ONE\n" {
		t.Fatalf("text = %q", data)
	}
	if !f.d.view.Undo() {
		t.Fatal("range formatting is not on the undo stack")
	}
	if data, _ := f.d.view.Text(); string(data) != "one\n" {
		t.Fatalf("undo text = %q", data)
	}
}

func TestFormatSelectionDropsAnswerForChangedDocument(t *testing.T) {
	f := newSemanticFixture(t)
	f.d.view.SelectAll()
	f.h.app.pluginEditShortcut(formatShortcut(f))
	f.waitForRequests(t, 1)
	if err := f.h.driver.Type("x"); err != nil {
		t.Fatal(err)
	}
	f.deliver(t, "op-1", pluginMethodRangeFormatting, formatEditsResult(t, core.PluginTextEdit{
		Range:   core.PluginDocumentRange{Start: core.PluginDocumentPosition{Line: 0, UTF16Column: 0}, End: core.PluginDocumentPosition{Line: 0, UTF16Column: 1}},
		NewText: "Z",
	}))
	f.h.settle()
	if data, _ := f.d.view.Text(); string(data) == "Zne\n" || string(data) == "Z\n" {
		t.Fatalf("stale range formatting changed the text: %q", data)
	}
}

func TestFormatDocumentDropsAnswerForChangedDocument(t *testing.T) {
	f := newSemanticFixture(t)
	f.d.view.GoToNavigation(0, 3, false)
	f.h.app.pluginEditShortcut(formatShortcut(f))
	f.waitForRequests(t, 1)
	if err := f.h.driver.Type("x"); err != nil {
		t.Fatal(err)
	}
	f.deliver(t, "op-1", pluginMethodFormatting, formatEditsResult(t, core.PluginTextEdit{
		Range:   core.PluginDocumentRange{Start: core.PluginDocumentPosition{Line: 0, UTF16Column: 0}, End: core.PluginDocumentPosition{Line: 0, UTF16Column: 1}},
		NewText: "Z",
	}))
	f.h.settle()
	data, _ := f.d.view.Text()
	if string(data) != "onex\n" {
		t.Fatalf("stale formatting changed the text: %q", data)
	}
}

func TestFormatDocumentWithoutEditsSaysNothingToFormat(t *testing.T) {
	f := newSemanticFixture(t)
	f.h.app.pluginEditShortcut(formatShortcut(f))
	f.waitForRequests(t, 1)
	f.deliver(t, "op-1", pluginMethodFormatting, formatEditsResult(t))
	if !f.h.shows("没有需要格式化的内容。") {
		t.Fatalf("no notice: %v", len(f.h.driver.Snapshot().Labels))
	}
}

func renameChangesResult(t *testing.T, changes map[string][]core.PluginTextEdit) json.RawMessage {
	t.Helper()
	// A language server names files by their real path.
	real := make(map[string][]core.PluginTextEdit, len(changes))
	for path, edits := range changes {
		real[realPath(path)] = edits
	}
	value, err := json.Marshal(map[string]any{"changes": real})
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func wordEdit(line, from, to int, text string) []core.PluginTextEdit {
	return []core.PluginTextEdit{{
		Range:   core.PluginDocumentRange{Start: core.PluginDocumentPosition{Line: line, UTF16Column: from}, End: core.PluginDocumentPosition{Line: line, UTF16Column: to}},
		NewText: text,
	}}
}

// startRename opens the dialog on the open document, types the name and
// confirms, then waits for Core's request.
func startRename(t *testing.T, f *semanticFixture, name string) {
	t.Helper()
	f.d.view.GoToNavigation(0, 1, false)
	if err := f.h.driver.Key(gfx.KeyF2, 0); err != nil {
		t.Fatal(err)
	}
	state := &f.h.app.semantics.rename
	if !state.open || state.name.Text() != "one" {
		t.Fatalf("rename dialog = open %v name %q", state.open, state.name.Text())
	}
	state.name.SetText(name)
	f.h.app.confirmPluginRename()
	f.waitForRequests(t, 1)
	request := f.kernel.request(0)
	if request.Operation != pluginSemanticRename || request.NewName != name || request.Position == nil {
		t.Fatalf("rename request = %+v", request)
	}
}

func TestRenameUpdatesOpenDocumentAndClosedFile(t *testing.T) {
	f := newSemanticFixture(t)
	closed := filepath.Join(f.p.root, "B.java")
	if err := os.WriteFile(closed, []byte("one two\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	startRename(t, f, "uno")
	f.deliver(t, "op-1", pluginMethodRename, renameChangesResult(t, map[string][]core.PluginTextEdit{
		f.d.path: wordEdit(0, 0, 3, "uno"),
		closed:   wordEdit(0, 0, 3, "uno"),
	}))
	awaitDocumentState(t, f.h, func() bool {
		data, _ := f.d.view.Text()
		return string(data) == "uno\n"
	})
	written, err := os.ReadFile(closed)
	if err != nil || string(written) != "uno two\n" {
		t.Fatalf("closed file = %q, %v", written, err)
	}
	if f.h.app.semantics.rename.open {
		t.Fatal("the rename dialog stayed open")
	}
	if !f.d.view.Undo() {
		t.Fatal("the open document edit is not undoable")
	}
	data, _ := f.d.view.Text()
	if string(data) != "one\n" {
		t.Fatalf("undo text = %q", data)
	}
}

func TestRenameRollsBackWrittenFilesWhenALaterWriteFails(t *testing.T) {
	f := newSemanticFixture(t)
	first, second := filepath.Join(f.p.root, "B.java"), filepath.Join(f.p.root, "C.java")
	for _, path := range []string{first, second} {
		if err := os.WriteFile(path, []byte("one\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	real := f.h.app.documentWriter
	failing := realPath(second)
	f.h.app.documentWriter = func(path string, data, expected []byte) error {
		if path == failing {
			return errors.New("disk full")
		}
		return real(path, data, expected)
	}
	startRename(t, f, "uno")
	f.deliver(t, "op-1", pluginMethodRename, renameChangesResult(t, map[string][]core.PluginTextEdit{
		first:  wordEdit(0, 0, 3, "uno"),
		second: wordEdit(0, 0, 3, "uno"),
	}))
	awaitDocumentState(t, f.h, func() bool { return f.h.shows("无法完成重命名，已写入的文件已恢复。") })
	for _, path := range []string{first, second} {
		data, err := os.ReadFile(path)
		if err != nil || string(data) != "one\n" {
			t.Fatalf("%s = %q, %v (want restored)", path, data, err)
		}
	}
	data, _ := f.d.view.Text()
	if string(data) != "one\n" {
		t.Fatalf("open document changed despite the failed commit: %q", data)
	}
}

func TestRenameOutsideWorkspaceIsRejectedBeforeAnyWrite(t *testing.T) {
	f := newSemanticFixture(t)
	outside := filepath.Join(t.TempDir(), "X.java")
	if err := os.WriteFile(outside, []byte("one\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	startRename(t, f, "uno")
	f.deliver(t, "op-1", pluginMethodRename, renameChangesResult(t, map[string][]core.PluginTextEdit{
		f.d.path: wordEdit(0, 0, 3, "uno"),
		outside:  wordEdit(0, 0, 3, "uno"),
	}))
	awaitDocumentState(t, f.h, func() bool {
		return f.h.shows("重命名涉及项目之外的文件或只读文档，未做任何更改。")
	})
	data, _ := f.d.view.Text()
	disk, _ := os.ReadFile(outside)
	if string(data) != "one\n" || string(disk) != "one\n" {
		t.Fatalf("rename wrote despite rejection: %q %q", data, disk)
	}
}

func TestRenameCancelClosesDialogWithoutRequest(t *testing.T) {
	f := newSemanticFixture(t)
	f.d.view.GoToNavigation(0, 1, false)
	if err := f.h.driver.Key(gfx.KeyF6, gfx.ModifierShift); err != nil {
		t.Fatal(err)
	}
	if !f.h.app.semantics.rename.open {
		t.Fatal("Shift+F6 did not open rename")
	}
	f.h.app.cancelPluginRename()
	f.h.settle()
	if f.h.app.semantics.rename.open || f.kernel.requestCount() != 0 {
		t.Fatal("cancel left state or sent a request")
	}
}
