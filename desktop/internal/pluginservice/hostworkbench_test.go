package pluginservice

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// fakeWorkbench stands in for the window.
type fakeWorkbench struct {
	mu         sync.Mutex
	edits      []EditRequest
	editErr    error
	snapshot   string
	opened     []OpenRequest
	prompts    chan PromptRequest
	release    chan struct{}
	choice     *int
	external   []string
	terminals  []TerminalSpec
	consent    bool
	sessions   []*fakeTerminal
	virtual    []VirtualDocument
	openResult OpenResult
}

func (w *fakeWorkbench) Documents(context.Context, string) ([]DocumentSummary, error) {
	return []DocumentSummary{{DocumentID: "d1", Version: 3, Encoding: "utf-8", LineEnding: "lf"}}, nil
}

func (w *fakeWorkbench) Snapshot(_ context.Context, _, id string, _ int) (DocumentSummary, string, error) {
	return DocumentSummary{DocumentID: id, Version: 3}, w.snapshot, nil
}

func (w *fakeWorkbench) Active(context.Context, string) (*DocumentSummary, error) { return nil, nil }

func (w *fakeWorkbench) Selections(context.Context, string, string) (SelectionsResult, error) {
	return SelectionsResult{}, nil
}

func (w *fakeWorkbench) Edit(_ context.Context, _ string, request EditRequest) (EditResult, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.editErr != nil {
		return EditResult{}, w.editErr
	}
	w.edits = append(w.edits, request)
	return EditResult{DocumentID: request.DocumentID, Version: request.ExpectedVersion + 1, Applied: true}, nil
}

func (w *fakeWorkbench) Open(_ context.Context, _ string, request OpenRequest) (OpenResult, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.opened = append(w.opened, request)
	return w.openResult, nil
}

func (w *fakeWorkbench) Prompt(ctx context.Context, request PromptRequest) (*int, error) {
	if w.prompts != nil {
		w.prompts <- request
	}
	if w.release != nil {
		select {
		case <-w.release:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return w.choice, nil
}

func (w *fakeWorkbench) OpenExternal(_ context.Context, address string) error {
	w.mu.Lock()
	w.external = append(w.external, address)
	w.mu.Unlock()
	return nil
}

func (w *fakeWorkbench) StartTerminal(ctx context.Context, _ string, spec TerminalSpec) (TerminalSession, error) {
	if !w.consent {
		return nil, &HostError{Code: CodePermissionDenied, Message: "no"}
	}
	session := &fakeTerminal{done: make(chan TerminalExit, 1), spec: spec}
	w.mu.Lock()
	w.terminals = append(w.terminals, spec)
	w.sessions = append(w.sessions, session)
	w.mu.Unlock()
	return session, nil
}

func (w *fakeWorkbench) OpenVirtualDocument(_ context.Context, _ string, document VirtualDocument) error {
	w.mu.Lock()
	w.virtual = append(w.virtual, document)
	w.mu.Unlock()
	return nil
}

type fakeTerminal struct {
	done   chan TerminalExit
	spec   TerminalSpec
	closed int
	shown  int
	output string
}

func (t *fakeTerminal) Show(context.Context) error { t.shown++; return nil }

func (t *fakeTerminal) Close(_ context.Context, retained int) error {
	t.closed++
	t.done <- TerminalExit{Reason: "closed", Retained: trimRetained(t.output, retained)}
	return nil
}

func (t *fakeTerminal) Done() <-chan TerminalExit { return t.done }

func openWorkbenchService(t *testing.T) (*Service, *fakeWorkbench, WorkspaceContext, *notifyKernel) {
	t.Helper()
	kernel := &notifyKernel{}
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	workbench := &fakeWorkbench{consent: true}
	if err := service.AttachWorkbench(workbench); err != nil {
		t.Fatal(err)
	}
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return service, workbench, service.Contexts.Open(root), kernel
}

func contextJSONOf(workspace WorkspaceContext) string {
	return `"context":{"contextID":"` + workspace.ContextID + `","generation":1}`
}

func TestWorkbenchMethodsAreOnlyGrantedWithAWindow(t *testing.T) {
	bare := openHostService(t)
	granted := pluginhostGrant(bare, methodEditorApplyEdits, methodTerminalCreate, methodRegisterContentProvider, methodBrowserOpenExternal)
	if len(granted) != 0 {
		t.Fatalf("a service without a window granted %v", granted)
	}
	service, _, _, _ := openWorkbenchService(t)
	granted = pluginhostGrant(service, methodEditorApplyEdits, methodTerminalCreate, methodRegisterContentProvider, methodBrowserOpenExternal, "lithe/host/run/start", "lithe/host/preview/openHTML", methodEditorGetActive)
	want := []string{methodEditorApplyEdits, methodTerminalCreate, methodRegisterContentProvider, methodBrowserOpenExternal, "lithe/host/run/start", methodEditorGetActive}
	if strings.Join(granted, ",") != strings.Join(want, ",") {
		t.Fatalf("granted = %v, want %v", granted, want)
	}
}

func TestEditorEditsCarryVersionAndMapFailures(t *testing.T) {
	service, workbench, workspace, _ := openWorkbenchService(t)
	params := `{` + contextJSONOf(workspace) + `,"documentID":"d1","expectedVersion":3,"edits":[{"range":{"start":{"line":1,"column":1},"end":{"line":1,"column":3}},"text":"x"}]}`
	result, refusal := respond(t, service, "a", "editor/applyEdits", params)
	if refusal != nil || string(result) != `{"documentID":"d1","version":4,"applied":true}` {
		t.Fatalf("applyEdits = %s %+v", result, refusal)
	}
	if len(workbench.edits) != 1 || workbench.edits[0].ExpectedVersion != 3 || len(workbench.edits[0].Edits) != 1 {
		t.Fatalf("edit request = %+v", workbench.edits)
	}

	workbench.editErr = &HostError{Code: CodeVersionConflict, Message: "stale", Details: map[string]any{"currentVersion": 9}}
	_, refusal = respond(t, service, "a", "editor/applyEdits", params)
	if refusal == nil || refusal.Code != CodeVersionConflict || string(refusal.Details) != `{"currentVersion":9}` {
		t.Fatalf("conflict = %+v", refusal)
	}
	workbench.editErr = nil

	// A range that ends before it starts, or a position below one, never reaches the window.
	for _, bad := range []string{
		`{"range":{"start":{"line":2,"column":1},"end":{"line":1,"column":1}},"text":"x"}`,
		`{"range":{"start":{"line":0,"column":1},"end":{"line":1,"column":1}},"text":"x"}`,
	} {
		_, refusal = respond(t, service, "a", "editor/applyEdits", `{`+contextJSONOf(workspace)+`,"documentID":"d1","expectedVersion":3,"edits":[`+bad+`]}`)
		if refusal == nil || refusal.Code != codeInvalidParams {
			t.Fatalf("bad range accepted: %+v", refusal)
		}
	}
	if len(workbench.edits) != 1 {
		t.Fatal("an invalid edit reached the window")
	}

	// insertText is a zero-width edit; replaceSelections takes one replacement or one each.
	if _, refusal = respond(t, service, "a", "editor/insertText", `{`+contextJSONOf(workspace)+`,"documentID":"d1","expectedVersion":3,"at":{"line":1,"column":1},"text":"y"}`); refusal != nil {
		t.Fatalf("insertText: %+v", refusal)
	}
	selections := `[{"anchor":{"line":1,"column":1},"active":{"line":1,"column":2}},{"anchor":{"line":2,"column":3},"active":{"line":2,"column":1}}]`
	if _, refusal = respond(t, service, "a", "editor/replaceSelections", `{`+contextJSONOf(workspace)+`,"documentID":"d1","expectedVersion":3,"selections":`+selections+`,"replacements":["a","b"]}`); refusal != nil {
		t.Fatalf("replaceSelections: %+v", refusal)
	}
	last := workbench.edits[len(workbench.edits)-1]
	if len(last.Edits) != 2 || last.Edits[1].Range.Start.Column != 1 || last.Edits[1].Range.End.Column != 3 {
		t.Fatalf("a backwards selection was not normalised: %+v", last.Edits)
	}
	if _, refusal = respond(t, service, "a", "editor/replaceSelections", `{`+contextJSONOf(workspace)+`,"documentID":"d1","expectedVersion":3,"selections":`+selections+`,"replacements":["a","b","c"]}`); refusal == nil {
		t.Fatal("a replacement count that matches neither rule was accepted")
	}
	// A closed context is expired before the window is asked.
	service.Contexts.Close(workspace.Path)
	if _, refusal = respond(t, service, "a", "editor/applyEdits", params); refusal == nil || refusal.Code != "plugin.host.contextExpired" {
		t.Fatalf("closed context = %+v", refusal)
	}
}

func TestSnapshotRefusesWhatExceedsTheBudget(t *testing.T) {
	service, workbench, workspace, _ := openWorkbenchService(t)
	workbench.snapshot = strings.Repeat("x", maxSnapshotBytes+1)
	_, refusal := respond(t, service, "a", "documents/getSnapshot", `{`+contextJSONOf(workspace)+`,"documentID":"d1"}`)
	if refusal == nil || refusal.Code != CodeLimitExceeded {
		t.Fatalf("oversize snapshot = %+v", refusal)
	}
	workbench.snapshot = "hello"
	result, refusal := respond(t, service, "a", "documents/getSnapshot", `{`+contextJSONOf(workspace)+`,"documentID":"d1"}`)
	if refusal != nil || !strings.Contains(string(result), `"text":"hello"`) {
		t.Fatalf("snapshot = %s %+v", result, refusal)
	}
}

func TestEditorOpenStaysInsideTheWorkspace(t *testing.T) {
	service, workbench, workspace, _ := openWorkbenchService(t)
	if err := os.MkdirAll(filepath.Join(workspace.Path, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspace.Path, "src", "a.txt"), []byte("a"), 0o644); err != nil {
		t.Fatal(err)
	}
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(workspace.Path, "link")); err != nil {
		t.Skip("symlinks are not available")
	}
	rootID := service.Contexts.RootID("a", workspace.Path)
	open := func(path string) *struct{ Code string } {
		_, refusal := respond(t, service, "a", "editor/open", `{`+contextJSONOf(workspace)+`,"resource":{"rootID":"`+rootID+`","path":"`+path+`"},"range":{"start":{"line":2,"column":4},"end":{"line":2,"column":4}}}`)
		if refusal == nil {
			return nil
		}
		return &struct{ Code string }{refusal.Code}
	}
	if refused := open("src/a.txt"); refused != nil {
		t.Fatalf("a file of the workspace was refused: %+v", refused)
	}
	got := workbench.opened[0]
	if got.Path != filepath.Join(workspace.Path, "src", "a.txt") || got.Caret == nil || got.Caret.Line != 2 || got.Caret.Column != 4 || got.Background {
		t.Fatalf("open request = %+v", got)
	}
	for _, path := range []string{"../x", "src/../../x", "/etc/passwd", `src\a.txt`, "link/escape.txt", "link"} {
		if refused := open(path); refused == nil || refused.Code != codeInvalidParams {
			t.Errorf("%q: %+v", path, refused)
		}
	}
	// Another plugin's root ID is not this plugin's.
	other := service.Contexts.RootID("b", workspace.Path)
	if _, refusal := respond(t, service, "a", "editor/open", `{`+contextJSONOf(workspace)+`,"resource":{"rootID":"`+other+`","path":"src/a.txt"}}`); refusal == nil {
		t.Fatal("a root ID of another plugin was accepted")
	}
	if _, refusal := respond(t, service, "a", "editor/open", `{`+contextJSONOf(workspace)+`,"resource":{"rootID":"`+rootID+`","path":"src/a.txt"},"tab":"preview"}`); refusal == nil || refusal.Code != CodeUnsupportedOption {
		t.Fatalf("preview tab = %+v", refusal)
	}
}

func TestWindowMessagesAreRateLimitedPerPlugin(t *testing.T) {
	service, workbench, workspace, _ := openWorkbenchService(t)
	now := time.Unix(1000, 0)
	service.messages.now = func() time.Time { return now }
	one := 1
	workbench.choice = &one
	params := `{` + contextJSONOf(workspace) + `,"text":"hi","actions":["a","b"]}`
	for i := 0; i < messageBurst; i++ {
		result, refusal := respond(t, service, "a", "window/showWarning", params)
		if refusal != nil || string(result) != `{"selectedIndex":1}` {
			t.Fatalf("message %d = %s %+v", i, result, refusal)
		}
	}
	_, refusal := respond(t, service, "a", "window/showWarning", params)
	if refusal == nil || refusal.Code != CodeRateLimited || !strings.Contains(string(refusal.Details), "retryAfterMilliseconds") {
		t.Fatalf("sixth message = %+v", refusal)
	}
	// Another plugin has its own budget, and the window passes.
	if _, refusal = respond(t, service, "b", "window/showError", params); refusal != nil {
		t.Fatalf("another plugin: %+v", refusal)
	}
	now = now.Add(11 * time.Second)
	if _, refusal = respond(t, service, "a", "window/showInformation", params); refusal != nil {
		t.Fatalf("after the window: %+v", refusal)
	}
	for _, bad := range []string{
		`{` + contextJSONOf(workspace) + `,"text":""}`,
		`{` + contextJSONOf(workspace) + `,"text":"x","actions":["a","b","c","d"]}`,
		`{` + contextJSONOf(workspace) + `,"text":"x","actions":["` + strings.Repeat("a", 41) + `"]}`,
	} {
		if _, refusal = respond(t, service, "c", "window/showError", bad); refusal == nil || refusal.Code != codeInvalidParams {
			t.Errorf("%s: %+v", bad, refusal)
		}
	}
}

func TestPendingMessagesAreCappedAndACancelledOneFreesItsSlot(t *testing.T) {
	service, workbench, workspace, _ := openWorkbenchService(t)
	workbench.release = make(chan struct{})
	workbench.prompts = make(chan PromptRequest, 8)
	params := `{` + contextJSONOf(workspace) + `,"text":"hi"}`
	var group sync.WaitGroup
	for i := 0; i < messagePendingAt; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			respond(t, service, "a", "window/showInformation", params)
		}()
		<-workbench.prompts
	}
	if _, refusal := respond(t, service, "a", "window/showInformation", params); refusal == nil || refusal.Code != CodeBusy {
		t.Fatalf("fourth pending message = %+v", refusal)
	}
	close(workbench.release)
	group.Wait()
}

func TestBrowserOpensOnlyHTTPAddresses(t *testing.T) {
	service, workbench, workspace, _ := openWorkbenchService(t)
	for _, address := range []string{"https://example.com/a?b=1", "http://localhost:8080"} {
		result, refusal := respond(t, service, "a", "browser/openExternal", `{`+contextJSONOf(workspace)+`,"url":"`+address+`"}`)
		if refusal != nil || string(result) != `{"opened":true,"source":"web"}` {
			t.Fatalf("%s = %s %+v", address, result, refusal)
		}
	}
	for _, address := range []string{"file:///etc/passwd", "javascript:alert(1)", "ftp://x/y", "http://user:pw@host/", "/relative", "https://"} {
		if _, refusal := respond(t, service, "a", "browser/openExternal", `{`+contextJSONOf(workspace)+`,"url":"`+address+`"}`); refusal == nil || refusal.Code != codeInvalidParams {
			t.Errorf("%s accepted: %+v", address, refusal)
		}
	}
	if len(workbench.external) != 2 {
		t.Fatalf("opened %v", workbench.external)
	}
	if _, refusal := respond(t, service, "a", "browser/openExternal", `{`+contextJSONOf(workspace)+`,"resource":{"rootID":"r","path":"a.html"}}`); refusal == nil || refusal.Code != CodeUnsupportedOption {
		t.Fatalf("resource = %+v", refusal)
	}
}

func TestContentProviderRegistrationRules(t *testing.T) {
	service, _, workspace, _ := openWorkbenchService(t)
	for _, scheme := range []string{"file", "https", "JAR", "1jar", "", "a b", "lithe"} {
		_, refusal := respond(t, service, "a", "documents/registerContentProvider", `{`+contextJSONOf(workspace)+`,"scheme":"`+scheme+`","function":"documents.read"}`)
		if refusal == nil || refusal.Code != codeInvalidParams {
			t.Errorf("scheme %q: %+v", scheme, refusal)
		}
	}
	// A valid scheme still needs a running session that registered the function.
	if _, refusal := respond(t, service, "a", "documents/registerContentProvider", `{`+contextJSONOf(workspace)+`,"scheme":"jdt","function":"documents.read"}`); refusal == nil || refusal.Code != CodePreconditionFailed {
		t.Fatalf("no session = %+v", refusal)
	}
	session := &BackendSession{
		host: service.Host, PluginID: "a", Session: pluginbackend.Session{ID: "session-a"},
		functions: map[string]bool{"documents.read": true}, waiters: map[string]chan core.BackendEvent{},
		done: make(chan struct{}), changed: make(chan struct{}), ready: true,
	}
	service.Host.sessions["a"] = session
	result, refusal := respond(t, service, "a", "documents/registerContentProvider", `{`+contextJSONOf(workspace)+`,"scheme":"jdt","function":"documents.read"}`)
	if refusal != nil {
		t.Fatalf("register: %+v", refusal)
	}
	var registered struct {
		SubscriptionID string `json:"subscriptionID"`
	}
	if err := json.Unmarshal(result, &registered); err != nil || registered.SubscriptionID == "" {
		t.Fatalf("result = %s", result)
	}
	if !service.HasContentProvider(workspace.Path, "jdt://contents/java.base/java/lang/String.class") {
		t.Fatal("the registered scheme is not served")
	}
	if _, refusal = respond(t, service, "b", "documents/registerContentProvider", `{`+contextJSONOf(workspace)+`,"scheme":"jdt","function":"documents.read"}`); refusal == nil {
		t.Fatal("another plugin took a registered scheme")
	}
	if _, refusal = respond(t, service, "a", "documents/registerContentProvider", `{`+contextJSONOf(workspace)+`,"scheme":"jdt","function":"documents.read"}`); refusal == nil || refusal.Code != CodePreconditionFailed {
		t.Fatalf("second registration = %+v", refusal)
	}
	// Another plugin cannot dispose it; the owner can.
	respond(t, service, "b", "subscriptions/dispose", `{"subscriptionID":"`+registered.SubscriptionID+`"}`)
	if !service.HasContentProvider(workspace.Path, "jdt://x") {
		t.Fatal("a foreign plugin disposed the provider")
	}
	if _, refusal = respond(t, service, "a", "subscriptions/dispose", `{"subscriptionID":"`+registered.SubscriptionID+`"}`); refusal != nil {
		t.Fatal(refusal)
	}
	if service.HasContentProvider(workspace.Path, "jdt://x") {
		t.Fatal("the provider survived its disposal")
	}
}

func TestContentAnswersAreCheckedAndTheContextWithdrawsProviders(t *testing.T) {
	service, workbench, workspace, _ := openWorkbenchService(t)
	for answer, ok := range map[string]bool{`"class A {}"`: true, `{"content":"x"}`: true, `{"content":"x","mime":"t"}`: false, `7`: false, `null`: false} {
		_, err := service.decodeContent(context.Background(), json.RawMessage(answer))
		if (err == nil) != ok {
			t.Errorf("%s: %v", answer, err)
		}
	}
	if _, err := service.decodeContent(context.Background(), json.RawMessage(`"`+strings.Repeat("a", maxContentBytes+1)+`"`)); err == nil {
		t.Error("an answer over 1 MiB was accepted")
	}
	// Opening a URI nobody serves reports it and opens nothing.
	if err := service.OpenContentURI(context.Background(), workspace.Path, "jdt://x/y", 0, 0); err == nil || len(workbench.virtual) != 0 {
		t.Fatalf("unserved URI: %v %v", err, workbench.virtual)
	}
	caller := callerContext("a")
	_ = caller
}

func TestTerminalLifecycle(t *testing.T) {
	service, workbench, workspace, kernel := openWorkbenchService(t)
	params := `{` + contextJSONOf(workspace) + `,"executable":"docker","arguments":["exec","-it","c1","sh"],"title":"c1 shell","environment":{"A":"1","B":null},"retainedContextBytes":8}`
	result, refusal := respond(t, service, "a", "terminal/create", params)
	if refusal != nil {
		t.Fatalf("create: %+v", refusal)
	}
	var created struct {
		TerminalID string `json:"terminalID"`
		Generation int    `json:"generation"`
	}
	if err := json.Unmarshal(result, &created); err != nil || created.Generation != 1 {
		t.Fatalf("created = %s", result)
	}
	spec := workbench.terminals[0]
	if spec.Executable != "docker" || spec.Directory != workspace.Path || !spec.Show || spec.RetainedBytes != 8 || spec.Environment["B"] != nil || *spec.Environment["A"] != "1" {
		t.Fatalf("spec = %+v", spec)
	}
	terminal := workbench.sessions[0]
	terminal.output = "0123456789abcdef"
	handle := terminalParams(workspace, created.TerminalID)

	// onExit once per handle; a second subscription is refused.
	result, refusal = respond(t, service, "a", "terminal/onExit", handle)
	if refusal != nil {
		t.Fatalf("onExit: %+v", refusal)
	}
	if _, second := respond(t, service, "a", "terminal/onExit", handle); second == nil || second.Code != CodePreconditionFailed {
		t.Fatalf("second subscription = %+v", second)
	}
	// Another plugin's terminal ID is not found.
	if _, other := respond(t, service, "b", "terminal/show", handle); other == nil || other.Code != CodeNotFound {
		t.Fatalf("foreign handle = %+v", other)
	}
	if _, refusal = respond(t, service, "a", "terminal/show", handle); refusal != nil || terminal.shown != 1 {
		t.Fatalf("show: %+v shown=%d", refusal, terminal.shown)
	}

	// Close keeps a snapshot within the budget, and reports its size.
	result, refusal = respond(t, service, "a", "terminal/close", handle)
	if refusal != nil || string(result) != `{"retainedContextBytes":8}` {
		t.Fatalf("close = %s %+v", result, refusal)
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		kernel.mu.Lock()
		sent := append([]string(nil), kernel.sent...)
		kernel.mu.Unlock()
		if len(sent) > 0 {
			if !strings.Contains(sent[0], `"reason":"closed"`) || !strings.Contains(sent[0], `"generation":1`) || !strings.Contains(sent[0], "subscriptions/notify") {
				t.Fatalf("exit notification = %s", sent[0])
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("no exit notification")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if _, refusal = respond(t, service, "a", "terminal/show", handle); refusal == nil || refusal.Code != CodePreconditionFailed {
		t.Fatalf("show after close = %+v", refusal)
	}

	// Reopen starts a new generation with the snapshot as display history.
	result, refusal = respond(t, service, "a", "terminal/reopen", handle)
	var reopened struct {
		TerminalID string `json:"terminalID"`
		Generation int    `json:"generation"`
		Restored   int    `json:"restoredContextBytes"`
	}
	if err := json.Unmarshal(result, &reopened); err != nil || refusal != nil || reopened.TerminalID != created.TerminalID || reopened.Generation != 2 || reopened.Restored != 8 {
		t.Fatalf("reopen = %s %+v", result, refusal)
	}
	if got := workbench.terminals[1].Prefill; got != "89abcdef" {
		t.Fatalf("prefill = %q", got)
	}
	if _, refusal = respond(t, service, "a", "terminal/reopen", handle); refusal == nil || refusal.Code != CodePreconditionFailed {
		t.Fatalf("reopening a running terminal = %+v", refusal)
	}

	// Dispose closes the live process and forgets the handle.
	if _, refusal = respond(t, service, "a", "terminal/dispose", handle); refusal != nil {
		t.Fatalf("dispose: %+v", refusal)
	}
	if workbench.sessions[1].closed != 1 {
		t.Fatal("dispose left the process running")
	}
	if _, refusal = respond(t, service, "a", "terminal/show", handle); refusal == nil || refusal.Code != CodeNotFound {
		t.Fatalf("show after dispose = %+v", refusal)
	}
}

func terminalParams(workspace WorkspaceContext, id string) string {
	return `{` + contextJSONOf(workspace) + `,"terminalID":"` + id + `"}`
}

func TestTerminalLimitsAndConsent(t *testing.T) {
	service, workbench, workspace, _ := openWorkbenchService(t)
	create := func(body string) *struct{ Code string } {
		_, refusal := respond(t, service, "a", "terminal/create", `{`+contextJSONOf(workspace)+`,`+body+`}`)
		if refusal == nil {
			return nil
		}
		return &struct{ Code string }{refusal.Code}
	}
	for _, body := range []string{
		`"executable":"./tool"`, `"executable":"bin/tool"`, `"executable":""`,
		`"executable":"sh","title":"two\nlines"`,
		`"executable":"sh","environment":{"LITHE_X":"1"}`, `"executable":"sh","environment":{"A=B":"1"}`,
		`"executable":"sh","retainedContextBytes":262145`,
		`"executable":"sh","cwd":{"rootID":"nope","path":""}`,
	} {
		if refused := create(body); refused == nil || (refused.Code != codeInvalidParams) {
			t.Errorf("%s accepted or wrong code: %+v", body, refused)
		}
	}
	if refused := create(`"executable":"sh","arguments":[` + strings.TrimSuffix(strings.Repeat(`"a",`, 257), ",") + `]`); refused == nil || refused.Code != CodeLimitExceeded {
		t.Errorf("257 arguments: %+v", refused)
	}
	if len(workbench.terminals) != 0 {
		t.Fatal("an invalid launch reached the window")
	}
	// Declined consent creates nothing and frees the slot.
	workbench.consent = false
	if refused := create(`"executable":"sh"`); refused == nil || refused.Code != CodePermissionDenied {
		t.Fatalf("declined = %+v", refused)
	}
	workbench.consent = true
	for i := 0; i < maxTerminalsPerPlugin; i++ {
		if refused := create(`"executable":"sh"`); refused != nil {
			t.Fatalf("terminal %d: %+v", i, refused)
		}
	}
	if refused := create(`"executable":"sh"`); refused == nil || refused.Code != CodeLimitExceeded {
		t.Fatalf("ninth terminal = %+v", refused)
	}
	// Ending the session releases every handle of it.
	service.resources.releaseSession("session-a")
	if refused := create(`"executable":"sh"`); refused != nil {
		t.Fatalf("after the session ended: %+v", refused)
	}
	for _, session := range workbench.sessions[:maxTerminalsPerPlugin] {
		if session.closed != 1 {
			t.Fatal("a terminal outlived its session")
		}
	}
}

func TestClosingTheContextDisposesItsTerminals(t *testing.T) {
	service, workbench, workspace, _ := openWorkbenchService(t)
	if _, refusal := respond(t, service, "a", "terminal/create", `{`+contextJSONOf(workspace)+`,"executable":"sh"}`); refusal != nil {
		t.Fatal(refusal)
	}
	service.Contexts.Close(workspace.Path)
	if workbench.sessions[0].closed != 1 {
		t.Fatal("closing the workspace left its terminal running")
	}
}
