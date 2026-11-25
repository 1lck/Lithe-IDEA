package pluginservice

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

type workflowWindow struct {
	*fakeWorkbench
	mu          sync.Mutex
	progress    ProgressUpdate
	released    []string
	blockOutput bool
	entered     chan struct{}
}

func (*workflowWindow) QuickInput(context.Context, string, QuickInput) (*QuickResult, error) {
	return nil, nil
}
func (*workflowWindow) OpenPreview(context.Context, string, PreviewRequest) (PreviewResult, error) {
	return PreviewResult{}, nil
}
func (*workflowWindow) ShowTextDiff(context.Context, string, DiffRequest) error { return nil }
func (w *workflowWindow) UpdateOutput(ctx context.Context, _ string, _ OutputUpdate) error {
	if w.blockOutput {
		close(w.entered)
		<-ctx.Done() // Request and test deadlines bound the simulated window wait.
		return ctx.Err()
	}
	return nil
}
func (w *workflowWindow) UpdateProgress(_ context.Context, _ string, update ProgressUpdate) error {
	w.mu.Lock()
	w.progress = update
	w.mu.Unlock()
	return nil
}
func (*workflowWindow) UpdateStatus(context.Context, string, StatusUpdate) error { return nil }
func (*workflowWindow) ReadClipboard(context.Context) (string, error)            { return "", nil }
func (*workflowWindow) WriteClipboard(context.Context, string) error             { return nil }
func (*workflowWindow) RevealResource(context.Context, string) error             { return nil }
func (*workflowWindow) OpenBrowserResource(context.Context, string, string, string) (bool, error) {
	return false, nil
}
func (w *workflowWindow) ReleaseWorkflow(_, kind, id string) {
	w.mu.Lock()
	w.released = append(w.released, kind+":"+id)
	w.mu.Unlock()
}

func workflowService(t *testing.T, window *workflowWindow) (*Service, WorkspaceContext, *notifyKernel) {
	t.Helper()
	if window.fakeWorkbench == nil {
		window.fakeWorkbench = &fakeWorkbench{}
	}
	kernel := &realActionDecoder{notifyKernel: &notifyKernel{}}
	service, workspace := openEditorServiceWith(t, kernel, window)
	runningActionSession(service, "a", "session-a")
	runningActionSession(service, "b", "session-b")
	t.Cleanup(func() {
		service.Contexts.CloseAll()
		if service.workflow.transport != nil {
			service.workflow.transport.CloseIdleConnections()
		}
	})
	return service, workspace, kernel.notifyKernel
}

func TestWorkflowProgressOwnershipCancellationAndContextCleanup(t *testing.T) {
	window := &workflowWindow{}
	service, workspace, kernel := workflowService(t, window)
	result, refusal := respond(t, service, "a", "progress/create", `{`+contextJSONOf(workspace)+`,"title":"Import","cancellable":true}`)
	if refusal != nil {
		t.Fatal(refusal)
	}
	var created struct{ ProgressID, SubscriptionID string }
	if err := json.Unmarshal(result, &created); err != nil || created.ProgressID == "" || created.ProgressID != created.SubscriptionID {
		t.Fatalf("create=%s, %v", result, err)
	}
	params := `{` + contextJSONOf(workspace) + `,"progressID":"` + created.ProgressID + `","percentage":25}`
	if _, refusal := respond(t, service, "b", "progress/report", params); refusal == nil || refusal.Code != CodeNotFound {
		t.Fatalf("foreign report=%+v", refusal)
	}
	window.progress.Cancel()
	window.progress.Cancel()
	kernel.mu.Lock()
	notifications := append([]string(nil), kernel.sent...)
	kernel.mu.Unlock()
	if len(notifications) != 1 || !strings.Contains(notifications[0], `"cancelled":true`) {
		t.Fatalf("cancel notifications=%v", notifications)
	}
	if _, refusal := respond(t, service, "a", "progress/report", params); refusal == nil || refusal.Code != pluginhost.CodeCancelled {
		t.Fatalf("cancelled report=%+v", refusal)
	}
	service.Contexts.Close(workspace.Path)
	if len(window.released) != 1 || window.released[0] != "progress:"+created.ProgressID {
		t.Fatalf("released=%v", window.released)
	}
	if len(service.workflow.byID) != 0 {
		t.Fatal("context retained workflow resources")
	}
}

func TestWorkflowClosingContextCancelsNativeCreationWithoutWaitingForWindow(t *testing.T) {
	window := &workflowWindow{blockOutput: true, entered: make(chan struct{})}
	service, workspace, _ := workflowService(t, window)
	ctx, cancel := context.WithTimeout(callerContext("a"), 3*time.Second)
	defer cancel()
	done := make(chan *pluginhost.Failure, 1)
	go func() {
		_, refusal := service.HostServices.Respond(ctx, "lithe/host/output/create", json.RawMessage(`{`+contextJSONOf(workspace)+`,"name":"Build"}`))
		done <- refusal
	}()
	select {
	case <-window.entered:
	case <-ctx.Done():
		t.Fatal("native creation did not start")
	}
	closed := make(chan struct{})
	go func() { service.Contexts.Close(workspace.Path); close(closed) }()
	select {
	case <-closed:
	case <-ctx.Done():
		t.Fatal("context close waited for the native window")
	}
	select {
	case refusal := <-done:
		if refusal == nil || refusal.Code != pluginhost.CodeCancelled {
			t.Fatalf("cancel=%+v", refusal)
		}
	case <-ctx.Done():
		t.Fatal("native creation did not terminate")
	}
	if len(service.workflow.byID) != 0 {
		t.Fatal("failed creation leaked a handle")
	}
}

func TestWorkflowHTTPRedirectBinaryBudgetAndContextCancellation(t *testing.T) {
	window := &workflowWindow{}
	service, workspace, _ := workflowService(t, window)
	var redirected atomic.Int32
	started := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/redirect":
			w.Header().Set("Location", "/target")
			w.Header().Set("Set-Cookie", "session=private")
			w.WriteHeader(http.StatusFound)
		case "/target":
			redirected.Add(1)
		case "/binary":
			if r.Header.Get("Cookie") != "" {
				t.Error("a cookie leaked between requests")
			}
			_, _ = w.Write([]byte{0xff, 0x00, 0xfe})
		case "/headers":
			w.Header().Set("X-Large", strings.Repeat("h", 20*1024))
		case "/wait":
			close(started)
			select {
			case <-r.Context().Done():
			case <-time.After(4 * time.Second):
				t.Error("request was not cancelled")
			}
		default:
			_, _ = w.Write([]byte("large"))
		}
	}))
	t.Cleanup(server.Close)
	request := func(ctx context.Context, path string, budget int) (json.RawMessage, *pluginhost.Failure) {
		params := mustMarshal(map[string]any{"context": workspace.ContextRef, "url": server.URL + path, "maximumResponseBytes": budget})
		return service.HostServices.Respond(ctx, "lithe/host/network/request", params)
	}
	ctx, cancel := context.WithTimeout(callerContext("a"), 5*time.Second)
	defer cancel()
	result, refusal := request(ctx, "/redirect", 128)
	if refusal != nil || !strings.Contains(string(result), `"status":302`) || redirected.Load() != 0 {
		t.Fatalf("redirect=%s %+v, followed=%d", result, refusal, redirected.Load())
	}
	result, refusal = request(ctx, "/binary", 128)
	if refusal != nil || !strings.Contains(string(result), `"encoding":"base64"`) || !strings.Contains(string(result), `"body":"/wD+"`) {
		t.Fatalf("binary=%s %+v", result, refusal)
	}
	for _, path := range []string{"/body", "/headers"} {
		if _, refusal = request(ctx, path, 2); refusal == nil || refusal.Code != CodeLimitExceeded {
			t.Fatalf("%s budget=%+v", path, refusal)
		}
	}
	done := make(chan *pluginhost.Failure, 1)
	go func() { _, refusal := request(ctx, "/wait?token=private", 128); done <- refusal }()
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("HTTP request did not start")
	}
	service.Contexts.Close(workspace.Path)
	select {
	case refusal := <-done:
		if refusal == nil || refusal.Code != pluginhost.CodeCancelled || strings.Contains(refusal.Message, "private") {
			t.Fatalf("cancel=%+v", refusal)
		}
	case <-ctx.Done():
		t.Fatal("context closure did not cancel HTTP")
	}
}
