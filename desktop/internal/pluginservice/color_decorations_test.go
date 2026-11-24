package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

type colorRefreshWorkbench struct {
	*fakeWorkbench
	roots []string
}

func (w *colorRefreshWorkbench) EditorColorDecorationsChanged(root string) {
	w.roots = append(w.roots, root)
}

type colorProviderKernel struct {
	*realActionDecoder
	service *Service
	answers map[string]json.RawMessage
}

func (k *colorProviderKernel) InvokePluginFunctionInContext(_ context.Context, session, operation, plugin, function string, params, _ json.RawMessage, _ int) (string, error) {
	var argument struct {
		Document struct {
			ID      string `json:"documentID"`
			Version int    `json:"version"`
		} `json:"document"`
	}
	if err := json.Unmarshal(params, &argument); err != nil || argument.Document.ID == "" {
		return "", errors.New("provider did not receive the versioned document envelope")
	}
	backend := k.service.Host.Running(plugin)
	if backend == nil || backend.Session.ID != session {
		return "", ErrBackendUnavailable
	}
	backend.observe(core.BackendEvent{Type: "requestCompleted", OperationID: operation, Result: mustMarshal(map[string]any{"value": k.answers[function]})})
	return operation, nil
}

func colorSession(s *Service, plugin, sessionID string) *BackendSession {
	b := &BackendSession{host: s.Host, PluginID: plugin, Session: pluginbackend.Session{ID: sessionID},
		functions: map[string]bool{"colors.collect": true}, waiters: map[string]chan core.BackendEvent{}, done: make(chan struct{}), changed: make(chan struct{}), ready: true}
	s.Host.mu.Lock()
	s.Host.sessions[plugin] = b
	s.Host.mu.Unlock()
	return b
}

func registerColors(t *testing.T, s *Service, workspace WorkspaceContext, plugin, session string) *pluginhost.Failure {
	t.Helper()
	ctx := pluginhost.WithCaller(t.Context(), pluginhost.Caller{PluginID: plugin, SessionID: session})
	_, failure := s.HostServices.Respond(ctx, methodRegisterEditorProviders, json.RawMessage(`{`+contextJSONOf(workspace)+`,"id":"colors","selector":{"fileExtensions":["txt"]},"providers":{"colorDecorations":{"function":"colors.collect","colorLegend":[{"id":"accent","light":"#112233","dark":"#DDEEFF"}]}}}`))
	return failure
}

func TestColorDecorationProvidersMergeAndWithdrawIndependently(t *testing.T) {
	kernel := &colorProviderKernel{realActionDecoder: &realActionDecoder{notifyKernel: &notifyKernel{}}, answers: map[string]json.RawMessage{
		"colors.collect": json.RawMessage(`{"decorations":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"colorId":"accent"}]}`),
	}}
	window := &colorRefreshWorkbench{fakeWorkbench: &fakeWorkbench{}}
	s, workspace := openEditorServiceWith(t, kernel, window)
	kernel.service = s
	for _, plugin := range []string{"dev.lithe.test.z-color", "dev.lithe.test.a-color"} {
		session := "session-" + plugin
		colorSession(s, plugin, session)
		if failure := registerColors(t, s, workspace, plugin, session); failure != nil {
			t.Fatal(failure)
		}
	}
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	decorations, err := s.PluginColorDecorations(ctx, workspace.Path, "sample.txt", "", "1", 7)
	if err != nil || len(decorations) != 1 || decorations[0].SourceID != "dev.lithe.test.a-color/colors" || decorations[0].Light != "#112233" {
		t.Fatalf("Core priority merge = %+v, %v", decorations, err)
	}
	s.resources.releaseSession("session-dev.lithe.test.a-color")
	decorations, err = s.PluginColorDecorations(ctx, workspace.Path, "sample.txt", "", "1", 7)
	if err != nil || len(decorations) != 1 || decorations[0].SourceID != "dev.lithe.test.z-color/colors" {
		t.Fatalf("withdrawing one provider removed another: %+v, %v", decorations, err)
	}
	s.resources.releaseContext(workspace.ContextID)
	if s.HasColorDecorationsProvider(workspace.Path, "sample.txt", "") || len(window.roots) != 4 {
		t.Fatalf("registration/withdrawal did not refresh open documents: %v", window.roots)
	}
}

func TestColorProviderRestartCanRegisterWithoutRetainingOldSession(t *testing.T) {
	s, workspace := openDecodedEditorService(t, &fakeWorkbench{})
	plugin := "dev.lithe.test.color-restart"
	colorSession(s, plugin, "old")
	if failure := registerColors(t, s, workspace, plugin, "old"); failure != nil {
		t.Fatal(failure)
	}
	colorSession(s, plugin, "new")
	if failure := registerColors(t, s, workspace, plugin, "new"); failure != nil {
		t.Fatal(failure)
	}
	if len(s.providers2.list) != 1 || s.providers2.list[0].sessionID != "new" || resourcesHeldBy(s, "old") != 0 {
		t.Fatalf("restart kept old registration: %+v", s.providers2.list)
	}
	if failure := registerColors(t, s, workspace, plugin, "new"); failure == nil {
		t.Fatal("duplicate active registration accepted")
	}
}

func TestColorProviderFunctionWithdrawalReleasesOnlyItsRegistration(t *testing.T) {
	window := &colorRefreshWorkbench{fakeWorkbench: &fakeWorkbench{}}
	s, workspace := openDecodedEditorService(t, window)
	plugin := "dev.lithe.test.color-withdrawal"
	b := colorSession(s, plugin, "running")
	if failure := registerColors(t, s, workspace, plugin, "running"); failure != nil {
		t.Fatal(failure)
	}
	otherDisposed := false
	s.resources.add(pluginhost.Caller{PluginID: plugin, SessionID: "running"}, workspace.ContextID, func() { otherDisposed = true })
	b.observe(core.BackendEvent{Type: "functionsChanged", Result: json.RawMessage(`{"removed":["unrelated.function"]}`)})
	if !s.HasColorDecorationsProvider(workspace.Path, "sample.txt", "") {
		t.Fatal("an unrelated function withdrawal removed the provider")
	}
	b.observe(core.BackendEvent{Type: "functionsChanged", Result: json.RawMessage(`{"removed":["colors.collect"]}`)})
	if s.HasColorDecorationsProvider(workspace.Path, "sample.txt", "") || len(window.roots) != 2 {
		t.Fatalf("function withdrawal did not release and refresh the provider: %v", window.roots)
	}
	if otherDisposed || resourcesHeldBy(s, "running") != 1 {
		t.Fatal("function withdrawal released an unrelated session resource")
	}
	b.observe(core.BackendEvent{Type: "functionsChanged", Result: json.RawMessage(`{"functions":["colors.collect"]}`)})
	if s.HasColorDecorationsProvider(workspace.Path, "sample.txt", "") {
		t.Fatal("function re-registration resurrected a withdrawn provider")
	}
	if failure := registerColors(t, s, workspace, plugin, "running"); failure != nil {
		t.Fatal(failure)
	}
}

func TestWorkspaceBackendReceivesInitialAndNewestContextRevision(t *testing.T) {
	kernel := &notifyKernel{}
	s, workspace := openEditorServiceWith(t, kernel, &fakeWorkbench{})
	plugin := "dev.lithe.test.context-replay"
	b := colorSession(s, plugin, "initial-session")
	b.Session.Granted = []string{grantWorkspace}
	b.ready = false
	// Opening occurred before the backend was ready: it receives no premature callback.
	s.contextsNotifyMu.Lock()
	if err := s.notifyWorkspaceContextsLocked(t.Context(), "", s.Contexts.Revision()); err != nil {
		t.Fatal(err)
	}
	s.contextsNotifyMu.Unlock()
	if len(kernel.sent) != 0 {
		t.Fatal("uninitialized backend received notification")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- s.activateWorkspaceBackend(ctx, plugin, workspace.ContextRef) }()
	// A second context opens while initialization is pending. Replay reads the latest state.
	s.Contexts.Open(t.TempDir())
	b.observe(core.BackendEvent{Type: "stateChanged", State: "ready"})
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("backend activation did not finish")
	}
	for _, revision := range []uint64{s.Contexts.Revision(), 1} {
		s.contextsNotifyMu.Lock()
		err := s.notifyWorkspaceContextsLocked(ctx, "", revision)
		s.contextsNotifyMu.Unlock()
		if err != nil {
			t.Fatal(err)
		}
	}
	if len(kernel.sent) != 1 || !strings.HasSuffix(kernel.sent[0], `{"revision":2}`) {
		t.Fatalf("startup replay duplicated or used old revision: %v", kernel.sent)
	}
	s.Contexts.Close(workspace.Path)
	s.contextsNotifyMu.Lock()
	err := s.notifyWorkspaceContextsLocked(ctx, "", s.Contexts.Revision())
	s.contextsNotifyMu.Unlock()
	if err != nil || len(kernel.sent) != 2 || !strings.HasSuffix(kernel.sent[1], `{"revision":3}`) {
		t.Fatalf("subsequent change=%v, %v", kernel.sent, err)
	}
}
