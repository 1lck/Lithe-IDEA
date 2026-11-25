package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
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

const navFixturePluginID = "dev.lithe.test.nav"

type navActionKernel struct {
	*semanticTestKernel
	initialize     sync.Once
	ready          chan struct{}
	readyOnce      sync.Once
	replies        chan core.BackendEvent
	languageEvents chan core.BackendEvent
	collected      json.RawMessage
	invokeFn       func(params json.RawMessage) json.RawMessage
}

func (k *navActionKernel) StartPluginBackend(context.Context, core.PluginBackendStart) (core.PluginBackendStarted, error) {
	return core.PluginBackendStarted{SessionID: "nav-fixture"}, nil
}

func (k *navActionKernel) WaitBackendEvents(ctx context.Context, session string, _ int) ([]core.BackendEvent, error) {
	if session == "fake" {
		select {
		case event := <-k.languageEvents:
			return []core.BackendEvent{event}, nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	var initial []core.BackendEvent
	k.initialize.Do(func() {
		initial = []core.BackendEvent{
			{Type: "stateChanged", State: "ready"},
			{Type: "functionsChanged", Result: json.RawMessage(`{"functions":["nav.collect","nav.invoke"]}`)},
		}
	})
	if initial != nil {
		return initial, nil
	}
	k.readyOnce.Do(func() { close(k.ready) })
	select {
	case reply := <-k.replies:
		return []core.BackendEvent{reply}, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (k *navActionKernel) InvokePluginFunctionInContext(ctx context.Context, _, operation, _, function string, argument, _ json.RawMessage, _ int) (string, error) {
	var result json.RawMessage
	switch function {
	case "nav.collect":
		result = k.collected
	case "nav.invoke":
		if k.invokeFn != nil {
			result = k.invokeFn(argument)
		} else {
			result = json.RawMessage(`{}`)
		}
	default:
		result = json.RawMessage(`{}`)
	}
	envelope, _ := json.Marshal(struct {
		Value json.RawMessage `json:"value"`
	}{Value: result})
	select {
	case k.replies <- core.BackendEvent{Type: "requestCompleted", OperationID: operation, Result: envelope}:
		return operation, nil
	case <-ctx.Done():
		return "", ctx.Err()
	}
}

func (*navActionKernel) StopPluginBackend(context.Context, string) error    { return nil }
func (*navActionKernel) DestroyPluginBackend(context.Context, string) error { return nil }
func (*navActionKernel) CancelPluginOperation(context.Context, string, string) error {
	return nil
}

func themedTestStore(t testing.TB, theme string) *store.Store {
	t.Helper()
	dir := t.TempDir()
	// An explicit theme keeps New from asking the system for its appearance,
	// which blocks when no application is running.
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"`+theme+`"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	return store.At(dir)
}

func openNavActionHarness(t *testing.T, collected json.RawMessage, invokeFn func(json.RawMessage) json.RawMessage) (*harness, *navActionKernel) {
	t.Helper()
	pluginRoot := t.TempDir()
	kernel := &navActionKernel{
		semanticTestKernel: &semanticTestKernel{testKernel: &testKernel{Client: core.NewClient()}},
		ready:              make(chan struct{}),
		replies:            make(chan core.BackendEvent, 16),
		languageEvents:     make(chan core.BackendEvent, 4),
		collected:          collected,
		invokeFn:           invokeFn,
	}
	dir := filepath.Join(pluginRoot, navFixturePluginID, "1.0.0")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	manifest := `{
		"schemaVersion":0,"id":"dev.lithe.test.nav","displayName":"Nav fixture",
		"version":"1.0.0","pluginAPIVersion":0,"requires":{"backend":0},
		"vendor":{"id":"dev.lithe.test","displayName":"Test","signatureRequirement":"publisherPackage"},
		"permissions":["backend.launch","editor.actions","documents.read"],
		"activationEvents":["onWorkspaceOpen"],
		"backend":{"launch":{"kind":"packaged","path":"fixture.exe"}}
	}`
	if err := os.WriteFile(filepath.Join(dir, "plugin.json"), []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	copyTestBinary(t, filepath.Join(dir, "fixture.exe"))
	h := newHarnessWithOptions(t, Options{
		Kernel:       kernel,
		PluginKernel: kernel,
		PluginRoot:   pluginRoot,
		Store:        themedTestStore(t, "light"),
		Languages:    []string{"en-US"},
	})
	return h, kernel
}

func navActionFixtureURI(t *testing.T, path string) string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	uri, err := core.NewClient().PluginDocumentURI(ctx, path, "auto")
	if err != nil {
		t.Fatalf("encode navigation fixture path %q: %v", path, err)
	}
	return uri
}

func installCollectedNavActions(t *testing.T, h *harness, kernel *navActionKernel, p *project, d *document) {
	t.Helper()
	if err := h.app.plugins.Manager.SetEnabled(navFixturePluginID, true); err != nil {
		t.Fatal(err)
	}
	workspace := h.app.plugins.Contexts.Open(p.root)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	backend, err := h.app.plugins.Host.EnsureBackend(ctx, navFixturePluginID)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-kernel.ready:
	case <-ctx.Done():
		t.Fatal("nav fixture backend did not become ready")
	}
	caller := pluginhost.WithCaller(ctx, pluginhost.Caller{PluginID: navFixturePluginID, SessionID: backend.Session.ID})
	registration, err := json.Marshal(struct {
		Context  pluginservice.ContextRef `json:"context"`
		ID       string                   `json:"id"`
		Function string                   `json:"function"`
		Selector json.RawMessage          `json:"selector"`
	}{workspace.ContextRef, "nav-fixture", "nav.collect", json.RawMessage(`{"fileExtensions":["java"]}`)})
	if err != nil {
		t.Fatal(err)
	}
	if _, failure := h.app.plugins.HostServices.Respond(caller, pluginhost.MethodPrefix+"editor/registerActions", registration); failure != nil {
		t.Fatalf("registerActions failed: %+v", failure)
	}
	text, _ := d.view.Text()
	actions, err := h.app.plugins.CollectEditorActions(ctx, p.root, d.path, strconv.Itoa(d.id), d.view.Revision(), string(text))
	if err != nil {
		t.Fatalf("CollectEditorActions: %v", err)
	}
	h.app.post(func(a *App) {
		a.clearEditorActions(d)
		snapshot := editorActionSnapshot{documentID: d.id, version: d.view.Revision(), collection: d.actionCollection}
		a.presentEditorActions(p, snapshot, actions, nil, nil)
		if d.actionTimer != nil {
			d.actionTimer.Stop()
			d.actionTimer = nil
		}
	})
	t.Cleanup(func() {
		for _, doc := range p.docs.list {
			if doc.actionTimer != nil {
				doc.actionTimer.Stop()
			}
		}
	})
	h.settle()
}

func findGutterIconCell(t *testing.T, d *document, lineIndex, wantSlot int) gfx.Rect {
	t.Helper()
	d.view.GoToNavigation(lineIndex, 0, false)
	caret, ok := d.view.CaretRect()
	if !ok {
		t.Fatalf("caret rect unavailable for line %d", lineIndex)
	}
	y := caret.Y + caret.Height/2
	for x := d.lastArea.X; x < caret.X; x += 2 {
		line, slot, cell, hit := d.view.LineIconAt(x, y)
		if hit && line == lineIndex && slot == wantSlot {
			return cell
		}
	}
	t.Fatalf("line %d slot %d gutter icon not found in [X=%.1f..%.1f, Y=%.1f]", lineIndex, wantSlot, d.lastArea.X, caret.X, y)
	return gfx.Rect{}
}

func TestEditorNavigationIconsAndDualSlotsAndThemeRefresh(t *testing.T) {
	cases := []struct {
		token string
		lane  string
	}{
		{"navigate-implemented", "navigate-down"},
		{"navigate-implementing", "navigate-up"},
		{"navigate-overridden", "navigate-down"},
		{"navigate-overriding", "navigate-up"},
		{"navigate-implementations", "navigate-down"},
		{"navigate-super", "navigate-up"},
	}
	for _, tc := range cases {
		lightLane, lightIcon, ok := editorActionPresentation(tc.token, false)
		darkLane, darkIcon, darkOK := editorActionPresentation(tc.token, true)
		if !ok || !darkOK || lightLane != tc.lane || darkLane != tc.lane {
			t.Fatalf("%s presentation = (%q,%v) / (%q,%v), want lane %q", tc.token, lightLane, ok, darkLane, darkOK, tc.lane)
		}
		if lightIcon.Layers[0].Fill == darkIcon.Layers[0].Fill {
			t.Fatalf("%s light and dark badge fills match unexpectedly: %+v", tc.token, lightIcon.Layers[0].Fill)
		}
	}

	h := newHarnessWithOptions(t, Options{
		Kernel:       &testKernel{Client: core.NewClient()},
		PluginKernel: &testKernel{Client: core.NewClient()},
		PluginRoot:   t.TempDir(),
		Store:        themedTestStore(t, "light"),
		Languages:    []string{"en-US"},
	})
	root := t.TempDir()
	writeFixture(t, root, map[string]string{"Base.java": "class Base {\n  void run() {}\n  public static void main(String[] a) {}\n}\n"})
	h.open(root)
	p := h.app.project
	h.app.openFile(p, filepath.Join(root, "Base.java"))
	h.settle()
	d := documentNamed(p, "Base.java")

	h.app.post(func(a *App) {
		a.clearEditorActions(d)
		snapshot := editorActionSnapshot{documentID: d.id, version: d.view.Revision(), collection: d.actionCollection}
		actions := []pluginservice.EditorAction{
			{ID: "up", Title: "Overrides super", Icon: "navigate-overriding", Range: pluginservice.EditorActionRange{StartLine: 1, StartColumn: 1, EndLine: 1, EndColumn: 6}},
			{ID: "down", Title: "Overridden by Sub", Icon: "navigate-overridden", Range: pluginservice.EditorActionRange{StartLine: 1, StartColumn: 1, EndLine: 1, EndColumn: 6}},
			{ID: "run", Title: "Run main", Icon: "run", Range: pluginservice.EditorActionRange{StartLine: 3, StartColumn: 1, EndLine: 3, EndColumn: 6}},
		}
		a.presentEditorActions(p, snapshot, actions, nil, nil)
	})
	h.settle()

	if got, want := strings.Join(d.actionPanel.lanes, ","), "navigate-up,navigate-down,run"; got != want {
		t.Fatalf("lanes = %q, want %q", got, want)
	}
	cell0 := findGutterIconCell(t, d, 0, 0)
	cell1 := findGutterIconCell(t, d, 0, 1)
	if cell1.X <= cell0.X {
		t.Fatalf("expected side-by-side nav slots on line 0: slot0=%+v slot1=%+v", cell0, cell1)
	}

	h.app.post(func(a *App) {
		a.settings.Theme = themeDark
		a.applyLook(themeDark)
	})
	h.settle()
	if !h.app.colors.Dark || len(d.actionPanel.lanes) != 3 {
		t.Fatalf("dark refresh failed: dark=%v lanes=%v", h.app.colors.Dark, d.actionPanel.lanes)
	}
	h.app.post(func(a *App) {
		a.settings.Theme = themeLight
		a.applyLook(themeLight)
	})
	h.settle()
	if h.app.colors.Dark || len(d.actionPanel.lanes) != 3 {
		t.Fatalf("light refresh failed: dark=%v lanes=%v", h.app.colors.Dark, d.actionPanel.lanes)
	}
}

func TestEditorActionGutterHoverTooltipLifecycle(t *testing.T) {
	h := newHarnessWithOptions(t, Options{
		Kernel:       &testKernel{Client: core.NewClient()},
		PluginKernel: &testKernel{Client: core.NewClient()},
		PluginRoot:   t.TempDir(),
		Store:        themedTestStore(t, "light"),
		Languages:    []string{"en-US"},
	})
	root := t.TempDir()
	writeFixture(t, root, map[string]string{
		"Service.java": "interface Service {\n  void run();\n}\n",
		"Other.java":   "class Other {}\n",
	})
	h.open(root)
	p := h.app.project
	h.app.openFile(p, filepath.Join(root, "Service.java"))
	h.settle()
	d := documentNamed(p, "Service.java")

	h.app.post(func(a *App) {
		a.clearEditorActions(d)
		snapshot := editorActionSnapshot{documentID: d.id, version: d.view.Revision(), collection: d.actionCollection}
		actions := []pluginservice.EditorAction{{
			ID:    "svc-down",
			Title: "Implemented by ImplA",
			Icon:  "navigate-implemented",
			Range: pluginservice.EditorActionRange{StartLine: 1, StartColumn: 1, EndLine: 1, EndColumn: 10},
			Alternatives: []pluginservice.EditorActionChoice{
				{ID: "alt1", Title: "Implemented by ImplB", Icon: "navigate-implemented"},
				{ID: "dup", Title: "Implemented by ImplA", Icon: "navigate-implemented"},
			},
		}}
		a.presentEditorActions(p, snapshot, actions, nil, nil)
	})
	h.settle()

	cell := findGutterIconCell(t, d, 0, 0)
	hover := func() {
		if err := h.driver.Move(cell.X+cell.Width/2, cell.Y+cell.Height/2); err != nil {
			t.Fatal(err)
		}
		h.settle()
	}

	hover()
	if !d.actionPanel.hoverOpen || d.actionPanel.hoverText != "Implemented by ImplA\nImplemented by ImplB" {
		t.Fatalf("hover state = %+v", d.actionPanel)
	}
	if !h.shows("Implemented by ImplA") || !h.shows("Implemented by ImplB") {
		t.Fatalf("tooltip lines not rendered: %v", h.driver.Snapshot().Labels)
	}

	// Moving away clears tooltip.
	caret, _ := d.view.CaretRect()
	if err := h.driver.Move(caret.X+10, caret.Y+caret.Height/2); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if d.actionPanel.hoverOpen || h.shows("Implemented by ImplA") {
		t.Fatal("moving off gutter icon left tooltip open")
	}

	// Leave clears tooltip.
	hover()
	if err := h.driver.Leave(); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if d.actionPanel.hoverOpen {
		t.Fatal("PointerExit left tooltip open")
	}

	// Scroll clears tooltip.
	hover()
	h.app.post(func(a *App) { a.pluginSemanticsScrolled(d) })
	h.settle()
	if d.actionPanel.hoverOpen {
		t.Fatal("scroll left tooltip open")
	}

	// Selecting another document clears tooltip.
	h.app.post(func(a *App) { a.openFile(p, filepath.Join(root, "Other.java")) })
	awaitDocumentState(t, h, func() bool { return documentNamed(p, "Other.java") != nil })
	other := documentNamed(p, "Other.java")
	h.app.post(func(a *App) { a.selectDocument(p, d.id) })
	h.settleChain()
	hover()
	if !d.actionPanel.hoverOpen {
		t.Fatal("expected hover tooltip to reopen before switching tab")
	}
	h.app.post(func(a *App) { a.selectDocument(p, other.id) })
	h.settle()
	if d.actionPanel.hoverOpen {
		t.Fatal("switching document left previous tooltip open")
	}
}

func TestEditorNavigationGutterClickAnchorsPopupAndSuppressesStartingToast(t *testing.T) {
	collected := json.RawMessage(`{
		"actions": [
			{
				"id": "impl-up",
				"range": {"start": {"line": 1, "column": 1}, "end": {"line": 1, "column": 10}},
				"title": "Implements Service",
				"icon": "navigate-implementing",
				"invoke": {"functionID": "nav.invoke", "params": {"kind": "single"}}
			},
			{
				"id": "svc-down",
				"range": {"start": {"line": 1, "column": 1}, "end": {"line": 1, "column": 10}},
				"title": "Implemented by classes",
				"icon": "navigate-implemented",
				"invoke": {"functionID": "nav.invoke", "params": {"kind": "multi-down"}}
			},
			{
				"id": "base-up",
				"range": {"start": {"line": 2, "column": 1}, "end": {"line": 2, "column": 8}},
				"title": "Overrides Base",
				"icon": "navigate-overriding",
				"invoke": {"functionID": "nav.invoke", "params": {"kind": "multi-up"}}
			}
		]
	}`)

	root := t.TempDir()
	implA := filepath.Join(root, "ImplA.java")
	implB := filepath.Join(root, "ImplB.java")
	implAURI := navActionFixtureURI(t, implA)
	implBURI := navActionFixtureURI(t, implB)
	servicePath := filepath.Join(root, "Service.java")
	writeFixture(t, root, map[string]string{
		"Service.java": "class ServiceImpl implements Service {\n  public void run() {}\n  public void third() {}\n}\n",
		"ImplA.java":   "class ImplA {\n}\n",
		"ImplB.java":   "class ImplB {\n}\n",
	})

	var invokedMu sync.Mutex
	var invoked []string
	h, kernel := openNavActionHarness(t, collected, func(arg json.RawMessage) json.RawMessage {
		var req struct {
			Data struct {
				Kind string `json:"kind"`
			} `json:"data"`
		}
		_ = json.Unmarshal(arg, &req)
		invokedMu.Lock()
		invoked = append(invoked, req.Data.Kind)
		invokedMu.Unlock()
		loc := func(uri string, line int) map[string]any {
			return map[string]any{
				"uri": uri,
				"range": map[string]any{
					"start": map[string]int{"line": line, "character": 0},
					"end":   map[string]int{"line": line, "character": 5},
				},
			}
		}
		switch req.Data.Kind {
		case "single":
			data, _ := json.Marshal(map[string]any{"reveal": map[string]any{"locations": []any{loc(implAURI, 0)}}})
			return data
		default:
			data, _ := json.Marshal(map[string]any{"reveal": map[string]any{"locations": []any{loc(implAURI, 0), loc(implBURI, 0)}}})
			return data
		}
	})
	h.open(root)
	p := h.app.project
	h.app.openFile(p, servicePath)
	h.settle()
	d := documentNamed(p, "Service.java")
	installCollectedNavActions(t, h, kernel, p, d)

	logger := &treeRecordingLog{}
	h.app.logSink = logger

	// Single-target click opens directly without "Starting ..." toast.
	cellUp := findGutterIconCell(t, d, 0, 0)
	h.click(gfx.Point{X: cellUp.X + cellUp.Width/2, Y: cellUp.Y + cellUp.Height/2})
	h.await("single-target gutter navigation to open ImplA.java", func() bool { return p.docs.byPath(implA) != nil })
	for _, entry := range h.app.notifications.list {
		if strings.Contains(entry.text, "Starting") {
			t.Fatalf("unexpected starting toast for navigation action: %q", entry.text)
		}
	}

	// Switch back, move caret to line 2 (away from line 0!), and click line 0 down icon.
	h.app.post(func(a *App) { a.selectDocument(p, d.id) })
	h.settleChain()
	if got := p.selectedDocument(p.docs.group); got != d {
		t.Fatalf("selected doc = %v, want %v", got, d)
	}
	cellDown := findGutterIconCell(t, d, 0, 1)
	d.view.GoToNavigation(2, 0, false)
	h.settle()
	caret2, _ := d.view.CaretRect()
	h.click(gfx.Point{X: cellDown.X + cellDown.Width/2, Y: cellDown.Y + cellDown.Height/2})
	h.await("implementation targets popup to open", func() bool { return h.app.semantics.definition.open })
	invokedMu.Lock()
	gotInvoked := append([]string(nil), invoked...)
	invokedMu.Unlock()
	if len(gotInvoked) < 2 || gotInvoked[0] != "single" || gotInvoked[1] != "multi-down" {
		t.Fatalf("unexpected invoked actions: %v", gotInvoked)
	}
	if h.app.semantics.definition.kind != pluginSemanticImplementation {
		t.Fatalf("popup kind = %q, want %q", h.app.semantics.definition.kind, pluginSemanticImplementation)
	}
	if got, want := h.app.definitionPopupTitle(), h.shared("desktop.semantics.implementations"); got != want {
		t.Fatalf("popup title = %q, want %q", got, want)
	}
	if h.app.semantics.definition.anchor == nil || *h.app.semantics.definition.anchor != cellDown || cellDown.Y >= caret2.Y {
		t.Fatalf("expected popup anchor at clicked gutter cell %+v above caret %+v, got %+v", cellDown, caret2, h.app.semantics.definition.anchor)
	}

	// Verify navigate-up multi-target uses Definitions popup title.
	h.app.closeSemanticDefinition()
	cellBaseUp := findGutterIconCell(t, d, 1, 0)
	h.click(gfx.Point{X: cellBaseUp.X + cellBaseUp.Width/2, Y: cellBaseUp.Y + cellBaseUp.Height/2})
	h.await("definition targets popup to open", func() bool { return h.app.semantics.definition.open })
	if got, want := h.app.definitionPopupTitle(), h.shared("desktop.semantics.definitions"); got != want {
		t.Fatalf("up multi-target popup title = %q, want %q", got, want)
	}
}

func TestFileURILocalPathNormalizesWindowsAndPOSIX(t *testing.T) {
	winDrive, _ := url.Parse("file:///C:/repo/src/Foo.java")
	if got := fileURILocalPath(winDrive, "windows"); got != `C:\repo\src\Foo.java` {
		t.Fatalf("windows drive = %q", got)
	}
	winLocalhost, _ := url.Parse("file://localhost/D:/work/Bar.java")
	if got := fileURILocalPath(winLocalhost, "windows"); got != `D:\work\Bar.java` {
		t.Fatalf("windows localhost drive = %q", got)
	}
	winUNC, _ := url.Parse("file://fileserver/share/Baz.java")
	if got := fileURILocalPath(winUNC, "windows"); got != `\\fileserver\share\Baz.java` {
		t.Fatalf("windows UNC = %q", got)
	}
	posix, _ := url.Parse("file:///Users/dev/Foo.java")
	if got := fileURILocalPath(posix, "darwin"); got != filepath.FromSlash("/Users/dev/Foo.java") {
		t.Fatalf("posix path = %q", got)
	}
}
