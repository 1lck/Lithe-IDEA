package pluginservice

import (
	"context"
	"encoding/json"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

// delayedProviderDecoder pauses one validation after the request has captured its owners.
// Later validations proceed independently, so a replacement backend can register first.
type delayedProviderDecoder struct {
	*realActionDecoder
	armed   atomic.Bool
	entered chan struct{}
	release chan struct{}
}

func (k *delayedProviderDecoder) DecodeEditorProviders(ctx context.Context, payload any) (json.RawMessage, error) {
	if k.armed.CompareAndSwap(true, false) {
		close(k.entered)
		select {
		case <-k.release:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return k.realActionDecoder.DecodeEditorProviders(ctx, payload)
}

func delayedColorRegistration(t *testing.T, s *Service, k *delayedProviderDecoder, workspace WorkspaceContext, plugin, sessionID string) (<-chan struct{}, **pluginhost.Failure, func()) {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	release := sync.OnceFunc(func() { close(k.release) })
	done := make(chan struct{})
	var refusal *pluginhost.Failure
	k.armed.Store(true)
	go func() {
		defer close(done)
		callerCtx := pluginhost.WithCaller(ctx, pluginhost.Caller{PluginID: plugin, SessionID: sessionID})
		_, refusal = s.HostServices.Respond(callerCtx, methodRegisterEditorProviders, json.RawMessage(`{`+contextJSONOf(workspace)+`,"id":"colors","selector":{"fileExtensions":["txt"]},"providers":{"colorDecorations":{"function":"colors.collect","colorLegend":[{"id":"accent","light":"#112233","dark":"#DDEEFF"}]}}}`))
	}()
	t.Cleanup(func() {
		release()
		cancel()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("delayed registration did not stop after cancellation")
		}
	})
	select {
	case <-k.entered:
	case <-ctx.Done():
		t.Fatal("registration did not reach validation gate")
	}
	return done, &refusal, release
}

func finishDelayedColorRegistration(t *testing.T, done <-chan struct{}, release func()) {
	t.Helper()
	release()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("released registration did not finish")
	}
}

func TestColorProviderDetachedRegistrationCannotReplaceNewSession(t *testing.T) {
	kernel := &delayedProviderDecoder{realActionDecoder: &realActionDecoder{notifyKernel: &notifyKernel{}}, entered: make(chan struct{}), release: make(chan struct{})}
	s, workspace := openEditorServiceWith(t, kernel, &fakeWorkbench{})
	plugin := "dev.lithe.test.color-detached-registration"
	old := colorSession(s, plugin, "old")
	if failure := registerColors(t, s, workspace, plugin, "old"); failure != nil {
		t.Fatal(failure)
	}
	done, refusal, release := delayedColorRegistration(t, s, kernel, workspace, plugin, "old")
	// Detach is synchronous; process teardown may still be pending when the new backend starts.
	old.cancel = func() {}
	stopOld := s.Host.Detach(plugin)
	t.Cleanup(func() { close(old.done); stopOld() })
	colorSession(s, plugin, "new")
	if failure := registerColors(t, s, workspace, plugin, "new"); failure != nil {
		t.Fatalf("replacement session could not register: %+v", failure)
	}
	newResourceDisposed := false
	s.resources.add(pluginhost.Caller{PluginID: plugin, SessionID: "new"}, workspace.ContextID, func() { newResourceDisposed = true })
	finishDelayedColorRegistration(t, done, release)
	if *refusal == nil {
		t.Error("detached session's delayed registration succeeded")
	}
	bindings := s.colorDecorationsBindings(workspace.Path, "sample.txt", "")
	if len(bindings) != 1 || bindings[0].sessionID != "new" {
		t.Fatalf("delayed old request replaced the current provider: %+v", bindings)
	}
	if newResourceDisposed || resourcesHeldBy(s, "new") != 2 {
		t.Fatal("delayed old request released resources owned by the new session")
	}
	if resourcesHeldBy(s, "old") != 0 {
		t.Fatal("detached request retained an old provider resource")
	}
}

func TestColorProviderClosedContextCannotRetainDelayedRegistration(t *testing.T) {
	kernel := &delayedProviderDecoder{realActionDecoder: &realActionDecoder{notifyKernel: &notifyKernel{}}, entered: make(chan struct{}), release: make(chan struct{})}
	s, workspace := openEditorServiceWith(t, kernel, &fakeWorkbench{})
	plugin := "dev.lithe.test.color-closed-registration"
	colorSession(s, plugin, "running")
	done, refusal, release := delayedColorRegistration(t, s, kernel, workspace, plugin, "running")
	s.Contexts.Close(workspace.Path)
	s.Contexts.Open(workspace.Path)
	finishDelayedColorRegistration(t, done, release)
	if *refusal == nil || (*refusal).Code != "plugin.host.contextExpired" {
		t.Errorf("closed context registration was not refused: %+v", *refusal)
	}
	if len(s.providers2.list) != 0 || resourcesHeldBy(s, "running") != 0 {
		t.Fatal("closed context retained a late provider registration")
	}
}
