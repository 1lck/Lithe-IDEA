package pluginweb

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// waitLimit bounds every wait for an answer the page is posted.
const waitLimit = 10 * time.Second

const windowID = "dev.lithe.fixture.web-panel.window"

type fakeView struct {
	messages chan string
	mu       sync.Mutex
	loads    []string
	closed   bool
}

func (v *fakeView) PostMessage(text string) { v.messages <- text }
func (v *fakeView) Load(url string)         { v.mu.Lock(); v.loads = append(v.loads, url); v.mu.Unlock() }
func (v *fakeView) Close()                  { v.mu.Lock(); v.closed = true; v.mu.Unlock() }

// fakeHost keeps state in memory. The "wait" function reports one progress
// update, signals started and returns only when its call is cancelled.
type fakeHost struct {
	mu      sync.Mutex
	state   map[string][]byte
	opened  []string
	chosen  string
	started chan struct{}
}

func (h *fakeHost) State(_ context.Context, plugin, window string) ([]byte, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.state[plugin+"/"+window], nil
}

func (h *fakeHost) SetState(_ context.Context, plugin, window string, state []byte) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if state == nil {
		delete(h.state, plugin+"/"+window)
	} else {
		h.state[plugin+"/"+window] = state
	}
	return nil
}

func (h *fakeHost) BackendFunctions(context.Context, string) ([]string, error) {
	return []string{"echo", "wait"}, nil
}

func (h *fakeHost) CallBackend(ctx context.Context, _, function string, params json.RawMessage, progress func(json.RawMessage)) (json.RawMessage, error) {
	switch function {
	case "echo":
		return params, nil
	case "wait":
		if progress != nil {
			progress(json.RawMessage(`{"message":"working","percentage":40}`))
		}
		close(h.started)
		<-ctx.Done()
		return nil, ctx.Err()
	}
	return nil, Fail("plugin.function.unknown", "no such function")
}

func (h *fakeHost) ChooseFile(string, FileRequest) (string, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.chosen, nil
}

func (h *fakeHost) OpenFile(path string, _, _ int) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.opened = append(h.opened, path)
	return nil
}

type fixture struct {
	page *Page
	view *fakeView
	host *fakeHost
	dir  string
}

func openFixture(t *testing.T) *fixture {
	t.Helper()
	manifest, err := os.ReadFile("../../../shared/contracts/plugins/v1/fixtures/ui/web-panel.plugin.json")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "ui"), 0o755); err != nil {
		t.Fatal(err)
	}
	write := func(name, text string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("ui/index.html", "<!doctype html><html><head><title>Panel</title></head><body>hi</body></html>")
	write("ui/app.js", "console.log(1)")
	outside := filepath.Join(t.TempDir(), "secret.txt")
	if err := os.WriteFile(outside, []byte("secret"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(dir, "ui", "link.js")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Dir(outside), filepath.Join(dir, "linked")); err != nil {
		t.Fatal(err)
	}
	host := &fakeHost{state: map[string][]byte{}, chosen: "/tmp/chosen.txt", started: make(chan struct{})}
	ctx, cancel := context.WithTimeout(context.Background(), waitLimit)
	defer cancel()
	page, err := Open(ctx, Config{
		Kernel:  core.NewClient(),
		Host:    host,
		Package: dir,
		Post:    func(fn func()) { fn() },
		Log:     func(string, error) {},
		Open: core.PluginWebOpen{
			Manifest: manifest, WindowID: windowID, Platform: "macos", Locale: "en",
			Theme: core.PluginWebTheme{Theme: "dark", Variables: map[string]string{"--lithe-background": "#1e1f22"}},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	view := &fakeView{messages: make(chan string, 16)}
	page.Attach(view)
	t.Cleanup(page.Close)
	return &fixture{page: page, view: view, host: host, dir: dir}
}

// next returns the next message posted to the page.
func (f *fixture) next(t *testing.T) map[string]json.RawMessage {
	t.Helper()
	select {
	case text := <-f.view.messages:
		var message map[string]json.RawMessage
		if err := json.Unmarshal([]byte(text), &message); err != nil {
			t.Fatalf("message %q: %v", text, err)
		}
		return message
	case <-time.After(waitLimit):
		t.Fatal("the page was posted nothing")
		return nil
	}
}

func (f *fixture) request(t *testing.T, id int, method string, params any) map[string]json.RawMessage {
	t.Helper()
	encoded, err := json.Marshal(map[string]any{"id": id, "method": method, "params": params})
	if err != nil {
		t.Fatal(err)
	}
	f.page.Receive(string(encoded))
	return f.next(t)
}

func errorCode(t *testing.T, message map[string]json.RawMessage) string {
	t.Helper()
	var failure struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(message["error"], &failure); err != nil || failure.Code == "" {
		t.Fatalf("not an error reply: %s", message)
	}
	return failure.Code
}

func TestPageServesItsPackageOnly(t *testing.T) {
	f := openFixture(t)
	if info := f.page.Info(); info.URL != "lithe-plugin://dev.lithe.fixture.web-panel/ui/index.html" || info.BridgeVersion != 2 {
		t.Fatalf("page = %+v", info)
	}
	mime, body, ok := f.page.Serve("/ui/index.html")
	if !ok || !strings.HasPrefix(mime, "text/html") {
		t.Fatalf("entry = %q %v", mime, ok)
	}
	document := string(body)
	if !strings.Contains(document, "Content-Security-Policy") || !strings.Contains(document, ".lithe-host/") || !strings.Contains(document, "<body>hi</body>") {
		t.Fatalf("entry lacks the policy, the bridge or its content:\n%s", document)
	}
	if _, script, ok := f.page.Serve("ui/app.js"); !ok || string(script) != "console.log(1)" {
		t.Fatalf("package script = %q %v", script, ok)
	}
	if _, bridge, ok := f.page.Serve("/.lithe-host/bridge.js"); !ok || !strings.Contains(string(bridge), "dev.lithe.fixture.web-panel") {
		t.Fatalf("bridge = %v", ok)
	}
	for _, path := range []string{"/ui/link.js", "/linked/secret.txt", "/../secret.txt", "/ui/missing.js", "/.lithe-host/other.js"} {
		if _, data, ok := f.page.Serve(path); ok {
			t.Errorf("%s was served: %q", path, data)
		}
	}
}

func TestReadPackageFileEnforcesTheLimit(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "big.bin"), make([]byte, 33), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := readPackageFile(dir, []string{"big.bin"}, 32); err == nil {
		t.Fatal("a file over the limit was read")
	}
	if data, err := readPackageFile(dir, []string{"big.bin"}, 33); err != nil || len(data) != 33 {
		t.Fatalf("read = %d %v", len(data), err)
	}
	if _, err := readPackageFile(dir, nil, 1<<20); !errors.Is(err, errOutsidePackage) {
		t.Fatalf("the package directory itself was read: %v", err)
	}
}

func TestPageRequestsReachTheHost(t *testing.T) {
	f := openFixture(t)
	if reply := f.request(t, 1, "ui.setState", map[string]any{"state": map[string]int{"tab": 2}}); string(reply["ok"]) != "{}" {
		t.Fatalf("setState = %s", reply)
	}
	if reply := f.request(t, 2, "ui.getState", nil); string(reply["ok"]) != `{"state":{"tab":2}}` {
		t.Fatalf("getState = %s", reply)
	}
	if reply := f.request(t, 3, "functions.list", nil); string(reply["ok"]) != `{"functions":["echo","wait"]}` {
		t.Fatalf("functions.list = %s", reply)
	}
	if reply := f.request(t, 4, "functions.invoke", map[string]any{"function": "echo", "params": map[string]int{"a": 1}}); string(reply["ok"]) != `{"value":{"a":1}}` {
		t.Fatalf("invoke = %s", reply)
	}
	if reply := f.request(t, 5, "dialog.saveFile", map[string]any{"suggestedName": "out.txt", "extensions": []string{"txt"}}); string(reply["ok"]) != `{"path":"/tmp/chosen.txt"}` {
		t.Fatalf("saveFile = %s", reply)
	}
	// The dialog's reply ended it, so the page may open another.
	f.host.mu.Lock()
	f.host.chosen = ""
	f.host.mu.Unlock()
	if reply := f.request(t, 6, "dialog.openFile", nil); string(reply["ok"]) != `{"path":null}` {
		t.Fatalf("cancelled openFile = %s", reply)
	}
	if reply := f.request(t, 7, "workspace.openFile", map[string]any{"path": "src/Main.java", "line": 3}); string(reply["ok"]) != "{}" || len(f.host.opened) != 1 {
		t.Fatalf("openFile = %s, opened %v", reply, f.host.opened)
	}
	if code := errorCode(t, f.request(t, 8, "workspace.openFile", map[string]any{"path": "../x"})); code != "plugin.web.forbidden" {
		t.Fatalf("escaping path = %s", code)
	}
	if code := errorCode(t, f.request(t, 9, "build.list", nil)); code != "plugin.web.unknownMethod" {
		t.Fatalf("build without build systems = %s", code)
	}
	if code := errorCode(t, f.request(t, 10, "functions.invoke", map[string]any{"function": "missing"})); code != "plugin.function.unknown" {
		t.Fatalf("failed call = %s", code)
	}
}

// A page call reports progress, is cancelled by the page, and answers with
// requestCancelled; its ID cannot be used again.
func TestPageCancelsItsCall(t *testing.T) {
	f := openFixture(t)
	call, _ := json.Marshal(map[string]any{"id": 1, "method": "functions.invoke", "params": map[string]any{"function": "wait", "call": "c1"}})
	f.page.Receive(string(call))
	progress := f.next(t)
	if string(progress["event"]) != `"functions.progress"` || !strings.Contains(string(progress["payload"]), `"percentage":40`) {
		t.Fatalf("progress = %s", progress)
	}
	select {
	case <-f.host.started:
	case <-time.After(waitLimit):
		t.Fatal("the call did not start")
	}
	if reply := f.request(t, 2, "functions.cancel", map[string]any{"call": "c1"}); string(reply["ok"]) != "{}" {
		// The cancelled call may answer first; both arrive.
		if string(reply["id"]) != "1" {
			t.Fatalf("cancel = %s", reply)
		}
		if code := errorCode(t, reply); code != "requestCancelled" {
			t.Fatalf("cancelled call = %s", code)
		}
		f.next(t)
	} else if code := errorCode(t, f.next(t)); code != "requestCancelled" {
		t.Fatalf("cancelled call = %s", code)
	}
	if code := errorCode(t, f.request(t, 3, "functions.invoke", map[string]any{"function": "echo", "call": "c1"})); code != "plugin.web.invalidRequest" {
		t.Fatalf("reused call ID = %s", code)
	}
}

// Closing a page cancels its calls and posts nothing more to it.
func TestClosingThePageEndsItsCalls(t *testing.T) {
	f := openFixture(t)
	call, _ := json.Marshal(map[string]any{"id": 1, "method": "functions.invoke", "params": map[string]any{"function": "wait"}})
	f.page.Receive(string(call))
	select {
	case <-f.host.started:
	case <-time.After(waitLimit):
		t.Fatal("the call did not start")
	}
	f.page.Close()
	f.page.Close()
	f.view.mu.Lock()
	closed := f.view.closed
	f.view.mu.Unlock()
	if !closed {
		t.Fatal("the view stayed open")
	}
	f.page.Receive(string(call))
	ctx, cancel := context.WithTimeout(context.Background(), waitLimit)
	defer cancel()
	// Core has forgotten the page: a late reply frames nothing.
	message, err := core.NewClient().PluginWebReply(ctx, core.PluginWebReply{Page: f.page.Info().Page, ID: 1, Method: "functions.invoke", Result: json.RawMessage(`{}`)})
	if err != nil || message != "" {
		t.Fatalf("late reply = %q %v", message, err)
	}
	select {
	case text := <-f.view.messages:
		t.Fatalf("a closed page was posted %q", text)
	default:
	}
}

func TestNavigationStaysInThePackage(t *testing.T) {
	f := openFixture(t)
	f.page.Loaded("lithe-plugin://dev.lithe.fixture.web-panel/ui/other.html")
	f.page.Loaded("https://example.com/")
	f.page.Loaded("lithe-plugin://dev.lithe.fixture.other/ui/index.html")
	f.view.mu.Lock()
	defer f.view.mu.Unlock()
	if len(f.view.loads) != 2 || f.view.loads[0] != f.page.Info().URL {
		t.Fatalf("loads = %v", f.view.loads)
	}
}

func TestThemeChangesReachThePage(t *testing.T) {
	f := openFixture(t)
	f.page.SetTheme(core.PluginWebTheme{Theme: "light", Variables: map[string]string{"--lithe-background": "#ffffff"}})
	if message := f.next(t); string(message["event"]) != `"ui.themeChanged"` || !strings.Contains(string(message["payload"]), "#ffffff") {
		t.Fatalf("theme = %s", message)
	}
}
