package workbench

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
)

// clangdManifest is a real declarative language-server plugin: Core plans the
// system command, the host starts the real clangd process, and every assertion
// below observes that process's diagnostics rather than injected records.
const clangdManifest = `{
  "schemaVersion": 0,
  "id": "dev.lithe.test.clangd",
  "displayName": "Clangd Test Server",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"languages": 0, "languageServers": 0},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["languageServer.launch", "process.run"],
  "activationEvents": ["onLanguage:c"],
  "languages": [{"id": "c", "displayName": "C", "fileExtensions": ["c"]}],
  "languageServers": [{
    "languageID": "c",
    "languageIdentifier": "c",
    "launch": {"kind": "systemCommand", "commands": ["clangd"]},
    "arguments": [],
    "validationArguments": []
  }]
}`

// clangdHarness makes a window whose isolated plugin root holds clangdManifest
// and whose headless preferences mark it enabled. The package is placed there
// directly, so this exercises launch and document synchronization without the
// user installation or trust flow; it is never written to the user's profile. The test skips when clangd is not installed, so
// the integration assertion is never replaced by a fake server.
func clangdHarness(t *testing.T) *harness {
	t.Helper()
	if testing.Short() {
		t.Skip("starts a real language server process")
	}
	if _, err := exec.LookPath("clangd"); err != nil {
		t.Skipf("clangd is not installed: %v", err)
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	preferences := store.At(dir)
	pluginRoot := t.TempDir()
	installed := filepath.Join(pluginRoot, "dev.lithe.test.clangd", "1.0.0")
	if err := os.MkdirAll(installed, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(installed, "plugin.json"), []byte(clangdManifest), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := pluginstate.New(preferences).SetEnabled("dev.lithe.test.clangd", true); err != nil {
		t.Fatal(err)
	}
	h := newHarnessWithOptions(t, Options{
		Kernel:       &testKernel{Client: core.NewClient()},
		PluginKernel: &testKernel{Client: core.NewClient()},
		PluginRoot:   pluginRoot,
		Store:        preferences,
		Languages:    []string{"zh-Hans"},
	})
	h.app.reloadPluginLanguages()
	h.settle()
	return h
}

// awaitStateWithin pumps the driver until condition holds or limit expires. It
// is the bounded wait for an external language server; every iteration reacts
// to a wake, so an idle test does not spin. A background goroutine can finish its
// state change without posting anything, which rings no wake, so the wait also
// re-checks on a short tick instead of waiting the deadline out.
func awaitStateWithin(t *testing.T, h *harness, limit time.Duration, what string, condition func() bool) {
	t.Helper()
	deadline := time.NewTimer(limit)
	defer deadline.Stop()
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for !condition() {
		select {
		case <-h.driver.Wakes():
			if err := h.driver.Pump(); err != nil {
				t.Fatal(err)
			}
		case <-tick.C:
		case <-deadline.C:
			t.Fatalf("%s did not happen before the deadline", what)
		}
	}
}

// awaitValueWithin receives one value while pumping the driver, so a producer that
// still needs a window turn can finish. Waiting on the value itself keeps the result
// independent of a window wake: polling a channel length only rechecks after a wake,
// so a producer that posts nothing stays unobserved until the deadline.
func awaitValueWithin[T any](t *testing.T, h *harness, limit time.Duration, channel <-chan T, what string) T {
	t.Helper()
	deadline := time.NewTimer(limit)
	defer deadline.Stop()
	for {
		select {
		case value := <-channel:
			return value
		case <-h.driver.Wakes():
			if err := h.driver.Pump(); err != nil {
				t.Fatal(err)
			}
		case <-deadline.C:
			var zero T
			t.Fatalf("%s did not happen before the deadline", what)
			return zero
		}
	}
}

// problemMessagesContain reports whether a live server's diagnostics contain
// text. It reads the same store the Problems panel queries.
func problemMessagesContain(a *App, text string) bool {
	for _, set := range a.pluginDiagnosticSets() {
		for _, record := range set.All() {
			if strings.Contains(strings.ToLower(record.Message), strings.ToLower(text)) {
				return true
			}
		}
	}
	return false
}

// problemMessages lists the stored server messages for the test log and for a
// semantic assertion about the real server's output.
func problemMessages(a *App) []string {
	var messages []string
	for _, set := range a.pluginDiagnosticSets() {
		for _, record := range set.All() {
			messages = append(messages, record.Message)
		}
	}
	return messages
}

// diagnosticsForFile counts a server's diagnostics for one path.
func diagnosticsForFile(a *App, path string) int {
	total := 0
	for _, set := range a.pluginDiagnosticSets() {
		for _, record := range set.All() {
			if record.FileKey == path {
				total++
			}
		}
	}
	return total
}

// openClangdDocument opens a real C document through the same workbench action
// a search result uses and waits until the server has the document.
func openClangdDocument(t *testing.T, h *harness, root, content string) (*project, *document, string) {
	t.Helper()
	path := filepath.Join(root, "main.c")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.openFileAt(h.app.project, path, 1)
	var p *project
	var d *document
	awaitStateWithin(t, h, 30*time.Second, "clangd to open the document", func() bool {
		p = h.app.project
		if p == nil {
			return false
		}
		d = p.docs.byPath(path)
		return d != nil && d.sync.opened
	})
	return p, d, path
}

// TestClangdDocumentSyncEndToEnd proves the editor-to-Core-to-server chain:
// a real clangd process receives the document, a real editor edit arrives as an
// incremental change, its diagnostic reaches the Problems panel, the saved text
// is reported, and closing the tab withdraws the host's copy.
func TestClangdDocumentSyncEndToEnd(t *testing.T) {
	h := clangdHarness(t)
	root := t.TempDir()
	h.open(root)
	p, d, path := openClangdDocument(t, h, root, "int main(void) { return 0; }\n")
	if len(h.app.pluginServers) == 0 {
		t.Fatal("clangd was not registered as a running server")
	}

	// Insert an undeclared identifier with an ordinary editor text event, so
	// the change travels through OnEdit, the tracker and Core's didChange.
	if !d.view.GoToNavigation(0, 17, false) {
		t.Fatal("could not place the caret before return")
	}
	input := d.view.TextInput(app.TextInputContext{ID: d.hit})
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: "missing "}); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 30*time.Second, "a clangd diagnostic after the edit", func() bool {
		return problemMessagesContain(h.app, "missing")
	})
	messages := problemMessages(h.app)
	t.Logf("clangd diagnostics: %q", messages)
	if got := diagnosticsForFile(h.app, path); got == 0 {
		t.Fatal("clangd's diagnostic was not stored")
	}
	if !strings.Contains(strings.ToLower(strings.Join(messages, " ")), "undeclared identifier") {
		t.Fatalf("diagnostics = %q, want clangd's undeclared-identifier message", messages)
	}

	// The Problems panel queries the same store and shows the server's message.
	// A real server's serve loop is a tracked background task, so this click
	// pumps frames instead of waiting for every task to finish.
	at := center(h.button(itemProblems))
	if err := h.driver.Click(at.X, at.Y); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 10*time.Second, "the Problems query", func() bool {
		return h.app.problems.loaded && !h.app.problems.querying
	})
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	if !h.shows("missing") {
		t.Fatal("the Problems panel does not show clangd's message")
	}

	// A save reports the exact written text to the session and keeps the
	// document clean.
	h.app.saveDocument(p, d.id)
	awaitStateWithin(t, h, 10*time.Second, "the saved file", func() bool {
		data, err := os.ReadFile(path)
		return err == nil && strings.Contains(string(data), "missing ") && !d.dirty()
	})

	// Closing the tab closes the document in the session and withdraws the
	// diagnostics the host kept for it. Core clears its own copy on didClose.
	h.app.closeDocument(p, d.id)
	awaitStateWithin(t, h, 10*time.Second, "the closed tab", func() bool {
		return p.docs.byPath(path) == nil
	})
	if got := diagnosticsForFile(h.app, path); got != 0 {
		t.Fatalf("closed document kept %d host diagnostics", got)
	}
	// The serve loop is a tracked task: stop the session before waiting for all
	// tasks, as project close and application shutdown do.
	h.app.closeProject()
	awaitStateWithin(t, h, 20*time.Second, "the closed project", func() bool {
		return h.app.project == nil
	})
	h.settle()
}

// TestClangdProjectSwitchStopsSession proves leaving a project for another cancels
// the old workspace: the server is removed, its diagnostics are cleared, and the
// next project starts with no stale list. Opening a second project while one is
// shown opens a project tab, so the workbench closes the first before it opens the
// next one in its place.
func TestClangdProjectSwitchStopsSession(t *testing.T) {
	h := clangdHarness(t)
	root := t.TempDir()
	h.open(root)
	_, d, _ := openClangdDocument(t, h, root, "int main(void) { return 0; }\n")
	if !d.view.GoToNavigation(0, 17, false) {
		t.Fatal("could not place the caret before return")
	}
	input := d.view.TextInput(app.TextInputContext{ID: d.hit})
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: "missing "}); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 30*time.Second, "clangd diagnostics before the switch", func() bool {
		return problemMessagesContain(h.app, "missing")
	})

	next := t.TempDir()
	h.app.closeProject()
	awaitStateWithin(t, h, 20*time.Second, "the closed project", func() bool {
		return h.app.project == nil
	})
	h.app.openProject(next)
	awaitStateWithin(t, h, 20*time.Second, "the switched project", func() bool {
		return h.app.project != nil && h.app.project.root == next
	})
	if len(h.app.pluginServers) != 0 {
		t.Fatalf("the previous project's servers survived the switch: %v", h.app.pluginServers)
	}
	if h.app.pluginDiagnostics != nil {
		t.Fatalf("the previous project's diagnostics survived the switch: %v", h.app.pluginDiagnostics)
	}
	h.settle()
}

// The real clangd integration also proves that an unknown plugin language is
// not silently served by a built-in provider.
func TestClangdManifestContributesLanguage(t *testing.T) {
	h := clangdHarness(t)
	language, ok := h.app.syntaxRegistry().ForPath("main.c")
	if !ok || language.ID != "c" {
		t.Fatalf("language = %+v, ok = %v", language, ok)
	}
}

// A build can be the first consumer of a language server. Its session must
// also synchronize already-open editor buffers and retain workspace ownership.
func TestClangdBuildStartedSessionSynchronizesEditor(t *testing.T) {
	h := clangdHarness(t)
	root := t.TempDir()
	h.open(root)
	stack := h.app.plugins
	h.app.plugins = nil
	p, d := openSyncDocument(t, h, root, "main.c")
	h.app.plugins = stack
	if d.languageID != "c" {
		t.Fatalf("language = %q", d.languageID)
	}
	ctx, cancel := context.WithTimeout(p.ctx, 30*time.Second)
	defer cancel()
	result := make(chan error, 1)
	instance := buildInstance{PluginID: "dev.lithe.test.clangd"}
	h.app.tasks.running.Add(1)
	go func() {
		defer h.app.tasks.running.Done()
		_, err := h.app.sharedBuildProvider(ctx, p, instance, "c")
		result <- err
		h.app.invalidator.Invalidate()
	}()
	var ready bool
	awaitStateWithin(t, h, 35*time.Second, "build-started server and editor synchronization", func() bool {
		if !ready {
			select {
			case err := <-result:
				if err != nil {
					t.Fatal(err)
				}
				ready = true
			default:
			}
		}
		return ready
	})
	server, _ := h.app.documentSyncServer(d)
	if server == nil || server.project != p {
		t.Fatal("shared server lost its project ownership")
	}
	awaitStateWithin(t, h, 30*time.Second, "editor synchronization", func() bool { return d.sync.opened })
	awaitStateWithin(t, h, 30*time.Second, "diagnostics from the build-started server", func() bool {
		return diagnosticsForFile(h.app, d.path) > 0
	})
	h.app.requestCloseProject(nil)
	awaitStateWithin(t, h, 30*time.Second, "project close", func() bool { return h.app.project == nil })
	if h.app.isCurrentPluginServer(instance.PluginID, server) {
		t.Fatal("shared server survived project close")
	}
}
